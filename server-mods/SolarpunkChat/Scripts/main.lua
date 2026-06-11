-- SolarpunkChat: server-side chat dispatcher + MOTD delivery.
-- Port of Beacon's chat plane (BeaconModKit file-IPC + BeaconChat dispatcher)
-- to Solarpunk, collapsed into one self-contained mod (no ModKit dependency).
--
-- Solarpunk has no chat *input* UI, but it DOES natively render server-pushed
-- ClientMessage on the in-game message widget (SW_IngameMessage_C). So chat
-- DISPLAY rides the game's own renderer — no custom UMG overlay. The earlier
-- SolarpunkHud (BeaconHud port) REPARENTED SW_IngameMessage_C to re-render the
-- feed, which was redundant AND crashed the game on real-client UMG render
-- (isolated 2026-06-10: host stack stable, HUD = the crash). SolarpunkHud is
-- REMOVED; this mod's native ClientMessage fanout IS the chat display path.
-- (In-game *typing* would need a safe UMG input — deferred; Lantern ships none.)
--
--   1. Drains SolarpunkServer's chat-inbound.json (written by ChatService on
--      every RCON `say`, HTTP /api/v1/chat/say and /chat/player post) every
--      second and fans each message out to all connected PlayerControllers
--      via the ClientMessage UFUNCTION — the game renders it natively.
--   2. Sends the MOTD (SolarpunkServer\motd.txt, fresh-read per join) to each
--      joining player via ClientMessage, and logs the join.
--   3. Appends join/leave system messages to chat-outbound.json so
--      SolarpunkServer's ChatService ring buffer / chat history / HTTP
--      /chat/recent reflect session activity.
--
-- File contracts (SolarpunkServer ChatService, protocol/chat-v1.md):
--   chat-inbound.json  : {"version":1,"messages":[{ts,sender,target,channel,msg,color?}]}
--                        C# appends (capped 200) — Lua drains by rewriting
--                        {"version":1,"messages":[]}.
--   chat-outbound.json : same schema; Lua appends, C# drains.
--   motd.txt           : plain text, single line (ChatService normalises).

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local SCRIPT_SOURCE = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
if SCRIPT_SOURCE:sub(1, 1) == "@" then SCRIPT_SOURCE = SCRIPT_SOURCE:sub(2) end

local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkChat.log"

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkChat] " .. tostring(msg) .. "\n")
end

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
        if file_exists(c .. "\\appsettings.json") then return c end
    end
    return nil
end

local SP_DIR = find_solarpunkserver_dir()
if not SP_DIR then
    log("SolarpunkServer dir not found; chat plane disabled")
    return
end

-- Shared scheduler/state from SolarpunkServerRuntime (see the STABILITY
-- CONTRACT comment there): all polling runs as game-thread scheduler tasks,
-- and delivery (ClientMessage RPC) skips controllers that are mid-join-
-- transition (SP.settled) or kicked (SP.kicked) — RPC fanout into a
-- half-loaded/dying connection was part of the full-stack crash surface.
local SP = _G.SolarpunkSP
if not SP then
    error("SolarpunkChat requires SolarpunkServerRuntime (load via the orchestrator)")
end
log("SolarpunkServer dir: " .. SP_DIR)
local INBOUND = SP_DIR .. "\\chat-inbound.json"
local OUTBOUND = SP_DIR .. "\\chat-outbound.json"
local MOTD = SP_DIR .. "\\motd.txt"

-- -------------------------- tiny JSON helpers ----------------------------
-- Scoped to the chat-v1 file shape (flat string/number fields, no nesting).

local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', string.byte(c)) end)
    return s
end

local function unescape_json(s)
    return (s:gsub('\\(.)', function(c)
        if c == 'n' then return '\n' elseif c == 'r' then return '\r'
        elseif c == 't' then return '\t' else return c end
    end))
end

-- Parse the messages array: returns list of {ts,sender,channel,msg}.
-- Tolerant scanner: finds each {...} object and pulls known keys.
local function parse_messages(body)
    local out = {}
    if not body then return out end
    local arr = body:match('"messages"%s*:%s*%[(.*)%]')
    if not arr or arr:match('^%s*$') then return out end
    for obj in arr:gmatch('%b{}') do
        local m = {}
        m.ts = tonumber(obj:match('"ts"%s*:%s*(%d+)')) or 0
        local sender = obj:match('"sender"%s*:%s*"((\\.|[^"\\])*)"') or obj:match('"sender"%s*:%s*"([^"]*)"')
        local msg = obj:match('"msg"%s*:%s*"((\\.|[^"\\])*)"') or obj:match('"msg"%s*:%s*"([^"]*)"')
        local channel = obj:match('"channel"%s*:%s*"([^"]*)"')
        m.sender = sender and unescape_json(sender) or "Server"
        m.msg = msg and unescape_json(msg) or ""
        m.channel = channel or "system"
        if m.msg ~= "" then table.insert(out, m) end
    end
    return out
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function write_atomic(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    os.remove(path)
    return (pcall(function() return os.rename(tmp, path) end))
end

-- Append a message to chat-outbound.json (read-modify-write; ChatService is
-- the single drainer and tolerates a lost race by re-reading next tick).
local function outbound_send(sender, msg, channel)
    local body = read_all(OUTBOUND)
    local msgs = body and parse_messages(body) or {}
    table.insert(msgs, { ts = os.time(), sender = sender, channel = channel or "system", msg = msg })
    local parts = {}
    for _, m in ipairs(msgs) do
        table.insert(parts, string.format(
            '{"ts":%d,"sender":"%s","target":"all","channel":"%s","msg":"%s"}',
            m.ts or os.time(), escape_json(m.sender), escape_json(m.channel or "system"), escape_json(m.msg)))
    end
    write_atomic(OUTBOUND, '{"version":1,"messages":[' .. table.concat(parts, ',') .. ']}')
end

-- ------------------------- in-game delivery ------------------------------

local function chat_akey(pc)
    local k = 0
    pcall(function() k = pc:GetAddress() end)
    return k
end

-- True when it is safe to push an RPC at this controller: valid, not kicked
-- (dying), not mid-join-transition. The local listen-host controller never
-- gets transition stamps or kick marks, so it always passes.
local function deliverable(pc)
    if not (pc and pc:IsValid()) then return false end
    local k = chat_akey(pc)
    if SP.kicked[k] then return false end
    return SP.settled(k)
end

local function fanout(text)
    local n = 0
    local ok_outer = pcall(function()
        local pcs = SP.controllers()
        if not pcs then return end
        for _, pc in ipairs(pcs) do
            local ok = pcall(function()
                if deliverable(pc) and pc.ClientMessage then
                    pc:ClientMessage(text, FName("Default"), 0.0)
                end
            end)
            if ok then n = n + 1 end
        end
    end)
    if not ok_outer then return 0 end
    return n
end

local function read_motd()
    local body = read_all(MOTD)
    if not body then return "" end
    return (body:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ------------------------ inbound drain loop ------------------------------

SP.every("chat-inbound", 1000, 250, function()
    local body = read_all(INBOUND)
    if not body then return end
    local msgs = parse_messages(body)
    if #msgs == 0 then return end
    -- Drain first (single consumer = us) so a fanout fault can't loop
    -- the same batch forever.
    write_atomic(INBOUND, '{"version":1,"messages":[]}')
    for _, m in ipairs(msgs) do
        local label = (m.channel == "admin") and "[Admin] " or
                      (m.channel == "player") and "" or "[Server] "
        local line = (m.sender ~= "" and m.sender ~= "Server")
            and (label .. m.sender .. ": " .. m.msg)
            or (label .. m.msg)
        local delivered = fanout(line)   -- already on the game thread
        log("INBOUND channel=" .. m.channel .. " sender=" .. m.sender ..
            " msg=" .. m.msg .. " delivered=" .. tostring(delivered))
    end
end)

-- ------------------------- MOTD + join/leave ------------------------------
-- IMPORTANT (proven on the box 2026-06-10): /Script/Engine.GameModeBase:
-- K2_PostLogin and :Logout do NOT fire for remote IpNetDriver clients on this
-- build (the game's custom login path drives joins through BP_MainPlayerController
-- :BeginLoadData and BP_SurvivalGameMode:K2_OnLogout). So MOTD/join hangs off
-- BeginLoadData (deduped per controller — it fires repeatedly per join) and
-- leave hangs off K2_OnLogout.

-- Strip the SolarpunkAuth name-channel token so chat shows the character name
-- only (byte-identical with SolarpunkAuth.AUTH_DELIM / SolarpunkHost.clean_name).
local AUTH_DELIM = "__SPPW__"
local function clean_name(raw)
    raw = tostring(raw or "")
    local i = raw:find(AUTH_DELIM, 1, true)
    if i then return raw:sub(1, i - 1) end
    return raw
end

local function player_name(pc)
    local nm = ""
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then nm = ps:GetPlayerName():ToString() end
    end)
    return clean_name(nm)
end

local function akey(pc)
    local k = 0
    pcall(function() k = pc:GetAddress() end)
    return k
end

-- Join/leave + MOTD by POLLING, not hooks. The engine join/leave UFunctions
-- (K2_PostLogin / Logout) don't fire for remote clients on this build, and
-- stacking a third RegisterHook on BP_MainPlayerController:BeginLoadData
-- (Host's net-id enforcer and Auth's gate already hook it) proved unreliable.
-- A 1s sweep over the live remote controllers is hook-independent: a newly
-- seen remote PC with a non-empty name gets one MOTD (ClientMessage, the
-- delivery path proven on the box) + a join broadcast; a PC that disappears
-- emits a leave broadcast. Mirrors SolarpunkRoster's player tracking.
local greeted = {}    -- [addr] = display name (present == still connected + greeted)

SP.every("chat-joinleave", 1000, 750, function()
    local cs = SP.controllers()
    local live = {}
    if cs then
        for _, pc in ipairs(cs) do
            if pc and pc:IsValid() and not pc:IsLocalPlayerController() then
                local k = akey(pc)
                local name = player_name(pc)
                if name ~= "" and not SP.kicked[k] then
                    live[k] = name
                    -- greet only once the join transition has settled —
                    -- ClientMessage at the exact join boundary pokes a
                    -- half-loaded connection (crash surface). The MOTD just
                    -- arrives a few seconds after spawn instead.
                    if not greeted[k] and SP.settled(k) then
                        greeted[k] = name
                        outbound_send("Server", name .. " joined the server", "system")
                        local motd = read_motd()
                        if motd ~= "" then
                            pcall(function() pc:ClientMessage("[MOTD] " .. motd, FName("Default"), 0.0) end)
                            log("MOTD sent to " .. name)
                        end
                    end
                end
            end
        end
    end
    -- anyone we greeted who is no longer live has left
    for k, nm in pairs(greeted) do
        if not live[k] then
            greeted[k] = nil
            outbound_send("Server", nm .. " left the server", "system")
            log("leave: " .. nm)
        end
    end
end)
log("MOTD/join/leave poll task active (1s, game-thread scheduler)")

log("chat plane active: inbound poll 1s, outbound join/leave, MOTD on join")
