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

local function read_string_prop(obj, pname)
    local v
    if not pcall(function() v = obj[pname] end) then return nil end
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

local function set_world_slot_fields(obj, label)
    if not (obj and obj:IsValid()) then return end
    for _, pname in ipairs(WORLD_SLOT_FIELDS) do
        local ok = pcall(function() obj[pname] = WORLD_NAME end)
        if ok then
            log(label .. "." .. pname .. "=" .. tostring(read_string_prop(obj, pname)))
        end
    end
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
    local ok = pcall(function() p:set(WORLD_NAME) end)
    log("slot rewrite " .. label .. ": " .. tostring(before) .. " -> " .. WORLD_NAME ..
        " ok=" .. tostring(ok) .. " after=" .. tostring(param_string(p)))
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
local pending = {}     -- [controller addr] = countdown until BeginLoadData re-issue
local loaded_sid = {}  -- [controller addr] = last synthetic id we re-loaded under

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
local function is_blank_id(s)
    s = tostring(s or "")
    return s == "" or s == "TESTING UID" or s == "ERROR, BAD UNIQUE NET ID" or
        s:match("^0+$") ~= nil
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
    local ok = pcall(function()
        prop:ImportText(tostring(value), prop:ContainerPtrToValuePtr(obj), 0, obj)
    end)
    if not ok then return false end
    local after = read_string_prop(obj, field)
    local key = label .. "." .. field .. "=" .. tostring(value)
    if not field_stamp_log[key] then
        field_stamp_log[key] = true
        log(label .. "." .. field .. "=" .. tostring(after) .. " import=true")
    end
    return true
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
        if not only_blank or is_blank_id(before) then
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
local function prop_kind(prop)
    local full = tostring(prop)
    pcall(function() full = tostring(prop:GetFullName()) end)
    return full:match("^(%a+)Property") or full
end
local function is_player_id_field(name)
    local lower = tostring(name or ""):lower()
    return lower == "id" or lower:match("^id_") or lower:find("uniqueplayerid", 1, true) or
        lower:find("playerid", 1, true) or lower:find("player_id", 1, true)
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
                if not only_blank or is_blank_id(before) then
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
local playerdata_fields = {
    "UniquePlayerID", "UniquePlayerId", "PlayerID", "PlayerId",
    "PlayerIDString", "PlayerIdString", "PlayerdataID", "PlayerDataID",
    "PlayerdataId", "PlayerDataId", "UniqueID", "UniqueId",
    "SteamID", "SteamId", "UserID", "UserId", "OwnerID", "OwnerId",
    "ID", "Id",
}
local inventory_id_fields = {
    "InventoryID", "InventoryId", "InventoryUID", "InventoryUid",
    "UniqueInventoryID", "UniqueInventoryId", "InventoryIDString",
    "InventoryIdString", "InventoryUniqueID", "InventoryUniqueId",
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
local function stamp_playerdata_param(param, sid, why)
    if not isSynth(sid) or param == nil then return false end
    local s
    if not pcall(function() s = param:get() end) or not validish(s) then return false end
    local did = set_struct_string_fields(s, playerdata_fields, sid,
        "Playerdata param stamped why=" .. tostring(why or ""), false)
    did = set_struct_matching_string_props(s, is_player_id_field, sid,
        "Playerdata param stamped why=" .. tostring(why or ""), false) or did
    if did then pcall(function() param:set(s) end) end
    return did
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
        did = set_string_fields(item.obj, inventory_id_fields, inv_id, label, true) or did
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
local stamped_log = {}
stamp_unique_player_id = function(c, sid, why)
    if not (c and c:IsValid()) or not isSynth(sid) then return false end
    local did = false
    local ok_pc = pcall(function() c.UniquePlayerID = sid end)
    did = did or ok_pc
    local pawn = pawn_of(c)
    local ok_pawn = false
    if pawn then
        ok_pawn = pcall(function() pawn.UniquePlayerID = sid end)
        did = did or ok_pawn
    end
    local ok_ps = false
    pcall(function()
        local ps = c.PlayerState
        if ps and ps:IsValid() then
            ok_ps = pcall(function() ps.UniquePlayerID = sid end)
            did = did or ok_ps
        end
    end)
    local key = tostring(akey(c)) .. ":" .. sid .. ":" .. tostring(why or "")
    if did and not stamped_log[key] then
        stamped_log[key] = true
        log("UniquePlayerID stamped [" .. tostring(akey(c)) .. "] sid=" .. sid ..
            " why=" .. tostring(why or "") ..
            " pc=" .. tostring(ok_pc) ..
            " pawn=" .. tostring(ok_pawn) ..
            " ps=" .. tostring(ok_ps))
    end
    return did
end

local function tick()
    local cs = SP.controllers()
    if not cs then return end
    local live = {}
    for _, c in ipairs(cs) do
        if c and c:IsValid() and not c:IsLocalPlayerController() then
            local k = akey(c)
            live[k] = true
            -- never touch a controller auth already kicked (dying object)
            if not SP.kicked[k] then
                local nm = pname(c)
                if nm ~= "" then
                    local sid = synthId(nm)
                    stamp_persistence_ids(c, sid, "tick") -- save key (per-player)
                    -- The launcher/client name keeper can correct the PlayerState name
                    -- after the game's first BeginLoadData call. When that happens,
                    -- re-load under the corrected character id so the load key and
                    -- save key do not split for the session.
                    if loaded_sid[k] ~= sid and pending[k] == nil then
                        pending[k] = 6
                        if loaded_sid[k] then
                            log("save identity changed [" .. tostring(k) .. "]: " ..
                                tostring(loaded_sid[k]) .. " -> " .. sid ..
                                " (name=" .. nm .. "); re-arming BeginLoadData")
                        end
                    end
                    if pending[k] then
                        pending[k] = pending[k] - 1
                        if pending[k] <= 0 then
                            pending[k] = nil
                            local ok = pcall(function() c:BeginLoadData(sid) end) -- load key, lands last
                            if ok then
                                loaded_sid[k] = sid
                                log("BeginLoadData re-issued [" .. tostring(k) .. "] sid=" .. sid ..
                                    " name=" .. nm)
                            else
                                log("WARN: BeginLoadData re-issue failed [" .. tostring(k) ..
                                    "] sid=" .. sid .. " name=" .. nm)
                            end
                        end
                    end
                end
            end
        end
    end
    for k in pairs(loaded_sid) do
        if not live[k] then loaded_sid[k] = nil end
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

local save_player_hooked, save_player_tries = false, 0
local save_flush_guard = false
local function force_save_to_disk(reason)
    if save_flush_guard then return end
    save_flush_guard = true
    local sm = FindFirstOf("BPC_SaveManager_C")
    if sm and sm:IsValid() then
        local ok = pcall(function() sm:SaveToDisk() end)
        log("forced SaveToDisk reason=" .. tostring(reason or "") .. " ok=" .. tostring(ok))
    end
    save_flush_guard = false
end
local save_reentry = {}
local function save_sid_for_controller(c)
    if not (c and c:IsValid()) then return nil end
    -- The listen-server's local controller emits blank/BAD save IDs during
    -- normal hosting. Do not rewrite it to a remote player's identity.
    if c:IsLocalPlayerController() then return nil end
    local nm = pname(c)
    if nm == "" then return nil end
    return synthId(nm)
end
local function reissue_corrected_player_save(c, k, sid, playerdata, why)
    if save_reentry[k] or playerdata == nil then return false end
    local s
    if not pcall(function() s = playerdata:get() end) or not validish(s) then return false end
    save_reentry[k] = true
    local ok2, err2 = pcall(function() c:SERVER_SavePlayerdata(s) end)
    save_reentry[k] = nil
    log("SERVER_SavePlayerdata corrected reissue why=" .. tostring(why or "") ..
        " sid=" .. tostring(sid) .. " ok=" .. tostring(ok2) .. " err=" .. tostring(err2))
    return ok2
end
local function try_install_save_player_hook()
    if save_player_hooked then return end
    save_player_tries = save_player_tries + 1
    local ok = pcall(function()
        RegisterHook(BLD_CLASS .. ":SERVER_SavePlayerdata", function(self, playerdata)
            pcall(function()
                local c = self:get()
                if not c or not c:IsValid() then return end
                local k = akey(c)
                if SP.kicked[k] then return end
                local sid = save_sid_for_controller(c)
                if not sid then return end
                stamp_persistence_ids(c, sid, "pre-save")
                local did = stamp_playerdata_param(playerdata, sid, "pre-save")
                if did then reissue_corrected_player_save(c, k, sid, playerdata, "pre-save") end
            end)
        end, function()
            pcall(function() force_save_to_disk("post-player-save") end)
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
    try_install_save_slot_hooks()

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
