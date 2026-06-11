-- SolarpunkHost: the headless host pipeline. Transport swap -> named
-- persistent world -> HostGame -> per-player net-id save/load keying ->
-- periodic world save -> host status file.
--
-- This is host_netid_enforcer.lua (the proven transport+net-id base, kept
-- verbatim where possible — see that file for the full root-cause notes)
-- EXTENDED with world persistence + status publishing:
--
-- WORLD PERSISTENCE (proven on the box 2026-06-10):
--   BP_SkyGameInstance_C has an FString property `WorldSaveName`. HostGame()
--   reads it: the save system loads %LOCALAPPDATA%\Solarpunk\Saved\SaveGames\
--   <WorldSaveName>.sav if present ("LVP_SaveSystem: Loaded savegame...") or
--   creates a fresh world ("LVP_SaveSystem: No Savegame available. Created
--   new one."). BPC_SaveManager_C:SaveToDisk() writes <WorldSaveName>.sav on
--   demand; the game also runs its own autosave timer. So: set
--   gi.WorldSaveName = <configured name> BEFORE HostGame() and the instance
--   gets a stable named world that persists across restarts. Per-instance
--   isolation comes from the panel launching each instance with its own
--   LOCALAPPDATA (cmd /c set LOCALAPPDATA=<instance dir> && exe...).
--
-- NET-ID (see host_netid_enforcer.lua / IMPLEMENTATION-SPEC.md):
--   load key is a BP FString param stuck at "TESTING UID"; fix = re-issue
--   BeginLoadData(synth) from the tick loop after each natural load; save key
--   (UniquePlayerID variable) set every tick to the same synth id.
--   synth = "765611900" + crc32(lower(playername)) % 1e9.
--
-- CONFIG (SolarpunkServer\appsettings.json, panel-written):
--   "WorldName": "<name>"        world save slot. Default "World1".
--   "SaveIntervalSeconds": 300   forced SaveToDisk cadence (the game's own
--                                autosave still runs; this is the floor).
--
-- STATUS (SolarpunkServer\.solarpunk-host-status, key=value lines):
--   hosting=0|1, world=<name>, updated=<unix>, reason=<short>
--   The supervisor can poll this to know the world is actually up.

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local SCRIPT_SOURCE = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
if SCRIPT_SOURCE:sub(1, 1) == "@" then SCRIPT_SOURCE = SCRIPT_SOURCE:sub(2) end

local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkHost.log"

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkHost] " .. tostring(msg) .. "\n")
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
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

local function extract_json_string(json_text, key)
    if not json_text then return nil end
    local v = json_text:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    return v
end

local function extract_json_number(json_text, key)
    if not json_text then return nil end
    local v = json_text:match('"' .. key .. '"%s*:%s*(%-?%d+)')
    return v and tonumber(v) or nil
end

local SP_DIR = find_solarpunkserver_dir()
local WORLD_NAME = "World1"
local SAVE_INTERVAL_S = 300
if SP_DIR then
    local body = read_all(SP_DIR .. "\\appsettings.json")
    local w = extract_json_string(body, "WorldName")
    -- Sanitize: the name becomes a file name (<name>.sav). Allow word chars,
    -- dash, space; cap length. Anything else falls back to the default.
    if w and w ~= "" then
        w = w:gsub("[^%w%-%_ ]", ""):sub(1, 40)
        if w ~= "" then WORLD_NAME = w end
    end
    local s = extract_json_number(body, "SaveIntervalSeconds")
    if s and s >= 30 then SAVE_INTERVAL_S = s end
    log("config: SolarpunkServer dir=" .. SP_DIR .. " WorldName=" .. WORLD_NAME ..
        " SaveIntervalSeconds=" .. SAVE_INTERVAL_S)
else
    log("config: SolarpunkServer dir not found; defaults WorldName=" .. WORLD_NAME)
end

local HOST_STATUS = SP_DIR and (SP_DIR .. "\\.solarpunk-host-status") or nil
local function write_host_status(hosting, reason)
    if not HOST_STATUS then return end
    local tmp = HOST_STATUS .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write("hosting=" .. (hosting and "1" or "0") .. "\n" ..
            "world=" .. WORLD_NAME .. "\n" ..
            "updated=" .. tostring(os.time()) .. "\n" ..
            "reason=" .. tostring(reason or "") .. "\n")
    f:close()
    os.remove(HOST_STATUS)
    pcall(function() os.rename(tmp, HOST_STATUS) end)
end
write_host_status(false, "booting")

-- Shared scheduler/state from SolarpunkServerRuntime (see the STABILITY
-- CONTRACT comment there). All periodic work below runs as game-thread
-- scheduler tasks — no mod-owned LoopAsync, no async-thread native access.
local SP = _G.SolarpunkSP
if not SP then
    error("SolarpunkHost requires SolarpunkServerRuntime (load via the orchestrator)")
end

-- ---------------------------------------------------------------------------
-- Net-id keying (verbatim from host_netid_enforcer.lua — see that file for
-- the proven dead-ends; do not "simplify" this back into a hook param write).
-- ---------------------------------------------------------------------------

local hosted = false
local pending = {}     -- [controller addr] = countdown until BeginLoadData re-issue

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
local function synthId(seed)
    if not seed or #seed == 0 then seed = "spx" end
    return string.format("765611900%09d", crc32(string.lower(seed)) % 1000000000)
end
-- Strip the SolarpunkAuth name-channel token (`<character>__SPPW__<password>`)
-- so the save/load key is derived from the character name ONLY. Must stay
-- byte-identical with SolarpunkAuth.AUTH_DELIM / SolarpunkRoster.clean_name.
local AUTH_DELIM = "__SPPW__"
local function clean_name(raw)
    raw = tostring(raw or "")
    local i = raw:find(AUTH_DELIM, 1, true)
    if i then return raw:sub(1, i - 1) end
    return raw
end
local function pname(c)
    local nm = ""
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then nm = ps:GetPlayerName():ToString() end
    end)
    return clean_name(nm)
end
local function akey(c)
    local k = 0
    pcall(function() k = c:GetAddress() end)
    return k
end
local function isSynth(s) return s ~= nil and s:find("^765611900%d") ~= nil end

local function tick()
    local cs = SP.controllers()
    if not cs then return end
    for _, c in ipairs(cs) do
        if c and c:IsValid() and not c:IsLocalPlayerController() then
            local k = akey(c)
            -- never touch a controller auth already kicked (dying object)
            if not SP.kicked[k] then
                local nm = pname(c)
                if nm ~= "" then
                    local sid = synthId(nm)
                    pcall(function() c.UniquePlayerID = sid end)        -- save key (per-player)
                    if pending[k] then
                        pending[k] = pending[k] - 1
                        if pending[k] <= 0 then
                            pending[k] = nil
                            pcall(function() c:BeginLoadData(sid) end)  -- load key, lands last
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Boot: GI found -> world name -> transport swap -> load-detect hook -> host.
-- ---------------------------------------------------------------------------

-- THE single BeginLoadData hook for the whole stack (SolarpunkAuth's gate
-- runs off its sweep; it no longer registers a second hook on this UFunction
-- — two Lua hooks on the same BP function dispatching during the join
-- transition was a prime crash suspect on UE4SS-on-5.7). Besides arming the
-- net-id re-issue, the hook stamps SP.transition so Roster/Chat/Auth keep
-- their hands off the controller until the join transition settles.
local BLD_CLASS = "/Game/Code/Character/BP_MainPlayerController.BP_MainPlayerController_C"
local ld_hooked, ld_tries = false, 0
local function try_install_bld_hook()
    if ld_hooked then return end
    ld_tries = ld_tries + 1
    local ok = pcall(function()
        RegisterHook(BLD_CLASS .. ":BeginLoadData", function(self, p1)
            pcall(function()
                local c = self:get()
                if not c or not c:IsValid() then return end
                if c:IsLocalPlayerController() then return end
                local k = akey(c)
                SP.transition[k] = os.time()       -- join/load transition in flight
                local key = ""
                pcall(function() key = p1:get():ToString() end)
                if not isSynth(key) then pending[k] = 6 end -- ~6*250ms after last natural load
            end)
        end, function() end)
    end)
    if ok then
        ld_hooked = true
        log("BeginLoadData hook installed (attempt " .. ld_tries .. ")")
    elseif ld_tries >= 60 then
        ld_hooked = true -- stop retrying
        log("BeginLoadData hook FAILED after " .. ld_tries .. " tries")
    end
end

-- Boot: GI found -> world name -> transport swap -> host. All on the game
-- thread via the shared scheduler (FindFirstOf/RegisterHook off-thread was
-- part of the crash surface).
SP.every("host-boot", 1000, 0, function()
    if hosted then return end
    local gi = FindFirstOf("BP_SkyGameInstance_C")
    if not (gi and gi:IsValid()) then return end
    hosted = true

    -- world: name the persistent save slot BEFORE hosting. HostGame's
    -- save-system init loads <WorldSaveName>.sav or creates it.
    local ok_w, err_w = pcall(function() gi.WorldSaveName = WORLD_NAME end)
    log("WorldSaveName=" .. WORLD_NAME .. " set ok=" .. tostring(ok_w) ..
        (ok_w and "" or (" err=" .. tostring(err_w))))

    -- transport: force IpNetDriver so the headless host binds real UDP
    local eng = FindFirstOf("GameEngine")
    pcall(function()
        local defs = eng.NetDriverDefinitions
        for i = 1, defs:GetArrayNum() do
            local d = defs[i]
            if d.DefName:ToString() == "GameNetDriver" then
                d.DriverClassName = FName("/Script/OnlineSubsystemUtils.IpNetDriver")
                d.DriverClassNameFallback = FName("/Script/OnlineSubsystemUtils.IpNetDriver")
            end
        end
    end)

    pcall(function() gi:HostGame() end)
    log("HostGame() called (world=" .. WORLD_NAME .. ")")
    write_host_status(true, "hostgame_called")
end)

-- Hook install retry: on some game builds (e.g. retail build 23659698)
-- BP_MainPlayerController loads AFTER mods start, so a one-shot RegisterHook
-- throws "no UFunction found". Retry until it installs (build-churn robust).
-- Gated on `hosted` so we don't churn class lookups before boot.
SP.every("host-bld-hook", 1000, 250, function()
    if not hosted then return end
    try_install_bld_hook()
end)

-- net-id enforcement tick (every scheduler tick = 250ms, unchanged cadence)
SP.every("host-netid", 250, 0, function()
    if not hosted then return end
    tick()
end)

-- forced world save cadence (the game autosaves too; this is the floor)
SP.every("host-save", SAVE_INTERVAL_S * 1000, 2000, function()
    if not hosted then return end
    local sm = FindFirstOf("BPC_SaveManager_C")
    if sm and sm:IsValid() then
        local ok = pcall(function() sm:SaveToDisk() end)
        log("periodic SaveToDisk ok=" .. tostring(ok))
    end
end)

-- heartbeat into the host status file so the supervisor sees liveness
SP.every("host-heartbeat", 30000, 4000, function()
    if not hosted then return end
    write_host_status(true, "alive")
end)
