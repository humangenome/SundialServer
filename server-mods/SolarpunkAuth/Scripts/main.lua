-- SolarpunkAuth: server-side password gate for Solarpunk headless hosts.
-- Port of Beacon's BeaconAuth (SN2) to Solarpunk (UE 5.7).
--
-- TRANSPORT REALITY (proven on the box 2026-06-10, supersedes the K2_PostLogin
-- + ?Password design below):
--   1. /Script/Engine.GameModeBase:K2_PostLogin does NOT fire for remote
--      IpNetDriver clients on this build — only for the listen host's local
--      player. The game's custom login path drives remote joins through
--      BP_MainPlayerController:BeginLoadData (and PlayerController::
--      ServerAcknowledgePossession), NOT the engine PostLogin event. So the
--      gate hook is BeginLoadData, which is PROVEN to fire for every remote
--      client (with a live IpConnection).
--   2. The client's `?Password=` / `?Name=` URL options are NOT readable from
--      Lua on this build: FString *properties* (UNetConnection.RequestURL,
--      FURL.Op[], FURL.Host) reflect as null UObjects, and no UFunction returns
--      the per-connection options. Only FString *returned from a UFunction* is
--      readable (APlayerState:GetPlayerName, UGameplayStatics:ParseOption both
--      work). The one readable inbound channel the client controls is therefore
--      its player NAME (set via ?Name=, surfaced through GetPlayerName).
--
-- AUTH CONTRACT (name-channel): the launcher connects with
--     open <ip>:<port>?Name=<character>__SPPW__<password>
--   when the server is password-protected (no token when it is open). The gate
--   reads GetPlayerName, splits on the "__SPPW__" delimiter, and compares the
--   token to SolarpunkAuthPassword. Mismatch / missing token => kick. The
--   character identity used for save/roster keying is the part BEFORE the
--   delimiter (SolarpunkHost + SolarpunkRoster strip it the same way via
--   clean_name), so the password never pollutes the save key or the published
--   roster name. The listen-server host (local player, no NetConnection) is
--   positively detected and exempt.
--
-- Config source: SolarpunkServer\appsettings.json key "SolarpunkAuthPassword"
-- (panel-written; same contract as SolarpunkServer's SourceQueryHostedService
-- which advertises A2S PasswordRequired from the same key).
-- Status file: SolarpunkServer\.solarpunk-auth-status (key=value lines:
-- ready, passwordConfigured, updated, reason) read by SolarpunkServer's
-- HeartbeatWatchdogService for the fail-closed contract.

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local SCRIPT_SOURCE = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
if SCRIPT_SOURCE:sub(1, 1) == "@" then SCRIPT_SOURCE = SCRIPT_SOURCE:sub(2) end

local function get_mod_dir()
    local src = SCRIPT_SOURCE
    if src == "" then return nil end
    local sep = src:find("\\Scripts\\", 1, true) or src:find("/Scripts/", 1, true)
    if not sep then return nil end
    return src:sub(1, sep - 1)
end

local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkAuth.log"

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkAuth] " .. tostring(msg) .. "\n")
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Locate SolarpunkServer\appsettings.json by walking up from the mod dir.
-- Panel layout: <dirid>\Solarpunk\Binaries\Win64\ue4ss\Mods\SolarpunkAuth
-- with <dirid>\SolarpunkServer\appsettings.json as the 6th-parent sibling.
local function find_appsettings()
    local candidates = {}
    local mod_dir = get_mod_dir()
    if mod_dir then
        local dir = mod_dir
        for _ = 1, 8 do
            table.insert(candidates, dir .. "\\SolarpunkServer\\appsettings.json")
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
                table.insert(candidates, dir .. "\\SolarpunkServer\\appsettings.json")
                local parent = dir:match("^(.+)\\[^\\]+$")
                if not parent or parent == dir then break end
                dir = parent
            end
        end
    end
    for _, candidate in ipairs(candidates) do
        if file_exists(candidate) then
            log("appsettings.json located: " .. candidate)
            return candidate
        end
    end
    return nil
end

-- Minimal JSON string extractor (same as BeaconAuth's, incl. \uXXXX decode).
local function codepoint_to_utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + (math.floor(cp / 0x1000) % 0x40),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end
end

local function extract_json_string(json_text, key)
    if not json_text then return nil end
    local _, value_start = json_text:find('"' .. key .. '"%s*:%s*"')
    if value_start == nil then return nil end
    local out = {}
    local i = value_start + 1
    while i <= #json_text do
        local ch = json_text:sub(i, i)
        if ch == "\\" then
            local nxt = json_text:sub(i + 1, i + 1)
            if nxt == '"' then out[#out + 1] = '"'; i = i + 2
            elseif nxt == "\\" then out[#out + 1] = "\\"; i = i + 2
            elseif nxt == "/" then out[#out + 1] = "/"; i = i + 2
            elseif nxt == "b" then out[#out + 1] = "\b"; i = i + 2
            elseif nxt == "f" then out[#out + 1] = "\f"; i = i + 2
            elseif nxt == "n" then out[#out + 1] = "\n"; i = i + 2
            elseif nxt == "r" then out[#out + 1] = "\r"; i = i + 2
            elseif nxt == "t" then out[#out + 1] = "\t"; i = i + 2
            elseif nxt == "u" then
                local hex = json_text:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if not cp then
                    i = i + 2
                else
                    i = i + 6
                    if cp >= 0xD800 and cp <= 0xDBFF then
                        if json_text:sub(i, i + 1) == "\\u" then
                            local hex2 = json_text:sub(i + 2, i + 5)
                            local low = tonumber(hex2, 16)
                            if low and low >= 0xDC00 and low <= 0xDFFF then
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                                i = i + 6
                            else
                                cp = 0xFFFD
                            end
                        else
                            cp = 0xFFFD
                        end
                    elseif cp >= 0xDC00 and cp <= 0xDFFF then
                        cp = 0xFFFD
                    end
                    out[#out + 1] = codepoint_to_utf8(cp)
                end
            else
                out[#out + 1] = nxt
                i = i + 2
            end
        elseif ch == '"' then
            break
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Status writer (atomic tmp+rename, retried; see BeaconAuth for rationale).
local APPSETTINGS_PATH = nil
local STATUS_FILE_PATH = nil

local function write_status(ready, passwordConfigured, reason)
    if not STATUS_FILE_PATH then return end
    local lines = {
        "ready=" .. (ready and "1" or "0"),
        "passwordConfigured=" .. (passwordConfigured and "1" or "0"),
        "updated=" .. tostring(os.time()),
        "reason=" .. tostring(reason or ""),
    }
    local tmpPath = STATUS_FILE_PATH .. ".tmp"
    local f = io.open(tmpPath, "wb")
    if not f then
        log("write_status: failed to open tmp " .. tmpPath)
        return
    end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    local rename_ok = false
    local rename_err = ""
    for attempt = 1, 5 do
        os.remove(STATUS_FILE_PATH)
        local ok, err = os.rename(tmpPath, STATUS_FILE_PATH)
        if ok then rename_ok = true; break end
        rename_err = tostring(err)
        if attempt < 5 then
            os.execute('ping -n 1 -w 100 127.0.0.1 > NUL 2>NUL')
        end
    end
    if not rename_ok then
        log("write_status: rename failed after retries: " .. rename_err)
        os.remove(tmpPath)
    end
end

local CONFIGURED_PASSWORD = ""
do
    local path = find_appsettings()
    APPSETTINGS_PATH = path
    if path then
        STATUS_FILE_PATH = path:gsub("[\\/]appsettings%.json$", "") .. "\\.solarpunk-auth-status"
        local body = read_all(path)
        -- SolarpunkAuthPassword only; byte-exact, no trim (panel normalises
        -- at input time, launcher sends byte-exact).
        CONFIGURED_PASSWORD = extract_json_string(body, "SolarpunkAuthPassword") or ""
        if CONFIGURED_PASSWORD == "" then
            log("SolarpunkAuthPassword is empty - auth check disabled (server is open)")
            write_status(true, false, "no_password_configured")
        else
            log("SolarpunkAuthPassword loaded (length=" .. #CONFIGURED_PASSWORD .. "); auth check active")
            write_status(false, true, "loading")
        end
    else
        log("appsettings.json not found - auth check disabled")
    end
end

-- Name-channel auth -------------------------------------------------------
-- The launcher carries the password in the player name after this delimiter.
-- Keep this byte-identical with SolarpunkHost.clean_name / SolarpunkRoster.
local AUTH_DELIM = "__SPPW__"

-- Split a raw GetPlayerName into { character, token }. No delimiter => token
-- is "" (treated as "no password supplied").
local function split_name(raw)
    raw = tostring(raw or "")
    local i = raw:find(AUTH_DELIM, 1, true)
    if not i then return raw, "" end
    return raw:sub(1, i - 1), raw:sub(i + #AUTH_DELIM)
end

local function is_transient_identity_name(name)
    if type(name) ~= "string" then return false end
    if name == "TESTING UID" or name == "ERROR, BAD UNIQUE NET ID" then return true end
    if name:match("^DESKTOP%-[A-Z0-9%-]+$") then return true end
    if name:match("^[A-Z0-9_%-]+%-PC%-[0-9A-Fa-f]+$") then return true end
    local _, suffix = name:match("^([%w_%-]+)%-([0-9A-Fa-f]+)$")
    return suffix ~= nil and #suffix >= 8
end

local function player_name(pc)
    local nm = ""
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then nm = ps:GetPlayerName():ToString() end
    end)
    return nm
end

-- ── Ban enforcement ─────────────────────────────────────────────────────────
-- The supervisor (RconHostedService `ban`/`unban`) writes active banned
-- synthetic ids to <SolarpunkServer>\bans.txt (one "765611900…" per line). We
-- compute a joining player's synthetic id the SAME way SolarpunkRoster does
-- (crc32 over the lowercased character name, token stripped) so a `ban` issued
-- against a roster SolarpunkUserId matches here, and kick anyone listed —
-- regardless of the join password.
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
local function synth_id(character)
    return string.format("765611900%09d", crc32(string.lower(character)) % 1000000000)
end

local BANS_PATH = STATUS_FILE_PATH and
    STATUS_FILE_PATH:gsub("\\%.solarpunk%-auth%-status$", "\\bans.txt") or nil
local BANNED = {}        -- [synth_id] = true
local function load_bans()
    if not BANS_PATH then return end
    local set = {}
    local body = read_all(BANS_PATH)
    if body then
        for line in body:gmatch("[^\r\n]+") do
            local id = line:match("^%s*(%d+)%s*$")
            if id then set[id] = true end
        end
    end
    BANNED = set
end
load_bans()

local function akey(pc)
    local k = 0
    pcall(function() k = pc:GetAddress() end)
    return k
end

-- Shared scheduler/state from SolarpunkServerRuntime (see the STABILITY
-- CONTRACT comment there). The gate runs as a game-thread scheduler task;
-- SP.kicked is the cross-mod "hands off this dying controller" set and
-- SP.settled() keeps kicks out of the join transition window.
local SP = _G.SolarpunkSP
if not SP then
    error("SolarpunkAuth requires SolarpunkServerRuntime (load via the orchestrator)")
end

-- Build a real FText. KickPlayer / ClientReturnToMainMenuWithTextReason take
-- an FText, and passing a bare Lua string to a reflected FText arg is an
-- uncatchable native AV on this build (the crash that killed an early host).
-- Same routes as BeaconHud.make_ftext.
local function make_ftext(s)
    local ft
    if pcall(function() ft = FText(s) end) and ft ~= nil then return ft end
    if pcall(function() ft = FText.FromString(s) end) and ft ~= nil then return ft end
    if pcall(function() ft = FText.new(s) end) and ft ~= nil then return ft end
    return nil
end
local KICK_REASON = make_ftext("Server password incorrect.")
local IDENTITY_KICK_REASON = make_ftext("Please close and reopen Sundial, then reconnect.")

-- Find the active GameSession (for KickPlayer). Cached after first resolve.
local g_game_session = nil
local function game_session()
    if g_game_session and g_game_session:IsValid() then return g_game_session end
    g_game_session = nil
    pcall(function()
        local gs = FindFirstOf("GameSession")
        if gs and gs:IsValid() then g_game_session = gs end
    end)
    return g_game_session
end

-- Kick a controller ONCE. Never call this repeatedly on the same PC — kicking
-- a half-torn-down PlayerController/NetConnection re-enters UE4SS dispatch on a
-- dying object and crashes. The single engine-sanctioned KickPlayer drops the
-- connection cleanly; ClientReturnToMainMenuWithTextReason is the fallback.
local function kick_once(pc, reason)
    if not pc or not pc:IsValid() then return false end
    local kick_reason = reason or KICK_REASON
    local ok_any = false
    local gs = game_session()
    if gs and kick_reason ~= nil then
        if pcall(function() gs:KickPlayer(pc, kick_reason) end) then ok_any = true end
    end
    if kick_reason ~= nil then
        pcall(function() pc:ClientReturnToMainMenuWithTextReason(kick_reason) end)
    end
    return ok_any
end

-- Grace before kicking a not-yet-valid client. The launcher (with the client
-- plugin) makes ?Name=<char>__SPPW__<pw> stick AT JOIN, so the token is present
-- on the very first evaluate and the client is admitted immediately. The grace
-- only matters when the name lands slightly after the connection forms (engine
-- name propagation / a post-join ServerChangeName), so a legitimate client is
-- never kicked on a transient empty/placeholder name. An unauthorized client
-- that never presents the token is kicked once the grace elapses.
local GRACE_SECONDS = 4

-- Per-controller verdicts. Each controller is decided EXACTLY ONCE; we never
-- re-touch a kicked PC (re-kicking the dying object crashes UE4SS). The
-- kicked set is the SHARED SP.kicked so Host/Roster/Chat also keep their
-- hands off a dying controller.
local kicked = SP.kicked   -- [addr] = true (denied + kicked once; leave alone)
local verified = {}        -- [addr] = true (allow, already checked OK)
local first_seen = {}      -- [addr] = os.time() first observed without a valid token

local function evaluate(pc)
    if not pc or not pc:IsValid() then return end
    if pc:IsLocalPlayerController() then return end   -- listen host: exempt
    local k = akey(pc)
    if verified[k] or kicked[k] then return end        -- decided already
    local raw = player_name(pc)
    local character, token = split_name(raw)
    -- NEVER kick mid-join-transition: KickPlayer on a controller whose
    -- BeginLoadData chain is still running re-enters the engine on a
    -- half-loaded object (UE4SS-on-5.7 AV class). Verdicts that ALLOW are
    -- fine any time; verdicts that KICK wait until the transition settles.
    local can_kick = SP.settled(k)
    -- Ban gate first: a banned synthetic id is rejected regardless of password.
    if character ~= "" and next(BANNED) ~= nil and BANNED[synth_id(character)] then
        if not can_kick then
            if not first_seen[k] then first_seen[k] = os.time() end
            return
        end
        kicked[k] = true
        first_seen[k] = nil
        log("auth DENY (banned) id=" .. synth_id(character) .. " [" .. tostring(k) .. "] -- kicking")
        kick_once(pc)
        return
    end
    -- Password gate: an empty CONFIGURED_PASSWORD means the server is open, so
    -- only the ban gate above applies; otherwise require the matching token.
    if CONFIGURED_PASSWORD == "" and is_transient_identity_name(character) then
        if not first_seen[k] then first_seen[k] = os.time(); return end
        if os.time() - first_seen[k] < GRACE_SECONDS then return end
        if not can_kick then return end
        kicked[k] = true
        first_seen[k] = nil
        log("auth DENY (transient identity) name='" .. tostring(raw) ..
            "' [" .. tostring(k) .. "] -- kicking (relaunch required)")
        kick_once(pc, IDENTITY_KICK_REASON)
        return
    end
    if CONFIGURED_PASSWORD == "" or (raw ~= "" and token == CONFIGURED_PASSWORD) then
        verified[k] = true
        first_seen[k] = nil
        log("auth OK for '" .. raw:gsub(AUTH_DELIM .. ".*", AUTH_DELIM .. "<redacted>") .. "' [" .. tostring(k) .. "]")
        return
    end
    -- not valid yet: start/continue the grace window
    if not first_seen[k] then first_seen[k] = os.time(); return end
    if os.time() - first_seen[k] < GRACE_SECONDS then return end   -- still in grace
    if not can_kick then return end                     -- wait for the transition to settle
    kicked[k] = true                                    -- mark BEFORE kicking: never kick twice
    first_seen[k] = nil
    log("auth DENY (password mismatch) name='" ..
        tostring(raw):gsub(AUTH_DELIM .. ".*", AUTH_DELIM .. "<redacted>") ..
        "' [" .. tostring(k) .. "] -- kicking (grace expired)")
    kick_once(pc)
end

-- Run the gate if a join password is set OR we have a bans file to enforce.
-- An open server with bans still kicks banned ids; a server with neither does
-- not register the sweep at all.
--
-- ENFORCEMENT = the 1s sweep ONLY. SolarpunkAuth used to also RegisterHook
-- BP_MainPlayerController:BeginLoadData, but SolarpunkHost's net-id enforcer
-- already hooks that exact UFunction — two Lua hooks dispatching on the same
-- BP function during the join transition was a prime suspect for the
-- full-stack hook-dispatch AV on UE4SS-on-5.7, and the prior K2_PostLogin
-- hook is proven dead for remote IpNetDriver clients on this build. The
-- sweep evaluates every remote controller within 1s of appearing; the grace
-- window (4s) plus the SP.settled() transition gate mean a legitimate
-- client is never kicked early and an unauthorized one is kicked seconds
-- after its join settles.
if CONFIGURED_PASSWORD ~= "" or BANS_PATH then
    local ban_reload_ticks = 0
    SP.every("auth-sweep", 1000, 500, function()
        -- Refresh the ban list every ~5s so `ban`/`unban` take effect live. A
        -- newly-banned online player loses `verified` so the next evaluate re-checks.
        ban_reload_ticks = ban_reload_ticks + 1
        if ban_reload_ticks >= 5 then
            ban_reload_ticks = 0
            load_bans()
            if next(BANNED) ~= nil then
                for k in pairs(verified) do verified[k] = nil end
            end
        end
        local cs = SP.controllers()
        if not cs then return end
        local live = {}
        for _, c in ipairs(cs) do
            if c and c:IsValid() and not c:IsLocalPlayerController() then
                live[akey(c)] = true
                evaluate(c)
            end
        end
        -- Addresses are forgotten once the controller leaves so a reused
        -- address re-checks. (kicked == SP.kicked: this is also what clears
        -- the shared hands-off set once the dying controller is gone.)
        for k in pairs(kicked) do if not live[k] then kicked[k] = nil end end
        for k in pairs(verified) do if not live[k] then verified[k] = nil end end
        for k in pairs(first_seen) do if not live[k] then first_seen[k] = nil end end
    end)

    log("auth gate active (1s game-thread sweep, name-channel)")
    write_status(true, true, "gate_active")
end
