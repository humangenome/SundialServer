-- SolarpunkRoster: tracks connected Solarpunk players and writes a snapshot
-- JSON (roster.json) next to SolarpunkServer\appsettings.json. SolarpunkServer's
-- RosterFileWatcherService polls that file every 5s and feeds the A2S player
-- list/count + the HTTP /api/v1/players endpoint.
--
-- Port of Beacon's BeaconRoster (SN2) to Solarpunk (UE 5.7), with one
-- simplification: the authoritative source is FindAllOf("BP_MainPlayerController_C")
-- filtered to remote controllers (the headless host's own local listen player
-- is excluded), which matches exactly the set of controllers the
-- SolarpunkHost net-id enforcer keys saves for. The player id published as
-- SolarpunkUserId is the SAME synthetic id (765611900 + crc32(lower(name)))
-- the save/load keying uses, so the roster id == the save key == the
-- launcher-known identity.
--
-- roster.json schema:
--
--   {
--     "unix_ms": <write time ms>,
--     "world": { "name": "<UWorld name>" },
--     "players": [
--       { "SolarpunkUserId": "765611900NNNNNNNNN",
--         "DisplayName": "<player name>",
--         "ConnectedAtUnixMs": <ms>,
--         "LastPacketUnixMs": <ms>,
--         "PingMs": <int>,
--         "X": <float>, "Y": <float>, "Z": <float>, "PosUnixMs": <ms> }
--     ]
--   }

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local SCRIPT_SOURCE = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
if SCRIPT_SOURCE:sub(1, 1) == "@" then SCRIPT_SOURCE = SCRIPT_SOURCE:sub(2) end

local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkRoster.log"

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkRoster] " .. tostring(msg) .. "\n")
end

log("SolarpunkRoster loaded")

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function get_mod_dir()
    local src = SCRIPT_SOURCE
    if src == "" then return nil end
    local sep = src:find("\\Scripts\\", 1, true) or src:find("/Scripts/", 1, true)
    if not sep then return nil end
    return src:sub(1, sep - 1)
end

local function find_solarpunkserver_dir()
    local candidates = {}
    local mod_dir = get_mod_dir()
    if mod_dir then
        local dir = mod_dir
        for _ = 1, 8 do
            table.insert(candidates, dir .. "\\SolarpunkServer")
            local parent = dir:match("^(.+)[\\/][^\\/]+$")
            if not parent or parent == dir then break end
            dir = parent
        end
    end
    local probe = io.popen("cd")
    if probe then
        local cwd = probe:read("*l")
        probe:close()
        if cwd and #cwd > 0 then
            local dir = cwd
            for _ = 1, 8 do
                table.insert(candidates, dir .. "\\SolarpunkServer")
                local parent = dir:match("^(.+)\\[^\\]+$")
                if not parent or parent == dir then break end
                dir = parent
            end
        end
    end
    for _, c in ipairs(candidates) do
        if file_exists(c .. "\\appsettings.json") then
            log("SolarpunkServer dir located: " .. c)
            return c
        end
    end
    return nil
end

local SP_DIR = find_solarpunkserver_dir()
local ROSTER_FILE = SP_DIR and (SP_DIR .. "\\roster.json") or nil
if not ROSTER_FILE then
    log("FATAL: could not locate SolarpunkServer dir; roster snapshots disabled")
    return
end
log("Roster file: " .. ROSTER_FILE)

-- Shared scheduler/state from SolarpunkServerRuntime (see the STABILITY
-- CONTRACT comment there): the scan runs as a game-thread scheduler task and
-- skips controllers that are mid-join-transition (SP.settled) or kicked
-- (SP.kicked) — reading Pawn/ping off a half-loaded or dying controller was
-- part of the full-stack crash surface on UE4SS-on-5.7.
local SP = _G.SolarpunkSP
if not SP then
    error("SolarpunkRoster requires SolarpunkServerRuntime (load via the orchestrator)")
end

-- Synthetic id, identical derivation to SolarpunkHost's net-id enforcer so
-- the roster id matches the save key.
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = c ~ string.byte(s, i)
        for _ = 1, 8 do
            local m = -(c & 1)
            c = (c >> 1) ~ (0xEDB88320 & m)
        end
    end
    return (~c) & 0xFFFFFFFF
end

local function synth_id(name)
    if not name or #name == 0 then name = "spx" end
    return string.format("765611900%09d", crc32(string.lower(name)) % 1000000000)
end

-- Strip the SolarpunkAuth name-channel token so the published roster name +
-- SolarpunkUserId match the save key (character name only, never the password).
-- Byte-identical with SolarpunkAuth.AUTH_DELIM / SolarpunkHost.clean_name.
local AUTH_DELIM = "__SPPW__"
local function clean_name(raw)
    raw = tostring(raw or "")
    local i = raw:find(AUTH_DELIM, 1, true)
    if i then return raw:sub(1, i - 1) end
    return raw
end

local function is_legacy_launcher_identity(name)
    local base, suffix = tostring(name or ""):match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    if not base or not suffix or #suffix < 8 then return false end
    if base == "server" or base:match("^DESKTOP") or base:match("%-PC$") then return false end
    return base:match("%l") ~= nil
end

local function is_transient_identity_name(name)
    if type(name) ~= "string" then return false end
    if name == "TESTING UID" or name == "ERROR, BAD UNIQUE NET ID" then return true end
    if is_legacy_launcher_identity(name) then return false end
    if name:match("^DESKTOP%-[A-Z0-9%-]+$") then return true end
    if name:match("^[A-Z0-9_%-]+%-PC%-[0-9A-Fa-f]+$") then return true end
    local _, suffix = name:match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    return suffix ~= nil and #suffix >= 8
end

local function unix_ms()
    return os.time() * 1000
end

local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', string.byte(c)) end)
    return s
end

-- roster keyed by synthetic id. Value: { name, joined_unix_ms, ping_ms, x,y,z, pos_unix_ms }
local roster = {}

local function get_world_name()
    local ok, world = pcall(FindFirstOf, "World")
    if not ok or not world or not world:IsValid() then return "" end
    local ok2, n = pcall(function() return world:GetName() end)
    if ok2 and n and n ~= "" then return tostring(n) end
    return ""
end

local function player_name(pc, key)
    local canonical = SP.canonical_name and SP.canonical_name[key]
    if canonical and canonical ~= "" and not is_transient_identity_name(canonical) then
        return canonical
    end
    local nm = ""
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then nm = ps:GetPlayerName():ToString() end
    end)
    nm = clean_name(nm)
    if nm == "" or is_transient_identity_name(nm) then return "" end
    return nm
end

local function player_ping(pc)
    local ping = 0
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then
            local p = ps.ExactPing
            if type(p) == "number" and p > 0 then ping = math.floor(p)
            else
                local cp = ps.CompressedPing
                if type(cp) == "number" then ping = math.floor(cp * 4) end
            end
        end
    end)
    return ping
end

local function pawn_location(pc)
    local loc = nil
    pcall(function()
        local pawn = pc.Pawn
        if (not pawn or not pawn:IsValid()) and pc.K2_GetPawn then pawn = pc:K2_GetPawn() end
        if pawn and pawn:IsValid() then
            local l = pawn:K2_GetActorLocation()
            if l then loc = { x = l.X or 0, y = l.Y or 0, z = l.Z or 0 } end
        end
    end)
    return loc
end

-- Game-thread scan: every remote BP_MainPlayerController_C with a non-empty
-- player name is a roster entry. Controllers still inside the join
-- transition (or kicked) are skipped this pass — they show up on the next
-- 5s tick once settled, which also means a roster read at the exact
-- join-boundary can no longer hand back a half-initialized position.
local function akey(pc)
    local k = 0
    pcall(function() k = pc:GetAddress() end)
    return k
end

local function rescan()
    local live = {}
    local cs = SP.controllers()
    if cs then
        for _, c in ipairs(cs) do
            if c and c:IsValid() and not c:IsLocalPlayerController() then
                local k = akey(c)
                if SP.kicked[k] or not SP.settled(k) then
                    -- mid-transition or dying: keep an existing entry alive
                    -- (no fresh reads), pick the player up next tick.
                    local nm = player_name(c, k)
                    if nm ~= "" then live[synth_id(nm)] = true end
                else
                    local nm = player_name(c, k)
                    if nm ~= "" then
                        local id = synth_id(nm)
                        live[id] = true
                        if not roster[id] then
                            roster[id] = { name = nm, joined_unix_ms = unix_ms() }
                            log("joined: " .. nm .. " [" .. id .. "]")
                        end
                        roster[id].name = nm
                        roster[id].ping_ms = player_ping(c)
                        local loc = pawn_location(c)
                        if loc then
                            roster[id].x = loc.x
                            roster[id].y = loc.y
                            roster[id].z = loc.z
                            roster[id].pos_unix_ms = unix_ms()
                        end
                    end
                end
            end
        end
    end
    for id, entry in pairs(roster) do
        if not live[id] then
            log("left: " .. tostring(entry.name) .. " [" .. id .. "]")
            roster[id] = nil
        end
    end
end

local function write_roster(world_name)
    local now = unix_ms()
    local parts = {}
    for id, entry in pairs(roster) do
        table.insert(parts, string.format(
            '{"SolarpunkUserId":"%s","DisplayName":"%s","ConnectedAtUnixMs":%d,"LastPacketUnixMs":%d,"PingMs":%d,"X":%.3f,"Y":%.3f,"Z":%.3f,"PosUnixMs":%d}',
            escape_json(id), escape_json(entry.name or "Unknown"),
            entry.joined_unix_ms or now, now, entry.ping_ms or 0,
            entry.x or 0, entry.y or 0, entry.z or 0, entry.pos_unix_ms or 0))
    end
    local json = '{"unix_ms":' .. now
        .. ',"world":{"name":"' .. escape_json(world_name or "") .. '"}'
        .. ',"players":[' .. table.concat(parts, ',') .. ']}'

    local tmp = ROSTER_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(json)
    f:close()
    pcall(function() os.remove(ROSTER_FILE) end)
    if not pcall(function() os.rename(tmp, ROSTER_FILE) end) then
        log("roster write failed: could not replace " .. tostring(ROSTER_FILE))
    end
end

-- Initial empty write so the file always exists once the mod loads.
write_roster("")

-- 5s scheduler task (game thread): scan, then write the snapshot. The file
-- is tiny so writing on the game thread is cheap, and it removes the old
-- async-thread write (cross-thread Lua was the full-stack crash surface).
SP.every("roster-snapshot", 5000, 1000, function()
    pcall(rescan)
    local world_name = ""
    pcall(function() world_name = get_world_name() end)
    pcall(function() write_roster(world_name) end)
end)

log("periodic roster snapshot every 5s")
