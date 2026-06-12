-- SolarpunkNoPhantomHost: two in-game display fixes for the headless listen host.
--
--  (1) The host's own generated player (PlayerState name "server-<hex>" / the
--      host machine identity) is a real replicated pawn + PlayerState, so every
--      joining client SEES it standing in the world and lists it in the PLAYERS
--      overlay. The overlay renders CLIENT-side from replicated PlayerStates, so
--      a server-side PlayerArray prune does nothing — the fix is to stop the
--      host PlayerState + pawn REPLICATING (SetReplicates(false)): the client
--      proxies are torn down and the row/pawn vanish. Spectator flags + a blanked
--      PlayerNamePrivate stay on as belt-and-braces if replication-stop fails.
--
--  (2) A remote player's in-game nameplate/PLAYERS row shows the per-session
--      machine identity (e.g. MACHINE-PC-<hex>) instead of the launcher
--      character name. The engine name (PlayerNamePrivate, what GetPlayerName /
--      the HTTP roster read) is already corrected by the client-side
--      SolarpunkConnect keeper — the in-game UI reads a DIFFERENT, game-owned
--      surface. This mod discovers and rewrites those surfaces with the clean
--      character name:
--        a. any game-added FString/FName/FText property on the PlayerState or
--           Pawn whose value still carries the machine identity (reflection
--           walk; every rewrite is logged "prop <object>.<field> old -> new"
--           so the carrying field is identified from the log), and
--        b. THE actual UI surface (proven live 2026-06-11): the REPLICATED
--           BP_SkyGameGameState_C.UniqueIDToPlayerNames TArray of
--           S_UniqueIDToPlayerName structs. The PLAYERS list rebuilds its rows
--           from it ("Refresh Entries" on menu open) and W_PlayerNamePlate is
--           SetPlayerName'd from the same lookup at creation. Direct struct
--           field writes replicate; see fix_name_array below.
--
-- HARD RULES INHERITED FROM THE STACK (see SolarpunkServerRuntime):
--  * NO mod-owned LoopAsync: all periodic work runs as SP.every game-thread
--    scheduler tasks (cross-thread Lua was the 2026-06-10 full-stack crash).
--  * Never touch a controller that is mid-join-transition (SP.settled) or
--    kicked (SP.kicked).
--  * Never write PlayerNamePrivate on a REMOTE player: SolarpunkAuth reads the
--    __SPPW__ token from it during its grace window, and the client keeper
--    re-asserts it — both fight a server-side rewrite. The host (auth-exempt,
--    no keeper) is the only PlayerState whose engine name we blank.
--  * Never pass a bare Lua string to an FText property/argument (uncatchable
--    native AV on this build) — FText goes through make_ftext, FName through
--    FName().
--
-- Log: %APPDATA%\Solarpunk\SolarpunkNoPhantomHost.log

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkNoPhantomHost.log"

local once = {}
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n"); f:close() end
    print("[SolarpunkNoPhantomHost] " .. tostring(msg) .. "\n")
end
local function log_once(k, m) if once[k] then return end once[k] = true log(m) end

local SP = _G.SolarpunkSP
if not SP then
    error("SolarpunkNoPhantomHost requires SolarpunkServerRuntime (load via the orchestrator)")
end

-- ── tiny object helpers ─────────────────────────────────────────────────────
local function is_valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function full_name(o)
    if not is_valid(o) then return "<invalid>" end
    local ok, n = pcall(function() return tostring(o:GetFullName()) end)
    if ok and n and n ~= "" then return n end
    return "<unknown>"
end
local function short_name(o)
    local fn = full_name(o)
    return fn:match("([^%.: ]+)$") or fn
end
local function call(o, m, ...)
    if not is_valid(o) then return false end
    local ok_get, fn = pcall(function() return o[m] end)
    if not ok_get or (type(fn) ~= "function" and type(fn) ~= "userdata") then return false end
    local args = { ... }
    local up = table.unpack or unpack
    local ok = pcall(function() return fn(o, up(args)) end)
    return ok
end
local function set_field(o, f, v)
    if not is_valid(o) then return false end
    return pcall(function() o[f] = v end)
end
local function akey(o)
    local k = 0
    pcall(function() k = o:GetAddress() end)
    return k
end

-- FText must be constructed, never coerced from a bare Lua string (native AV).
local function make_ftext(s)
    local ft
    if pcall(function() ft = FText(s) end) and ft ~= nil then return ft end
    if pcall(function() ft = FText.FromString(s) end) and ft ~= nil then return ft end
    if pcall(function() ft = FText.new(s) end) and ft ~= nil then return ft end
    return nil
end

-- ── name shapes ─────────────────────────────────────────────────────────────
-- Keep byte-identical with SolarpunkAuth.AUTH_DELIM / SolarpunkHost.clean_name.
local AUTH_DELIM = "__SPPW__"
local function clean_name(raw)
    raw = tostring(raw or "")
    local i = raw:find(AUTH_DELIM, 1, true)
    if i then return raw:sub(1, i - 1) end
    return raw
end

-- Generated machine-identity shapes observed on this game (OSS Null profile
-- name): "server-680B752F44B1A" (host) and "<MACHINE>-PC-<hex>" (per-session
-- client identity). Shape = <prefix>-<6+ hex chars>; the prefix is either the
-- literal "server" or an UPPERCASE machine-name shape. Deliberately narrow so
-- a legitimate character name is never classified as phantom.
local function is_phantom_name(name)
    if type(name) ~= "string" then return false end
    local prefix, suffix = name:match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    if suffix == nil or #suffix < 6 then return false end
    if prefix == "server" then return true end
    return prefix:match("^[A-Z0-9_%-]+$") ~= nil
end

local function ps_of(pc)
    local ps
    pcall(function() ps = pc.PlayerState end)
    if is_valid(ps) then return ps end
    return nil
end
local function pawn_of(pc)
    local pawn
    pcall(function() pawn = pc.Pawn end)
    if is_valid(pawn) then return pawn end
    pcall(function() pawn = pc:K2_GetPawn() end)
    if is_valid(pawn) then return pawn end
    return nil
end
local function raw_player_name(ps)
    local nm = ""
    pcall(function() nm = ps:GetPlayerName():ToString() end)
    return tostring(nm or "")
end

-- ── (1) host phantom: stop replication, hide, blank ─────────────────────────
local host_done = {}   -- [object addr] = true once processed

local function sanitize_host_object(o, what, hide)
    local k = akey(o)
    if k == 0 or host_done[k] then return end
    host_done[k] = true
    local ops = {}
    if call(o, "SetReplicates", false) then ops[#ops + 1] = "SetReplicates(false)" end
    if set_field(o, "bOnlyRelevantToOwner", true) then ops[#ops + 1] = "bOnlyRelevantToOwner" end
    if set_field(o, "bAlwaysRelevant", false) then ops[#ops + 1] = "bAlwaysRelevant=false" end
    if hide then
        if call(o, "SetActorHiddenInGame", true) then ops[#ops + 1] = "SetActorHiddenInGame" end
        if set_field(o, "bCanBeDamaged", false) then ops[#ops + 1] = "bCanBeDamaged=false" end
    end
    log("host " .. what .. " sanitized: " .. table.concat(ops, ", ") ..
        " obj=" .. full_name(o))
end

local function sanitize_host(pc)
    local ps = ps_of(pc)
    if ps then
        local k = akey(ps)
        if k ~= 0 and not host_done[k] then
            local nm = raw_player_name(ps)
            sanitize_host_object(ps, "PlayerState name='" .. nm .. "'", false)
            -- belt-and-braces if replication-stop didn't take: spectator-flag +
            -- blank the engine name (host is auth-exempt; no keeper fights this)
            set_field(ps, "bIsSpectator", true)
            set_field(ps, "bOnlySpectator", true)
            set_field(ps, "bIsABot", true)
            if set_field(ps, "PlayerNamePrivate", "") then
                call(ps, "OnRep_PlayerName")
                log("host PlayerState engine name blanked (was '" .. nm .. "')")
            end
        end
    end
    local pawn = pawn_of(pc)
    if pawn then sanitize_host_object(pawn, "Pawn", true) end
end

-- ── (2) remote display-name fix + discovery ─────────────────────────────────
-- Reflection walk over an object's class chain collecting string-ish
-- properties: { name, kind = "Str"|"Name"|"Text" }.
local function stringy_props(obj)
    local out = {}
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not is_valid(cls) then return out end
    local guard = 0
    while is_valid(cls) and guard < 24 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local pfull = tostring(prop:GetFullName())
                    local kind = pfull:match("^(%a+)Property")
                    if kind == "Str" or kind == "Name" or kind == "Text" then
                        local pname
                        pcall(function() pname = prop:GetFName():ToString() end)
                        if not pname then pname = pfull:match("([^%.:]+)$") end
                        if pname then out[#out + 1] = { name = pname, kind = kind } end
                    end
                end)
            end)
        end)
        local sup
        if not pcall(function() sup = cls:GetSuperStruct() end) then break end
        if not is_valid(sup) then break end
        cls = sup
    end
    return out
end

-- Fallback when ForEachProperty is unavailable on this UE4SS build: probe a
-- curated list of likely display-name fields (FString-read-back only).
local CANDIDATE_PROPS = {
    "PlayerName", "Username", "UserName", "NickName", "Nickname",
    "PlayerNickname", "DisplayName", "PlayerDisplayName", "CharacterName",
    "CharName", "ProfileName", "SteamName", "OnlineName", "NetworkName",
}

local function read_prop_string(obj, pname)
    local v
    if not pcall(function() v = obj[pname] end) then return nil end
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

local function write_prop(obj, pname, kind, value)
    if kind == "Str" then
        return set_field(obj, pname, value)
    elseif kind == "Name" then
        local fn
        if not pcall(function() fn = FName(value) end) or fn == nil then return false end
        return set_field(obj, pname, fn)
    elseif kind == "Text" then
        local ft = make_ftext(value)
        if ft == nil then return false end
        return set_field(obj, pname, ft)
    end
    return false
end

local dumped = {}   -- [object addr] = true once its props were dumped to the log

local function dump_props(obj, label)
    local k = akey(obj)
    if k == 0 or dumped[k] then return end
    dumped[k] = true
    local props = stringy_props(obj)
    if #props == 0 then
        log("DISCOVER " .. label .. " " .. short_name(obj) ..
            ": reflection walk found no string props (ForEachProperty unavailable?) — using candidate list")
        for _, pname in ipairs(CANDIDATE_PROPS) do
            local s = read_prop_string(obj, pname)
            if s and s ~= "" then
                log("DISCOVER " .. label .. " ." .. pname .. " = '" .. s .. "'")
            end
        end
        return
    end
    for _, p in ipairs(props) do
        local s = read_prop_string(obj, p.name)
        if s and s ~= "" and #s <= 96 then
            log("DISCOVER " .. label .. " ." .. p.name .. " (" .. p.kind .. ") = '" .. s .. "'")
        end
    end
end

-- Rewrite every string-ish property on obj whose value still carries the
-- machine identity. Returns number of rewrites.
local function fix_props(obj, label, want)
    if not is_valid(obj) then return 0 end
    local fixes = 0
    local props = stringy_props(obj)
    if #props == 0 then
        -- candidate fallback: FString-shaped reads only (safe to write back)
        for _, pname in ipairs(CANDIDATE_PROPS) do
            local v
            if pcall(function() v = obj[pname] end) and type(v) == "string"
                and v ~= want and is_phantom_name(clean_name(v)) then
                if set_field(obj, pname, want) then
                    fixes = fixes + 1
                    call(obj, "OnRep_" .. pname)
                    log("FIXED prop " .. label .. " ." .. pname .. " '" .. v .. "' -> '" .. want .. "'")
                end
            end
        end
        return fixes
    end
    for _, p in ipairs(props) do
        if p.name ~= "PlayerNamePrivate" then   -- never fight auth/keeper on the engine name
            local s = read_prop_string(obj, p.name)
            if s and s ~= want and is_phantom_name(clean_name(s)) then
                if write_prop(obj, p.name, p.kind, want) then
                    fixes = fixes + 1
                    call(obj, "OnRep_" .. p.name)
                    log("FIXED prop " .. label .. " ." .. p.name .. " (" .. p.kind .. ") '" ..
                        s .. "' -> '" .. want .. "'")
                else
                    log("FAILED writing prop " .. label .. " ." .. p.name .. " (" .. p.kind .. ")")
                end
            end
        end
    end
    return fixes
end

-- Server-side name keeper. The game re-stamps the OSS Null machine identity
-- onto PlayerState after join, and the client-side SolarpunkConnect keeper
-- only corrects it every 2s — a visible flap window the in-game UI can catch.
-- Remember the last GOOD raw name per controller (good = clean part is not a
-- machine shape) and restore it within one 250ms tick of a re-stamp. The RAW
-- name (token included) is restored verbatim, so SolarpunkAuth's token read
-- and the client keeper's full-name compare both see exactly what the client
-- itself asserted — this writer can never destroy an auth token.
local good_name = {}      -- [controller addr] = last known good RAW name
local last_seen = {}      -- [controller addr] = last observed raw name (for transition logging)
local machine_of = {}     -- [machine-shaped clean name] = controller addr that wore it

local function keep_name(pc, k)
    local ps = ps_of(pc)
    if not ps then return end
    local raw = raw_player_name(ps)
    if raw ~= last_seen[k] then
        log("name transition [" .. tostring(k) .. "]: '" .. tostring(last_seen[k]) .. "' -> '" .. raw .. "'")
        last_seen[k] = raw
    end
    if raw ~= "" and not is_phantom_name(clean_name(raw)) then
        good_name[k] = raw
        return
    end
    if raw ~= "" then machine_of[clean_name(raw)] = k end
    local want = good_name[k]
    if want and want ~= "" and raw ~= want then
        if set_field(ps, "PlayerNamePrivate", want) then
            call(ps, "OnRep_PlayerName")
            log("re-stamp reverted [" .. tostring(k) .. "]: '" .. raw .. "' -> '" .. want .. "'")
        end
    end
end

-- ── (2b) GameState UniqueIDToPlayerNames — THE in-game name surface ─────────
-- PROVEN 2026-06-11 by live discovery on a dedicated host with a real retail client:
--   * BP_SkyGameGameState_C.UniqueIDToPlayerNames is a REPLICATED
--     TArray<S_UniqueIDToPlayerName> (struct: UniqueID Str, PlayerName Str —
--     hash-suffixed BP field names, resolved at runtime so build churn can't
--     silently break us).
--   * The PLAYERS list (W_IngameMenu > SW_IngameMenuOnlineUI > SW_PlayerList)
--     renders one row per replicated PlayerState and resolves each row's
--     DISPLAY name from this array ("Refresh Entries" reruns on menu open);
--     W_PlayerNamePlate gets SetPlayerName'd from the same lookup at creation.
--     PlayerNamePrivate is NOT what the in-game UI shows.
--   * The game appends entries at join carrying whatever GetPlayerName()
--     returned at that instant — the OSS Null machine identity
--     (MACHINE-PC-<hex>), plus the host's junk pair
--     (UniqueID='ERROR, BAD UNIQUE NET ID', PlayerName='server-<hex>').
--   * UpdateUniqueIDToPlayerNames takes NO args (self-refresh off the save
--     manager) — a 2-arg call can never work. Direct struct-field writes DO
--     work and DO replicate to connected clients (validated end-to-end).
-- The sweep below runs on the fast tick: host junk entries are blanked, and
-- machine-identity names are rewritten to the owning character name. Match
-- order: exact machine-name history (machine_of, stamped by keep_name) ->
-- controller/pawn UniquePlayerID -> single-remote fallback.
local function uid_string(obj, prop)
    local uid
    if not pcall(function() uid = obj[prop] end) or uid == nil then return nil end
    if type(uid) == "string" then return uid ~= "" and uid or nil end
    local s
    if pcall(function() s = uid:ToString() end) and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function fstr_val(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

local HOST_JUNK_UID = "ERROR, BAD UNIQUE NET ID"
local NAME_STRUCT_PATH = "/Game/Code/Misc/S_UniqueIDToPlayerName.S_UniqueIDToPlayerName"
local sf_uid, sf_name      -- resolved S_UniqueIDToPlayerName field names
local sf_warned = false

local function resolve_struct_fields()
    if sf_uid and sf_name then return true end
    local sdef
    pcall(function() sdef = StaticFindObject(NAME_STRUCT_PATH) end)
    if not is_valid(sdef) then return false end
    pcall(function()
        sdef:ForEachProperty(function(p)
            pcall(function()
                local nm = tostring(p:GetFName():ToString())
                if nm:find("^UniqueID") then sf_uid = nm
                elseif nm:find("^PlayerName") then sf_name = nm end
            end)
        end)
    end)
    if sf_uid and sf_name then
        log("name-array struct fields resolved: " .. sf_uid .. " / " .. sf_name)
        return true
    end
    if not sf_warned then
        sf_warned = true
        log("WARN: could not resolve S_UniqueIDToPlayerName fields (struct moved?)")
    end
    return false
end

local fixed_logged = {}    -- ["uid>want"] = true (log each rewrite once)

local function fix_name_array()
    if not resolve_struct_fields() then return end
    local gs = FindFirstOf("BP_SkyGameGameState_C")
    if not is_valid(gs) then return end
    local arr
    if not pcall(function() arr = gs.UniqueIDToPlayerNames end) or arr == nil then return end
    -- collect remote identities once per sweep
    local by_uid = {}      -- uid string -> clean character name
    local singles = {}     -- distinct clean names of settled remote players
    local cs = SP.controllers()
    if cs then
        for _, pc in ipairs(cs) do
            if pc and pc:IsValid() then
                local k = akey(pc)
                if not SP.kicked[k] then
                    local is_local = false
                    pcall(function() is_local = pc:IsLocalPlayerController() end)
                    if not is_local and good_name[k] then
                        local want = clean_name(good_name[k])
                        if want ~= "" and not is_phantom_name(want) then
                            if not singles[want] then
                                singles[want] = true
                                singles[#singles + 1] = want
                            end
                            local u1 = uid_string(pc, "UniquePlayerID")
                            if u1 then by_uid[u1] = want end
                            local pawn = pawn_of(pc)
                            if pawn then
                                local u2 = uid_string(pawn, "UniquePlayerID")
                                if u2 then by_uid[u2] = want end
                            end
                        end
                    end
                end
            end
        end
    end
    pcall(function()
        arr:ForEach(function(_, el)
            local s = el:get()
            if s == nil then return end
            local uid = fstr_val(s[sf_uid]) or ""
            local name = fstr_val(s[sf_name])
            if name == nil then return end
            -- host junk entry: blank the display name (the host has no row —
            -- its PlayerState never replicates — this is belt-and-braces for
            -- any lookup that resolves the junk uid)
            if uid == HOST_JUNK_UID or name:match("^server%-[0-9A-Fa-f]+$") then
                if name ~= "" then
                    pcall(function() s[sf_name] = "" end)
                    log("name-array host entry blanked (was '" .. name .. "')")
                end
                return
            end
            local cleaned = clean_name(name)
            if not is_phantom_name(cleaned) then return end
            local owner_k = machine_of[cleaned]
            local want = (owner_k and good_name[owner_k] and clean_name(good_name[owner_k]))
                or by_uid[uid]
                or (#singles == 1 and singles[1] or nil)
            if want and want ~= "" and not is_phantom_name(want) and want ~= name then
                if pcall(function() s[sf_name] = want end) then
                    local lk = tostring(uid) .. ">" .. want
                    if not fixed_logged[lk] then
                        fixed_logged[lk] = true
                        log("name-array [" .. tostring(uid) .. "] '" .. name .. "' -> '" .. want .. "'")
                    end
                end
            end
        end)
    end)
end

local function fix_remote(pc)
    local ps = ps_of(pc)
    if not ps then return end
    local want = clean_name(raw_player_name(ps))
    -- until the keeper's character name has landed there is no trusted name to
    -- write; never propagate a machine identity or an empty string.
    if want == "" or is_phantom_name(want) then return end
    dump_props(ps, "PlayerState")
    fix_props(ps, "PlayerState", want)
    local pawn = pawn_of(pc)
    if pawn then
        dump_props(pawn, "Pawn")
        fix_props(pawn, "Pawn", want)
    end
end

-- ── scheduler tasks ─────────────────────────────────────────────────────────
-- Fast tick: revert machine-identity re-stamps within 250ms.
SP.every("nophantom-keepname", 250, 0, function()
    local cs = SP.controllers()
    if not cs then return end
    for _, pc in ipairs(cs) do
        if pc and pc:IsValid() then
            local k = akey(pc)
            if not SP.kicked[k] and SP.settled(k) then
                local is_local = false
                pcall(function() is_local = pc:IsLocalPlayerController() end)
                if not is_local then pcall(keep_name, pc, k) end
            end
        end
    end
    pcall(fix_name_array)
end)

SP.every("nophantom", 1000, 750, function()
    local cs = SP.controllers()
    if not cs then return end
    for _, pc in ipairs(cs) do
        if pc and pc:IsValid() then
            local k = akey(pc)
            if not SP.kicked[k] then
                local is_local = false
                pcall(function() is_local = pc:IsLocalPlayerController() end)
                if is_local then
                    pcall(sanitize_host, pc)
                elseif SP.settled(k) then
                    pcall(fix_remote, pc)
                end
            end
        end
    end
end)

log("SolarpunkNoPhantomHost loaded (host de-replication + remote display-name enforcement)")
