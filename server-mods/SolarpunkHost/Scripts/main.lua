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
local HOST_IDENTITY_SEED = "sp-host"
local INSTANCE_DIR = SP_DIR and SP_DIR:match("^(.*)[\\/]SolarpunkServer$")
local SAVE_GAMES_DIR = INSTANCE_DIR and (INSTANCE_DIR .. "\\UserDir\\Saved\\SaveGames") or nil
local SAVE_INTERVAL_S = 300
if SP_DIR then
    LOG_DIR = SP_DIR .. "\\logs"
    os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
    LOG_FILE = LOG_DIR .. "\\SolarpunkHost.log"
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
    local instance_id = extract_json_string(body, "InstanceId")
    if instance_id and instance_id ~= "" then
        instance_id = instance_id:gsub("[^%w%-%_]", ""):sub(1, 60)
        if instance_id ~= "" then HOST_IDENTITY_SEED = "host-" .. instance_id end
    end
    log("config: SolarpunkServer dir=" .. SP_DIR .. " WorldName=" .. WORLD_NAME ..
        " SaveIntervalSeconds=" .. SAVE_INTERVAL_S ..
        " HostIdentitySeed=" .. HOST_IDENTITY_SEED ..
        " SaveGamesDir=" .. tostring(SAVE_GAMES_DIR))
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

local WORLD_SLOT_FIELDS = {
    "WorldSaveName",
    "WorldName",
    "SaveGameName",
    "SaveGameSlotName",
    "SaveSlotName",
    "SlotName",
    "SlotNameStr",
    "CurrentSaveName",
    "CurrentSaveGameName",
    "CurrentSaveSlotName",
    "SelectedSaveName",
    "SelectedSaveGameName",
    "SelectedSaveSlotName",
    "LoadedSaveName",
}

local function is_world_slot_field_name(name)
    local lower = tostring(name or ""):lower()
    if lower:find("player", 1, true) or lower:find("server", 1, true) or
        lower:find("display", 1, true) or lower:find("profile", 1, true) then
        return false
    end
    return lower == "worldname" or lower == "worldsavename" or lower:match("^worldname_") or
        lower:match("^worldsavename_") or lower:find("worldsave", 1, true) or
        lower:find("savegame", 1, true) or lower:find("saveslot", 1, true) or
        lower:find("slotname", 1, true) or lower:find("slot_name", 1, true)
end

local function read_string_prop(obj, pname)
    local v
    if not pcall(function() v = obj[pname] end) then return nil end
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

local dynamic_world_slot_log = {}
local function set_dynamic_world_slot_fields(obj, label)
    if not (obj and obj:IsValid()) then return false end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not (cls and cls:IsValid()) then return false end
    local did = false
    local guard = 0
    while cls and cls:IsValid() and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pfull = tostring(prop:GetFullName())
                    local kind = pfull:match("^(%a+)Property")
                    if kind ~= "Str" and kind ~= "Name" and kind ~= "Text" then return end
                    local pname = prop:GetFName():ToString()
                    if not is_world_slot_field_name(pname) then return end
                    local before = read_string_prop(obj, pname)
                    if before == WORLD_NAME then return end
                    local ok = pcall(function() obj[pname] = WORLD_NAME end)
                    local after = read_string_prop(obj, pname)
                    if ok and after == WORLD_NAME then
                        did = true
                        local key = tostring(label) .. "." .. tostring(pname)
                        if not dynamic_world_slot_log[key] then
                            dynamic_world_slot_log[key] = true
                            log(label .. "." .. pname .. "=" .. tostring(after) ..
                                " dynamic-world-slot before=" .. tostring(before))
                        end
                    end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not (sup and sup:IsValid()) then break end
        cls = sup
    end
    return did
end

local function set_world_slot_fields(obj, label)
    if not (obj and obj:IsValid()) then return end
    for _, pname in ipairs(WORLD_SLOT_FIELDS) do
        local ok = pcall(function() obj[pname] = WORLD_NAME end)
        if ok then
            log(label .. "." .. pname .. "=" .. tostring(read_string_prop(obj, pname)))
        end
    end
    set_dynamic_world_slot_fields(obj, label)
end

local world_slot_enforce_log = {}
local function enforce_world_slot_fields(obj, label)
    if not (obj and obj:IsValid()) then return false end
    local did = false
    for _, pname in ipairs(WORLD_SLOT_FIELDS) do
        local before = read_string_prop(obj, pname)
        local ok = pcall(function() obj[pname] = WORLD_NAME end)
        if ok then
            local after = read_string_prop(obj, pname)
            if before ~= after then
                did = true
                local key = tostring(label) .. "." .. pname .. "=" .. tostring(after)
                if not world_slot_enforce_log[key] then
                    world_slot_enforce_log[key] = true
                    log(label .. "." .. pname .. "=" .. tostring(after) ..
                        " enforced before=" .. tostring(before))
                end
            end
        end
    end
    did = set_dynamic_world_slot_fields(obj, label) or did
    return did
end

local function enforce_world_slot_runtime(reason)
    local did = false
    local gi = FindFirstOf("BP_SkyGameInstance_C")
    if gi and gi:IsValid() then
        did = enforce_world_slot_fields(gi, "GameInstance.runtime." .. tostring(reason or "")) or did
    end
    local sm = FindFirstOf("BPC_SaveManager_C")
    if sm and sm:IsValid() then
        did = enforce_world_slot_fields(sm, "SaveManager.runtime." .. tostring(reason or "")) or did
    end
    for _, cname in ipairs({ "LVP_SaveSystem_C", "LVP_SaveSystem" }) do
        local ok, objs = pcall(FindAllOf, cname)
        if ok and objs then
            for _, obj in ipairs(objs) do
                if obj and obj:IsValid() then
                    did = enforce_world_slot_fields(obj, cname .. ".runtime." .. tostring(reason or "")) or did
                end
            end
        end
    end
    return did
end

local function log_saveish_string_props(obj, label)
    if not (obj and obj:IsValid()) then return end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not (cls and cls:IsValid()) then return end
    local guard = 0
    while cls and cls:IsValid() and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pfull = tostring(prop:GetFullName())
                    local kind = pfull:match("^(%a+)Property")
                    if kind == "Str" or kind == "Name" or kind == "Text" then
                        local pname
                        pcall(function() pname = prop:GetFName():ToString() end)
                        local lower = pname and pname:lower() or ""
                        if lower:find("save", 1, true) or lower:find("slot", 1, true) or
                            lower:find("world", 1, true) or lower:find("name", 1, true) then
                            log(label .. ".prop." .. pname .. "=" .. tostring(read_string_prop(obj, pname)))
                        end
                    end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not (sup and sup:IsValid()) then break end
        cls = sup
    end
end

local function param_string(p)
    if type(p) == "string" then return p end
    local v
    if not pcall(function() v = p:get() end) then return nil end
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

local function rewrite_world_slot_param(p, label)
    local before = param_string(p)
    if not before or before == "" or before == WORLD_NAME then return end
    if before == "Options" or before == "gp_data" then return end
    enforce_world_slot_runtime("slot-rewrite-" .. tostring(label or ""))
    local ok = pcall(function() p:set(WORLD_NAME) end)
    log("slot rewrite " .. label .. ": " .. tostring(before) .. " -> " .. WORLD_NAME ..
        " ok=" .. tostring(ok) .. " after=" .. tostring(param_string(p)))
end

local mirror_log = {}
local function latest_relevant_save_name()
    if not SAVE_GAMES_DIR then return nil end
    local p = io.popen('dir /b /a-d /o-d "' .. SAVE_GAMES_DIR .. '\\*.sav" 2>NUL')
    if not p then return nil end
    for name in p:lines() do
        local lower = tostring(name or ""):lower()
        if lower ~= "gp_data.sav" and lower ~= "options.sav" then
            p:close()
            return name
        end
    end
    p:close()
    return nil
end

local function latest_active_world_save()
    if not SAVE_GAMES_DIR then return nil end
    local latest = latest_relevant_save_name()
    if latest and latest:lower() == (WORLD_NAME .. ".sav"):lower() then return nil end
    local p = io.popen('dir /b /a-d /o-d "' .. SAVE_GAMES_DIR .. '\\*.sav" 2>NUL')
    if not p then return nil end
    local world_lower = (WORLD_NAME .. ".sav"):lower()
    for name in p:lines() do
        local lower = tostring(name or ""):lower()
        if lower ~= world_lower and lower ~= "gp_data.sav" and lower ~= "options.sav" then
            p:close()
            return name
        end
    end
    p:close()
    return nil
end

local function mirror_active_world_save(reason)
    if not SAVE_GAMES_DIR then return false end
    local source_name = latest_active_world_save()
    if not source_name then return false end
    local src = SAVE_GAMES_DIR .. "\\" .. source_name
    local dst = SAVE_GAMES_DIR .. "\\" .. WORLD_NAME .. ".sav"
    local data = read_all(src)
    if not data or #data == 0 then return false end
    local tmp = dst .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    os.remove(dst)
    local ok = os.rename(tmp, dst)
    if not ok then os.remove(tmp) end
    local key = tostring(source_name) .. ":" .. tostring(#data) .. ":" .. tostring(ok)
    if not mirror_log[key] then
        mirror_log[key] = true
        log("world save mirror " .. tostring(source_name) .. " -> " .. WORLD_NAME ..
            ".sav reason=" .. tostring(reason or "") ..
            " ok=" .. tostring(ok) .. " bytes=" .. tostring(#data))
    end
    return ok
end

local function archive_orphaned_world_saves(reason)
    if not SAVE_GAMES_DIR then return 0 end
    local p = io.popen('dir /b /a-d "' .. SAVE_GAMES_DIR .. '\\*.sav" 2>NUL')
    if not p then return 0 end
    local archive_dir = SAVE_GAMES_DIR .. "\\_sundial_orphaned_saves"
    os.execute('mkdir "' .. archive_dir .. '" >NUL 2>NUL')
    local world_lower = (WORLD_NAME .. ".sav"):lower()
    local count = 0
    local stamp = os.date("%Y%m%d%H%M%S")
    for name in p:lines() do
        local lower = tostring(name or ""):lower()
        if lower ~= world_lower and lower ~= "gp_data.sav" and lower ~= "options.sav" then
            local src = SAVE_GAMES_DIR .. "\\" .. name
            local dst = archive_dir .. "\\" .. stamp .. "-" .. name
            local suffix = 0
            while file_exists(dst) and suffix < 100 do
                suffix = suffix + 1
                dst = archive_dir .. "\\" .. stamp .. "-" .. tostring(suffix) .. "-" .. name
            end
            local ok = os.rename(src, dst)
            log("orphan world save archive " .. tostring(name) ..
                " reason=" .. tostring(reason or "") .. " ok=" .. tostring(ok) ..
                " dst=" .. tostring(dst))
            if ok then count = count + 1 end
        end
    end
    p:close()
    if count > 0 then
        log("orphan world save archive complete count=" .. tostring(count) ..
            " reason=" .. tostring(reason or ""))
    end
    return count
end

local function normalize_save_games_dir(reason)
    local mirrored = mirror_active_world_save(reason)
    -- Leave engine-generated world slot files in place. The game can continue
    -- probing that original slot after we mirror it to World1.sav; moving it
    -- causes missing-save reads during joins.
    local archived = 0
    if mirrored or archived > 0 or tostring(reason or "") ~= "sweep" then
        log("save dir normalized reason=" .. tostring(reason or "") ..
            " mirrored=" .. tostring(mirrored) ..
            " archived=" .. tostring(archived))
    end
end

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
local pending = {}     -- [controller addr] = legacy reissue state; kept for cleanup compatibility
local loaded_sid = {}  -- [controller addr] = last synthetic id observed for the controller
local first_seen_at = {}
local blocked_reissue_sid = {}
local blocked_reissue_log = {}
local MAX_BEGIN_LOAD_REISSUE_AGE = 12
SP.invalid_identity = SP.invalid_identity or {}

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
local HOST_SYNTH_ID = synthId(HOST_IDENTITY_SEED)
log("host local synthetic id=" .. HOST_SYNTH_ID .. " seed=" .. HOST_IDENTITY_SEED)
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
local function is_legacy_launcher_identity(nm)
    local base, suffix = tostring(nm or ""):match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    if not base or not suffix or #suffix < 8 then return false end
    if base == "server" or base:match("^DESKTOP") or base:match("%-PC$") then return false end
    return base:match("%l") ~= nil
end
local function pname(c)
    local nm = ""
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then nm = ps:GetPlayerName():ToString() end
    end)
    return clean_name(nm)
end
local function is_transient_identity_name(nm)
    if nm == "TESTING UID" or nm == "ERROR, BAD UNIQUE NET ID" then return true end
    if is_legacy_launcher_identity(nm) then return false end
    if tostring(nm or ""):match("^DESKTOP%-[A-Z0-9%-]+$") then return true end
    if tostring(nm or ""):match("^[A-Z0-9_%-]+%-PC%-[0-9A-Fa-f]+$") then return true end
    local suffix = tostring(nm or ""):match("^[%w_%-]+%-([0-9A-Fa-f]+)$")
    return suffix ~= nil and #suffix >= 8
end
local transient_log = {}
local function stable_pname(c, k)
    local raw = pname(c)
    local nm = raw
    if SP.canonical_name and SP.canonical_name[k] and SP.canonical_name[k] ~= "" then
        nm = SP.canonical_name[k]
    end
    if nm == "" then return nil end
    if is_transient_identity_name(nm) then
        local key = tostring(k) .. ":" .. tostring(nm)
        if not transient_log[key] then
            transient_log[key] = true
            log("save identity pending [" .. tostring(k) .. "] transient name=" .. tostring(nm))
        end
        return nil
    end
    return nm
end
local function akey(c)
    local k = 0
    pcall(function() k = c:GetAddress() end)
    return k
end
local function isSynth(s) return s ~= nil and s:find("^765611900%d") ~= nil end
local function is_blank_id(s)
    s = tostring(s or "")
    return s == "" or s == "TESTING UID" or s == "ERROR, BAD UNIQUE NET ID" or
        s:match("^0+$") ~= nil
end
local function is_player_identity_field_name(name)
    local lower = tostring(name or ""):lower()
    return lower == "id" or lower:match("^id_") or
        lower:find("uniqueplayerid", 1, true) or lower:find("unique_player_id", 1, true) or
        lower:find("playerid", 1, true) or lower:find("player_id", 1, true) or
        lower:find("playerdataid", 1, true) or lower:find("player_data_id", 1, true) or
        lower:find("uniqueid", 1, true) or lower:find("unique_id", 1, true) or
        lower:find("steamid", 1, true) or lower:find("steam_id", 1, true) or
        lower:find("userid", 1, true) or lower:find("user_id", 1, true)
end
local function pawn_of(c)
    if not (c and c:IsValid()) then return nil end
    local pawn
    pcall(function() pawn = c.Pawn end)
    if pawn and pawn:IsValid() then return pawn end
    pcall(function() pawn = c:K2_GetPawn() end)
    if pawn and pawn:IsValid() then return pawn end
    return nil
end
local stamp_unique_player_id
local function validish(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    if ok then return v end
    return type(obj) ~= "string" and type(obj) ~= "number" and type(obj) ~= "boolean"
end
local function object_synthetic_id(obj)
    if not validish(obj) then return nil end
    for _, field in ipairs({
        "UniquePlayerID", "UniquePlayerId", "PlayerID", "PlayerId",
        "PlayerIDString", "PlayerIdString", "UniqueID", "UniqueId",
        "SteamID", "SteamId", "UserID", "UserId", "OwnerID", "OwnerId",
    }) do
        local sid = read_string_prop(obj, field)
        if isSynth(sid) then return sid end
    end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not validish(cls) then return nil end
    local found
    local guard = 0
    while validish(cls) and guard < 24 and not found do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                if found then return end
                pcall(function()
                    local pfull = tostring(prop:GetFullName())
                    local kind = pfull:match("^(%a+)Property")
                    if kind ~= "Str" and kind ~= "Name" then return end
                    local pname = prop:GetFName():ToString()
                    if not is_player_identity_field_name(pname) then return end
                    local sid = read_string_prop(obj, pname)
                    if isSynth(sid) then found = sid end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not validish(sup) then break end
        cls = sup
    end
    if found then return found end
    return nil
end
local function controller_synthetic_id(c)
    local sid = object_synthetic_id(c)
    if sid then return sid end
    local pawn = pawn_of(c)
    sid = object_synthetic_id(pawn)
    if sid then return sid end
    pcall(function()
        local ps = c.PlayerState
        sid = object_synthetic_id(ps)
    end)
    return sid
end
local function trusted_existing_sid(c, k)
    local sid = controller_synthetic_id(c)
    if not isSynth(sid) or sid == HOST_SYNTH_ID then return nil end
    local raw = pname(c)
    if raw ~= "" and is_transient_identity_name(raw) and sid == synthId(raw) then
        return nil
    end
    if sid == loaded_sid[k] then return sid end
    local key = tostring(k) .. ":" .. tostring(sid)
    if not transient_log[key] then
        transient_log[key] = true
        log("save identity using existing synthetic id [" .. tostring(k) .. "] sid=" .. sid ..
            " raw=" .. tostring(raw))
    end
    return sid
end
local function object_key(obj)
    local k
    if pcall(function() k = obj:GetAddress() end) and k then return tostring(k) end
    return tostring(obj)
end
local function add_candidate(out, obj, label)
    if not validish(obj) then return end
    local k = object_key(obj)
    if out.seen[k] then return end
    out.seen[k] = true
    table.insert(out.items, { obj = obj, label = label })
end
local function candidate_prop(owner, pname)
    if not validish(owner) then return nil end
    local v
    if pcall(function() v = owner[pname] end) then return v end
    return nil
end
local function collect_named_props(owner, label, predicate, out)
    if not validish(owner) then return end
    local cls
    if not pcall(function() cls = owner:GetClass() end) or not validish(cls) then return end
    local guard = 0
    while validish(cls) and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pname = prop:GetFName():ToString()
                    if predicate(pname:lower()) then
                        add_candidate(out, candidate_prop(owner, pname), label .. "." .. pname)
                    end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not validish(sup) then break end
        cls = sup
    end
end
local field_stamp_log = {}
local function reflection_prop(obj, field)
    local refl
    if not pcall(function() refl = obj:Reflection() end) or not validish(refl) then return nil end
    local prop
    if not pcall(function() prop = refl:GetProperty(field) end) or not validish(prop) then return nil end
    return prop
end
local function import_text_property(obj, prop, field, value, label, only_blank)
    if not validish(obj) or not validish(prop) then return false end
    local before = read_string_prop(obj, field)
    if only_blank and not is_blank_id(before) then return false end
    if tostring(before or "") == tostring(value) then return false end
    local ok = pcall(function()
        prop:ImportText(tostring(value), prop:ContainerPtrToValuePtr(obj), 0, obj)
    end)
    if not ok then return false end
    local after = read_string_prop(obj, field)
    local key = label .. "." .. field .. "=" .. tostring(value)
    if not field_stamp_log[key] then
        field_stamp_log[key] = true
        log(label .. "." .. field .. "=" .. tostring(after) ..
            " import=" .. tostring(after == tostring(value)))
    end
    return after == tostring(value)
end
local function normalize_hex32(value)
    local s = tostring(value or ""):gsub("[^0-9A-Fa-f]", ""):lower()
    if #s == 32 then return s end
    return nil
end
local function guid_parts(hex)
    hex = normalize_hex32(hex)
    if not hex then return nil end
    return tonumber(hex:sub(1, 8), 16), tonumber(hex:sub(9, 16), 16),
        tonumber(hex:sub(17, 24), 16), tonumber(hex:sub(25, 32), 16)
end
local function uint32_hex(value)
    local n = type(value) == "number" and value or tonumber(tostring(value or ""))
    if not n then return nil end
    return string.format("%08x", n & 0xFFFFFFFF)
end
local function guid_hex(value)
    if value == nil then return nil end
    if type(value) == "string" then return normalize_hex32(value) end
    local out
    if pcall(function() out = value:ToString() end) then
        local h = normalize_hex32(out)
        if h then return h end
    end
    local a, b, c, d
    local ok = pcall(function()
        a, b, c, d = value.A, value.B, value.C, value.D
    end)
    if ok then
        local ha, hb, hc, hd = uint32_hex(a), uint32_hex(b), uint32_hex(c), uint32_hex(d)
        if ha and hb and hc and hd then return ha .. hb .. hc .. hd end
    end
    return nil
end
local function read_guid_prop(obj, field)
    local value
    if not pcall(function() value = obj[field] end) then return nil end
    return guid_hex(value)
end
local function is_blank_guid(value)
    local h = normalize_hex32(value)
    return h == nil or h:match("^0+$") ~= nil
end
local function dashed_guid(hex)
    hex = normalize_hex32(hex)
    if not hex then return nil end
    return hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-" ..
        hex:sub(13, 16) .. "-" .. hex:sub(17, 20) .. "-" .. hex:sub(21, 32)
end
local function guid_struct_text(hex)
    local a, b, c, d = guid_parts(hex)
    if not a then return nil end
    return string.format("(A=%u,B=%u,C=%u,D=%u)", a, b, c, d)
end
local function assign_guid_value(value, hex)
    local a, b, c, d = guid_parts(hex)
    if not a or not validish(value) then return false end
    local ok = pcall(function()
        value.A = a
        value.B = b
        value.C = c
        value.D = d
    end)
    return ok and guid_hex(value) == normalize_hex32(hex)
end
local function import_guid_property(obj, prop, field, hex, label, only_blank)
    if not validish(obj) or not validish(prop) then return false end
    hex = normalize_hex32(hex)
    if not hex then return false end
    local before = read_guid_prop(obj, field) or read_string_prop(obj, field)
    if only_blank and not is_blank_guid(before) and not is_blank_id(before) then return false end
    if normalize_hex32(before) == hex then return false end

    local value
    if pcall(function() value = obj[field] end) and assign_guid_value(value, hex) then
        pcall(function() obj[field] = value end)
        local after = read_guid_prop(obj, field)
        if after == hex then
            local key = label .. "." .. field .. "=" .. hex .. ".guid-field"
            if not field_stamp_log[key] then
                field_stamp_log[key] = true
                log(label .. "." .. field .. "=" .. after .. " guid-field=true")
            end
            return true
        end
    end

    for _, text in ipairs({ hex, hex:upper(), dashed_guid(hex), guid_struct_text(hex) }) do
        if text then
            pcall(function()
                prop:ImportText(text, prop:ContainerPtrToValuePtr(obj), 0, obj)
            end)
            local after = read_guid_prop(obj, field) or read_string_prop(obj, field)
            if normalize_hex32(after) == hex then
                local key = label .. "." .. field .. "=" .. hex .. ".guid-import"
                if not field_stamp_log[key] then
                    field_stamp_log[key] = true
                    log(label .. "." .. field .. "=" .. tostring(after) ..
                        " guid-import=true text=" .. tostring(text))
                end
                return true
            end
        end
    end

    local key = label .. "." .. field .. "=" .. hex .. ".guid-failed"
    if not field_stamp_log[key] then
        field_stamp_log[key] = true
        log(label .. "." .. field .. " guid-write failed before=" .. tostring(before))
    end
    return false
end
local function set_guid_fields(obj, fields, value, label, only_blank)
    if not validish(obj) then return false end
    local did = false
    for _, field in ipairs(fields) do
        local prop = reflection_prop(obj, field)
        if prop then
            did = import_guid_property(obj, prop, field, value, label, only_blank) or did
        end
    end
    return did
end
local function set_string_fields(obj, fields, value, label, only_blank)
    if not validish(obj) then return false end
    local did = false
    for _, field in ipairs(fields) do
        local prop = reflection_prop(obj, field)
        if prop then
            did = import_text_property(obj, prop, field, value, label, only_blank) or did
        end
    end
    return did
end
local prop_kind
local function set_matching_inventory_props(obj, value, label, only_blank)
    if not validish(obj) then return false end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not validish(cls) then return false end
    local did = false
    local guard = 0
    while validish(cls) and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pname = prop:GetFName():ToString()
                    local lower = pname:lower()
                    if lower:find("inventory", 1, true) == nil and
                        lower:find("invenotry", 1, true) == nil then return end
                    if lower:find("id", 1, true) == nil and
                        lower:find("uid", 1, true) == nil then return end
                    local kind = prop_kind(prop)
                    if kind == "Struct" then
                        did = import_guid_property(obj, prop, pname, value, label, only_blank) or did
                    elseif kind == "Str" or kind == "Name" or kind == "Text" then
                        did = import_text_property(obj, prop, pname, value, label, only_blank) or did
                    end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not validish(sup) then break end
        cls = sup
    end
    return did
end
local function set_matching_string_props(obj, predicate, value, label, only_blank)
    if not validish(obj) then return false end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not validish(cls) then return false end
    local did = false
    local guard = 0
    while validish(cls) and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pfull = tostring(prop:GetFullName())
                    local kind = pfull:match("^(%a+)Property")
                    if kind ~= "Str" and kind ~= "Name" then return end
                    local pname = prop:GetFName():ToString()
                    if not predicate(pname:lower()) then return end
                    local before = read_string_prop(obj, pname)
                    if only_blank and not is_blank_id(before) then return end
                    did = import_text_property(obj, prop, pname, value, label, only_blank) or did
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not validish(sup) then break end
        cls = sup
    end
    return did
end
local function struct_field_string(s, field)
    if not validish(s) then return nil end
    local v
    if not pcall(function() v = s[field] end) then return nil end
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local out
    if pcall(function() out = v:ToString() end) and type(out) == "string" then return out end
    return tostring(v)
end
local function set_struct_string_fields(s, fields, value, label, only_blank)
    if not validish(s) then return false end
    local did = false
    for _, field in ipairs(fields) do
        local before = struct_field_string(s, field)
        if (not only_blank or is_blank_id(before)) and tostring(before or "") ~= tostring(value) then
            local ok = pcall(function() s[field] = value end)
            local after = struct_field_string(s, field)
            if ok and after == tostring(value) then
                local key = label .. "." .. field .. "=" .. tostring(value)
                if not field_stamp_log[key] then
                    field_stamp_log[key] = true
                    log(label .. "." .. field .. "=" .. tostring(after) .. " struct=true")
                end
                did = true
            end
        end
    end
    return did
end
local function prop_name(prop)
    local name
    if pcall(function() name = prop:GetFName():ToString() end) and name and name ~= "" then return name end
    if pcall(function() name = prop:GetName() end) and name and name ~= "" then return name end
    return nil
end
prop_kind = function(prop)
    local full = tostring(prop)
    pcall(function() full = tostring(prop:GetFullName()) end)
    return full:match("^(%a+)Property") or full
end
local function struct_field_guid(s, field)
    if not validish(s) then return nil end
    local value
    if not pcall(function() value = s[field] end) then return nil end
    return guid_hex(value)
end
local function set_struct_guid_fields(s, fields, value, label, only_blank)
    if not validish(s) then return false end
    local did = false
    for _, field in ipairs(fields) do
        local before = struct_field_guid(s, field) or struct_field_string(s, field)
        if (not only_blank or is_blank_guid(before) or is_blank_id(before)) and
            normalize_hex32(before) ~= normalize_hex32(value) then
            local current
            local ok_get = pcall(function() current = s[field] end)
            local ok = false
            if ok_get and assign_guid_value(current, value) then
                ok = pcall(function() s[field] = current end)
            end
            if not ok then
                ok = pcall(function() s[field] = value end)
            end
            local after = struct_field_guid(s, field) or struct_field_string(s, field)
            if ok and normalize_hex32(after) == normalize_hex32(value) then
                local key = label .. "." .. field .. "=" .. tostring(value) .. ".struct-guid"
                if not field_stamp_log[key] then
                    field_stamp_log[key] = true
                    log(label .. "." .. field .. "=" .. tostring(after) .. " struct-guid=true")
                end
                did = true
            end
        end
    end
    return did
end
local function set_struct_matching_inventory_props(s, value, label, only_blank)
    if not validish(s) then return false end
    local did = false
    local logged_any = false
    local ok_iter = pcall(function()
        s:ForEachProperty(function(prop)
            local pname = prop_name(prop)
            local kind = prop_kind(prop)
            if pname and not logged_any then
                logged_any = true
                log(label .. ".inventory-field-scan first=" .. pname .. " kind=" .. kind)
            end
            if not pname then return end
            local lower = pname:lower()
            if lower:find("inventory", 1, true) == nil and
                lower:find("invenotry", 1, true) == nil then return end
            if lower:find("id", 1, true) == nil and lower:find("uid", 1, true) == nil then return end
            if kind == "Struct" then
                did = set_struct_guid_fields(s, { pname }, value, label, only_blank) or did
            elseif kind == "Str" or kind == "Name" or kind == "Text" then
                did = set_struct_string_fields(s, { pname }, value, label, only_blank) or did
            end
        end)
    end)
    if not ok_iter then
        local key = label .. ".inventory-field-scan-unavailable"
        if not field_stamp_log[key] then
            field_stamp_log[key] = true
            log(label .. ".inventory-field-scan unavailable")
        end
    end
    return did
end
local function is_player_id_field(name)
    return is_player_identity_field_name(name)
end
local function set_struct_matching_string_props(s, predicate, value, label, only_blank)
    if not validish(s) then return false end
    local did = false
    local logged_any = false
    local ok_iter = pcall(function()
        s:ForEachProperty(function(prop)
            local pname = prop_name(prop)
            local kind = prop_kind(prop)
            if pname and not logged_any then
                logged_any = true
                log(label .. ".field-scan first=" .. pname .. " kind=" .. kind)
            end
            if pname and (kind == "Str" or kind == "Name" or kind == "Text") and predicate(pname, kind) then
                local before = struct_field_string(s, pname)
                if (not only_blank or is_blank_id(before)) and tostring(before or "") ~= tostring(value) then
                    local ok = pcall(function() s[pname] = value end)
                    local after = struct_field_string(s, pname)
                    if ok and after == tostring(value) then
                        local key = label .. "." .. pname .. "=" .. tostring(value)
                        if not field_stamp_log[key] then
                            field_stamp_log[key] = true
                            log(label .. "." .. pname .. "=" .. tostring(after) .. " struct-scan=true kind=" .. kind)
                        end
                        did = true
                    else
                        log(label .. "." .. pname .. " struct-scan failed ok=" .. tostring(ok) ..
                            " before=" .. tostring(before) .. " after=" .. tostring(after) .. " kind=" .. kind)
                    end
                end
            end
        end)
    end)
    if not ok_iter then
        local key = label .. ".field-scan-unavailable"
        if not field_stamp_log[key] then
            field_stamp_log[key] = true
            log(label .. ".field-scan unavailable")
        end
    end
    return did
end
local function stable_inventory_id(sid)
    return string.format("%08x%08x%08x%08x",
        crc32("inv-a:" .. sid), crc32("inv-b:" .. sid),
        crc32("inv-c:" .. sid), crc32("inv-d:" .. sid))
end
local strict_inventory_id_fields = {
    "InventoryID", "InventoryId", "InventoryUID", "InventoryUid",
    "UniqueInventoryID", "UniqueInventoryId", "InventoryIDString",
    "InventoryIdString", "InventoryUniqueID", "InventoryUniqueId",
    "InvenotryID", "InvenotryId", "InvenotryUID", "InvenotryUid",
    "UniqueInvenotryID", "UniqueInvenotryId", "InvenotryIDString",
    "InvenotryIdString", "InvenotryUniqueID", "InvenotryUniqueId",
}
local playerdata_fields = {
    "UniquePlayerID", "UniquePlayerId", "PlayerID", "PlayerId",
    "PlayerIDString", "PlayerIdString", "PlayerdataID", "PlayerDataID",
    "PlayerdataId", "PlayerDataId", "UniqueID", "UniqueId",
    "SteamID", "SteamId", "UserID", "UserId", "OwnerID", "OwnerId",
    "ID", "Id",
}
local controller_id_fields = {
    "UniquePlayerID", "UniquePlayerId", "UniquePlayerID_9_EE47D6D847B2CFF0719CA4A8EB2B5363",
    "PlayerID", "PlayerId", "PlayerIDString", "PlayerIdString",
    "PlayerdataID", "PlayerDataID", "PlayerdataId", "PlayerDataId",
    "UniqueID", "UniqueId", "SteamID", "SteamId", "UserID", "UserId",
    "OwnerID", "OwnerId", "ID", "Id",
}
local inventory_id_fields = {
    "InventoryID", "InventoryId", "InventoryUID", "InventoryUid",
    "UniqueInventoryID", "UniqueInventoryId", "InventoryIDString",
    "InventoryIdString", "InventoryUniqueID", "InventoryUniqueId",
    -- The game typo is real: logs report "RepNotify InvenotryID".
    "InvenotryID", "InvenotryId", "InvenotryUID", "InvenotryUid",
    "UniqueInvenotryID", "UniqueInvenotryId", "InvenotryIDString",
    "InvenotryIdString", "InvenotryUniqueID", "InvenotryUniqueId",
    "OwnerID", "OwnerId", "ID", "Id",
}
local playerdata_prop_names = {
    "Playerdata", "PlayerData", "PlayerDataStruct", "PlayerdataStruct",
    "CurrentPlayerdata", "CurrentPlayerData", "LoadedPlayerdata", "LoadedPlayerData",
    "SavedPlayerdata", "SavedPlayerData", "PlayerSaveData", "SavePlayerData",
}
local inventory_prop_names = {
    "InventorySystem", "Inventory", "InventoryComponent", "PlayerInventory",
    "MainInventory", "BackpackInventory", "HotbarInventory",
}
local function playerdata_param_id(s)
    if not validish(s) then return nil end
    local found
    for _, field in ipairs(playerdata_fields) do
        local v = struct_field_string(s, field)
        if v and v ~= "" then found = v; break end
    end
    if found then return found end
    pcall(function()
        s:ForEachProperty(function(prop)
            if found then return end
            local pname = prop_name(prop)
            local kind = prop_kind(prop)
            if pname and (kind == "Str" or kind == "Name" or kind == "Text") and is_player_id_field(pname) then
                local v = struct_field_string(s, pname)
                if v and v ~= "" then found = v end
            end
        end)
    end)
    return found
end
local function stamp_playerdata_param(param, sid, why)
    if not isSynth(sid) or param == nil then return false end
    local patch = {}
    for _, field in ipairs(playerdata_fields) do patch[field] = sid end
    local s
    local ok_get = pcall(function() s = param:get() end)
    if not ok_get or not validish(s) then
        local ok_table = pcall(function() param:set(patch) end)
        local key = "Playerdata param set why=" .. tostring(why or "") .. " sid=" .. sid
        if not field_stamp_log[key] then
            field_stamp_log[key] = true
            log(key .. " get_ok=" .. tostring(ok_get) ..
                " valid=false table_ok=" .. tostring(ok_table))
        end
        return ok_table, patch, nil, ok_table and "table" or "none"
    end
    local before = playerdata_param_id(s)
    local label = "Playerdata param stamped why=" .. tostring(why or "")
    local did = set_struct_string_fields(s, playerdata_fields, sid, label, false)
    did = set_struct_matching_string_props(s, is_player_id_field, sid, label, false) or did
    pcall(function()
        s:ForEachProperty(function(prop)
            local pname = prop_name(prop)
            local kind = prop_kind(prop)
            if pname and (kind == "Str" or kind == "Name" or kind == "Text") and is_player_id_field(pname) then
                patch[pname] = sid
            end
        end)
    end)
    local ok_struct = false
    if did then ok_struct = pcall(function() param:set(s) end) end
    local after = playerdata_param_id(s)
    local ok_table = false
    if after ~= sid then ok_table = pcall(function() param:set(patch) end) end
    local key = "Playerdata param set why=" .. tostring(why or "") .. " sid=" .. sid
    if not field_stamp_log[key] then
        field_stamp_log[key] = true
        log(key .. " before=" .. tostring(before or "") .. " after=" .. tostring(after or "") ..
            " struct_changed=" .. tostring(did) .. " struct_ok=" .. tostring(ok_struct) ..
            " table_ok=" .. tostring(ok_table))
    end
    local kind = ok_table and "table" or "struct"
    local full_struct = (after == sid or did or ok_struct) and s or nil
    return after == sid or did or ok_struct or ok_table, patch, full_struct, kind
end
local function inventory_param_id(s)
    if not validish(s) then return nil end
    local found
    for _, field in ipairs(strict_inventory_id_fields) do
        local v = struct_field_guid(s, field) or struct_field_string(s, field)
        if v and not is_blank_guid(v) and not is_blank_id(v) then found = v; break end
    end
    if found then return found end
    pcall(function()
        s:ForEachProperty(function(prop)
            if found then return end
            local pname = prop_name(prop)
            local kind = prop_kind(prop)
            if not pname then return end
            local lower = pname:lower()
            if lower:find("inventory", 1, true) == nil and
                lower:find("invenotry", 1, true) == nil then return end
            if lower:find("id", 1, true) == nil and lower:find("uid", 1, true) == nil then return end
            local v
            if kind == "Struct" then
                v = struct_field_guid(s, pname)
            elseif kind == "Str" or kind == "Name" or kind == "Text" then
                v = struct_field_string(s, pname)
            end
            if v and not is_blank_guid(v) and not is_blank_id(v) then found = v end
        end)
    end)
    return found
end
local function stamp_inventory_param(param, sid, why)
    if not isSynth(sid) or param == nil then return false end
    local inv_id = stable_inventory_id(sid)
    local s
    local ok_get = pcall(function() s = param:get() end)
    if not ok_get or not validish(s) then
        local key = "Inventory param set why=" .. tostring(why or "") .. " sid=" .. sid
        if not field_stamp_log[key] then
            field_stamp_log[key] = true
            log(key .. " get_ok=" .. tostring(ok_get) .. " valid=false")
        end
        return false
    end
    local before = inventory_param_id(s)
    local label = "Inventory param stamped why=" .. tostring(why or "")
    local did = set_struct_guid_fields(s, strict_inventory_id_fields, inv_id, label, false)
    did = set_struct_string_fields(s, strict_inventory_id_fields, inv_id, label, false) or did
    did = set_struct_matching_inventory_props(s, inv_id, label, true) or did
    local ok_struct = false
    if did then ok_struct = pcall(function() param:set(s) end) end
    local after = inventory_param_id(s)
    local key = "Inventory param set why=" .. tostring(why or "") .. " sid=" .. sid
    if not field_stamp_log[key] then
        field_stamp_log[key] = true
        log(key .. " inv=" .. inv_id .. " before=" .. tostring(before or "") ..
            " after=" .. tostring(after or "") .. " changed=" .. tostring(did) ..
            " struct_ok=" .. tostring(ok_struct))
    end
    return normalize_hex32(after) == inv_id or did or ok_struct
end
local function stamp_playerdata_record(c, sid, why)
    local out = { seen = {}, items = {} }
    local owners = {
        { obj = c, label = "pc" },
        { obj = pawn_of(c), label = "pawn" },
    }
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then table.insert(owners, { obj = ps, label = "ps" }) end
    end)
    for _, owner in ipairs(owners) do
        for _, pname in ipairs(playerdata_prop_names) do
            add_candidate(out, candidate_prop(owner.obj, pname), owner.label .. "." .. pname)
        end
        collect_named_props(owner.obj, owner.label, function(lower)
            return lower:find("playerdata", 1, true) ~= nil or
                lower:find("player_data", 1, true) ~= nil or
                (lower:find("player", 1, true) ~= nil and lower:find("data", 1, true) ~= nil)
        end, out)
    end
    local did = false
    for _, item in ipairs(out.items) do
        local label = "Playerdata ID stamped [" .. tostring(akey(c)) .. "] " ..
            item.label .. " why=" .. tostring(why or "")
        did = set_string_fields(item.obj, playerdata_fields, sid, label, false) or did
        did = set_matching_string_props(item.obj, function(lower)
            return lower:find("id", 1, true) ~= nil or
                lower:find("uid", 1, true) ~= nil or
                lower:find("steam", 1, true) ~= nil
        end, sid, label, false) or did
    end
    return did
end
local function stamp_inventory_ids(c, sid, why)
    local inv_id = stable_inventory_id(sid)
    local out = { seen = {}, items = {} }
    local owners = {
        { obj = c, label = "pc" },
        { obj = pawn_of(c), label = "pawn" },
    }
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then table.insert(owners, { obj = ps, label = "ps" }) end
    end)
    for _, owner in ipairs(owners) do
        for _, pname in ipairs(inventory_prop_names) do
            add_candidate(out, candidate_prop(owner.obj, pname), owner.label .. "." .. pname)
        end
        collect_named_props(owner.obj, owner.label, function(lower)
            return lower:find("inventory", 1, true) ~= nil
        end, out)
    end
    local did = false
    for _, item in ipairs(out.items) do
        local label = "Inventory ID stamped [" .. tostring(akey(c)) .. "] " ..
            item.label .. " why=" .. tostring(why or "")
        did = set_guid_fields(item.obj, strict_inventory_id_fields, inv_id, label, false) or did
        did = set_string_fields(item.obj, strict_inventory_id_fields, inv_id, label, false) or did
        did = set_guid_fields(item.obj, inventory_id_fields, inv_id, label, true) or did
        did = set_string_fields(item.obj, inventory_id_fields, inv_id, label, true) or did
        did = set_matching_inventory_props(item.obj, inv_id, label, true) or did
        did = set_matching_string_props(item.obj, function(lower)
            return lower:find("id", 1, true) ~= nil or lower:find("uid", 1, true) ~= nil
        end, inv_id, label, true) or did
    end
    return did
end
local function stamp_persistence_ids(c, sid, why)
    local a = stamp_unique_player_id(c, sid, why)
    local b = stamp_playerdata_record(c, sid, why)
    local d = stamp_inventory_ids(c, sid, why)
    return a or b or d
end
local invalid_clear_log = {}
local function clear_invalid_identity_stamp(c, k, key)
    if not (c and c:IsValid()) then return end
    local value = tostring(key or "")
    local label = "Invalid identity cleared [" .. tostring(k) .. "]"
    local function clear_owner(owner, owner_label)
        if not validish(owner) then return false end
        local did = false
        did = pcall(function() owner.UniquePlayerID = value end) or did
        did = set_string_fields(owner, controller_id_fields, value,
            label .. " " .. owner_label .. ".known", false) or did
        did = set_matching_string_props(owner, is_player_identity_field_name, value,
            label .. " " .. owner_label .. ".scan", false) or did
        return did
    end
    local did = clear_owner(c, "pc")
    did = clear_owner(pawn_of(c), "pawn") or did
    pcall(function()
        local ps = c.PlayerState
        did = clear_owner(ps, "ps") or did
    end)
    local log_key = tostring(k) .. ":" .. value
    if not invalid_clear_log[log_key] then
        invalid_clear_log[log_key] = true
        log(label .. " key=" .. value .. " changed=" .. tostring(did))
    end
end
local stamped_log = {}
stamp_unique_player_id = function(c, sid, why)
    if not (c and c:IsValid()) or not isSynth(sid) then return false end
    local did = false
    local ok_pc = pcall(function() c.UniquePlayerID = sid end)
    did = did or ok_pc
    local scan_pc = set_string_fields(c, controller_id_fields, sid,
        "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] pc.generated why=" .. tostring(why or ""), false)
    scan_pc = set_matching_string_props(c, is_player_identity_field_name, sid,
        "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] pc.scan why=" .. tostring(why or ""), false) or scan_pc
    did = did or scan_pc
    local pawn = pawn_of(c)
    local ok_pawn = false
    local scan_pawn = false
    if pawn then
        ok_pawn = pcall(function() pawn.UniquePlayerID = sid end)
        did = did or ok_pawn
        scan_pawn = set_string_fields(pawn, controller_id_fields, sid,
            "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] pawn.generated why=" .. tostring(why or ""), false)
        scan_pawn = set_matching_string_props(pawn, is_player_identity_field_name, sid,
            "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] pawn.scan why=" .. tostring(why or ""), false) or scan_pawn
        did = did or scan_pawn
    end
    local ok_ps = false
    local scan_ps = false
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then
            ok_ps = pcall(function() ps.UniquePlayerID = sid end)
            did = did or ok_ps
            scan_ps = set_string_fields(ps, controller_id_fields, sid,
                "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] ps.generated why=" .. tostring(why or ""), false)
            scan_ps = set_matching_string_props(ps, is_player_identity_field_name, sid,
                "UniquePlayerID stamped [" .. tostring(akey(c)) .. "] ps.scan why=" .. tostring(why or ""), false) or scan_ps
            did = did or scan_ps
        end
    end)
    local key = tostring(akey(c)) .. ":" .. sid .. ":" .. tostring(why or "")
    if did and not stamped_log[key] then
        stamped_log[key] = true
        log("UniquePlayerID stamped [" .. tostring(akey(c)) .. "] sid=" .. sid ..
            " why=" .. tostring(why or "") ..
            " pc=" .. tostring(ok_pc) ..
            " pawn=" .. tostring(ok_pawn) ..
            " ps=" .. tostring(ok_ps) ..
            " pc_scan=" .. tostring(scan_pc) ..
            " pawn_scan=" .. tostring(scan_pawn) ..
            " ps_scan=" .. tostring(scan_ps) ..
            " pc_read=" .. tostring(controller_synthetic_id(c)))
    end
    return did
end

local function load_sid_for_controller(c, k)
    if c:IsLocalPlayerController() then return nil, nil end
    local nm = stable_pname(c, k)
    if not nm then
        local sid = trusted_existing_sid(c, k)
        if sid then return sid, "existing-synthetic" end
        return nil, nil
    end
    return synthId(nm), nm
end

local function begin_load_delay(c)
    return 6
end

local function mark_controller_seen(k)
    if not first_seen_at[k] then first_seen_at[k] = os.time() end
    return first_seen_at[k]
end

local function begin_load_age(k)
    return os.time() - (first_seen_at[k] or os.time())
end

local function allow_begin_load_reissue(k, sid, name_label, reason)
    local age = begin_load_age(k)
    if age <= MAX_BEGIN_LOAD_REISSUE_AGE then return true end
    blocked_reissue_sid[k] = sid
    pending[k] = nil
    local key = tostring(k) .. ":" .. tostring(sid)
    if not blocked_reissue_log[key] then
        blocked_reissue_log[key] = true
        log("BeginLoadData reissue skipped late [" .. tostring(k) .. "] sid=" ..
            tostring(sid) .. " name=" .. tostring(name_label or "") ..
            " age=" .. tostring(age) .. " reason=" .. tostring(reason or ""))
    end
    return false
end

local function drive_pending_begin_load(c, k, sid, name_label)
    if loaded_sid[k] == sid then return end
    local prior = loaded_sid[k]
    loaded_sid[k] = sid
    blocked_reissue_sid[k] = sid
    pending[k] = nil
    log("BeginLoadData reissue suppressed [" .. tostring(k) .. "] sid=" .. sid ..
        " name=" .. tostring(name_label or "") ..
        " prior=" .. tostring(prior or ""))
end

local function controller_blocked(k)
    return SP.kicked[k] or (SP.invalid_identity and SP.invalid_identity[k])
end

local function tick()
    local cs = SP.controllers()
    if not cs then return end
    local live = {}
    for _, c in ipairs(cs) do
        if c and c:IsValid() then
            local k = akey(c)
            live[k] = true
            mark_controller_seen(k)
            -- never touch a controller auth already kicked (dying object) or
            -- quarantined for a bad client identity.
            if not c:IsLocalPlayerController() and not controller_blocked(k) then
                local sid, name_label = load_sid_for_controller(c, k)
                if sid then
                    stamp_persistence_ids(c, sid, "tick")
                    -- Keep stamping the corrected id, but do not re-enter
                    -- BeginLoadData from Lua. UE4SS-on-5.7 can crash the host
                    -- when this happens during the join transition.
                    drive_pending_begin_load(c, k, sid, name_label)
                end
            end
        end
    end
    for k in pairs(loaded_sid) do
        if not live[k] then
            loaded_sid[k] = nil
            if SP.canonical_name then SP.canonical_name[k] = nil end
        end
    end
    for k in pairs(first_seen_at) do
        if not live[k] then
            first_seen_at[k] = nil
            blocked_reissue_sid[k] = nil
            if SP.invalid_identity then SP.invalid_identity[k] = nil end
        end
    end
    for k in pairs(pending) do
        if not live[k] then pending[k] = nil end
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
                mark_controller_seen(k)
                SP.transition[k] = os.time()       -- join/load transition in flight
                local key = ""
                pcall(function() key = p1:get():ToString() end)
                local sid = select(1, load_sid_for_controller(c, k))
                if is_blank_id(key) then
                    pending[k] = nil
                    loaded_sid[k] = nil
                    clear_invalid_identity_stamp(c, k, key)
                    if SP.invalid_identity then
                        SP.invalid_identity[k] = {
                            key = key,
                            sid = sid,
                            name = pname(c),
                            at = os.time(),
                        }
                    end
                    log("BeginLoadData invalid remote identity [" .. tostring(k) ..
                        "] key=" .. tostring(key or "") ..
                        " name=" .. tostring(pname(c)) ..
                        " sid=" .. tostring(sid or "") ..
                        " -- quarantined pending auth kick")
                    return
                end
                if sid and key ~= sid and blocked_reissue_sid[k] ~= sid then
                    stamp_persistence_ids(c, sid, "begin-load-hook")
                    drive_pending_begin_load(c, k, sid, sid)
                end
            end)
        end, function(self)
            pcall(function()
                local c = self:get()
                if not c or not c:IsValid() then return end
                if c:IsLocalPlayerController() then return end
                local k = akey(c)
                mark_controller_seen(k)
                SP.transition[k] = os.time()
            end)
        end)
    end)
    if ok then
        ld_hooked = true
        log("BeginLoadData hook installed (attempt " .. ld_tries .. ")")
    elseif ld_tries >= 60 then
        ld_hooked = true -- stop retrying
        log("BeginLoadData hook FAILED after " .. ld_tries .. " tries")
    end
end

local save_player_hooked, save_player_tries = false, 0
local save_flush_guard = false
local function force_save_to_disk(reason)
    if save_flush_guard then return end
    save_flush_guard = true
    enforce_world_slot_runtime("pre-force-save-" .. tostring(reason or ""))
    local sm = FindFirstOf("BPC_SaveManager_C")
    if sm and sm:IsValid() then
        local ok = pcall(function() sm:SaveToDisk() end)
        log("forced SaveToDisk reason=" .. tostring(reason or "") .. " ok=" .. tostring(ok))
        if ok then normalize_save_games_dir(reason) end
    end
    save_flush_guard = false
end
local function save_sid_for_controller(c)
    if not (c and c:IsValid()) then return nil end
    -- The listen-server's local controller is not a real customer player. If we
    -- stamp or re-save it, the game can persist customer state under host-local.
    if c:IsLocalPlayerController() then return nil end
    local nm = stable_pname(c, akey(c))
    if not nm then return trusted_existing_sid(c, akey(c)) end
    return synthId(nm)
end
local function try_install_save_player_hook()
    if save_player_hooked then return end
    save_player_tries = save_player_tries + 1
    local ok = pcall(function()
        RegisterHook(BLD_CLASS .. ":SERVER_SavePlayerdata", function(self, playerdata)
            pcall(function()
                local c = self:get()
                if not c or not c:IsValid() then return end
                if c:IsLocalPlayerController() then return end
                local k = akey(c)
                if controller_blocked(k) then return end
                local sid = save_sid_for_controller(c)
                if not sid then return end
                stamp_persistence_ids(c, sid, "pre-save")
                stamp_playerdata_param(playerdata, sid, "pre-save")
            end)
        end, function(self)
            pcall(function()
                local c = self and self:get()
                if not (c and c:IsValid()) then return end
                if c:IsLocalPlayerController() then return end
                if controller_blocked(akey(c)) then return end
                local sid = save_sid_for_controller(c)
                if sid then stamp_persistence_ids(c, sid, "post-save") end
            end)
        end)
    end)
    if ok then
        save_player_hooked = true
        log("SERVER_SavePlayerdata hook installed (attempt " .. save_player_tries .. ")")
    elseif save_player_tries >= 60 then
        save_player_hooked = true
        log("SERVER_SavePlayerdata hook FAILED after " .. save_player_tries .. " tries")
    end
end

local inventory_apply_hooked, inventory_apply_tries = false, 0
local function try_install_apply_inventory_hook()
    if inventory_apply_hooked then return end
    inventory_apply_tries = inventory_apply_tries + 1
    local ok = pcall(function()
        RegisterHook(BLD_CLASS .. ":SERVER_Net_ApplyAndSaveInventory", function(self, inventory)
            pcall(function()
                local c = self:get()
                if not c or not c:IsValid() then return end
                if c:IsLocalPlayerController() then return end
                local k = akey(c)
                if controller_blocked(k) then return end
                local sid = save_sid_for_controller(c)
                if not sid then return end
                stamp_persistence_ids(c, sid, "pre-inventory-apply")
                stamp_inventory_param(inventory, sid, "pre-inventory-apply")
            end)
        end, function(self)
            pcall(function()
                local c = self and self:get()
                if not (c and c:IsValid()) then return end
                if c:IsLocalPlayerController() then return end
                if controller_blocked(akey(c)) then return end
                local sid = save_sid_for_controller(c)
                if sid then stamp_persistence_ids(c, sid, "post-inventory-apply") end
            end)
        end)
    end)
    if ok then
        inventory_apply_hooked = true
        log("SERVER_Net_ApplyAndSaveInventory hook installed (attempt " ..
            inventory_apply_tries .. ")")
    elseif inventory_apply_tries >= 60 then
        inventory_apply_hooked = true
        log("SERVER_Net_ApplyAndSaveInventory hook FAILED after " ..
            inventory_apply_tries .. " tries")
    end
end

local save_hooked, save_hook_tries = false, 0
local function try_install_save_slot_hooks()
    if save_hooked then return end
    save_hook_tries = save_hook_tries + 1
    local any = false
    local function hook(path, pre)
        local ok = pcall(function() RegisterHook(path, pre, function() end) end)
        log("save-slot hook " .. path .. " ok=" .. tostring(ok))
        if ok then any = true end
    end
    hook("/Script/Engine.GameplayStatics:DoesSaveGameExist", function(_, slot_name)
        rewrite_world_slot_param(slot_name, "DoesSaveGameExist")
    end)
    hook("/Script/Engine.GameplayStatics:LoadGameFromSlot", function(_, slot_name)
        rewrite_world_slot_param(slot_name, "LoadGameFromSlot")
    end)
    hook("/Script/Engine.GameplayStatics:SaveGameToSlot", function(_, save_obj, slot_name)
        rewrite_world_slot_param(slot_name, "SaveGameToSlot")
    end)
    if any then
        save_hooked = true
        log("save-slot hooks installed (attempt " .. save_hook_tries .. ")")
    elseif save_hook_tries >= 60 then
        save_hooked = true
        log("save-slot hooks FAILED after " .. save_hook_tries .. " tries")
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
    log_saveish_string_props(gi, "GameInstance.before")
    set_world_slot_fields(gi, "GameInstance")
    log_saveish_string_props(gi, "GameInstance.after")
    enforce_world_slot_runtime("pre-host")
    try_install_save_slot_hooks()
    try_install_bld_hook()
    try_install_save_player_hook()
    try_install_apply_inventory_hook()
    normalize_save_games_dir("pre-host")

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
    try_install_save_player_hook()
    try_install_apply_inventory_hook()
end)

SP.every("host-save-slot-hooks", 1000, 250, function()
    if not hosted then return end
    try_install_save_slot_hooks()
end)

-- net-id enforcement tick (every scheduler tick = 250ms, unchanged cadence)
SP.every("host-netid", 250, 0, function()
    if not hosted then return end
    tick()
end)

-- forced world save cadence (the game autosaves too; this is the floor)
SP.every("host-save", SAVE_INTERVAL_S * 1000, 2000, function()
    if not hosted then return end
    enforce_world_slot_runtime("periodic")
    local sm = FindFirstOf("BPC_SaveManager_C")
    if sm and sm:IsValid() then
        local ok = pcall(function() sm:SaveToDisk() end)
        log("periodic SaveToDisk ok=" .. tostring(ok))
        if ok then normalize_save_games_dir("periodic") end
    end
end)

-- Keep the active save slot pinned between the game's own autosaves. This
-- clears random post-host slot aliases quickly without forcing extra saves.
SP.every("host-save-normalize", 15000, 7000, function()
    if not hosted then return end
    enforce_world_slot_runtime("sweep")
    normalize_save_games_dir("sweep")
end)

-- heartbeat into the host status file so the supervisor sees liveness
SP.every("host-heartbeat", 30000, 4000, function()
    if not hosted then return end
    write_host_status(true, "alive")
end)
