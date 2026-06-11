-- SolarpunkModKit v1: shared Lua surface that consumer mods write against.
--
-- Loaded first by SolarpunkServerRuntime. Populates _G.Solarpunk with the
-- namespaces documented in protocol/modkit-v1.md. Consumer mods preamble:
--
--   local Solarpunk = _G.Solarpunk
--   if not Solarpunk or not Solarpunk.ModKit or Solarpunk.ModKit.Version < 1 then
--       error("SolarpunkModKit v1 required")
--   end
--
-- File-IPC wire format matches SolarpunkRoster's pattern: ModKit writes
-- registration tables into <SolarpunkServerDir>\<name>.json; SolarpunkServer
-- reads them. Inbound queues (command-queue.json, chat-inbound.json) are
-- polled at 250ms. Chat broadcast is wired end-to-end (Solarpunk.Chat.Send /
-- Broadcast reach connected players via SolarpunkChat + the SolarpunkHud
-- overlay). The remaining gap is reverse command dispatch: mod-registered
-- slash commands have no SolarpunkServer consumer yet, so they don't fire
-- from RCON/HTTP. The full Lua API is live and the wire format is locked.

local MODKIT_VERSION = 1
local POLL_INTERVAL_MS = 250

-- ---------------------------------------------------------------------------
-- Path resolution. Mirrors SolarpunkRoster's locator so a managed install
-- finds InstanceRoot + SolarpunkServer dir regardless of cwd.
-- ---------------------------------------------------------------------------

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"

local function source_path()
    local src = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src
end

local SCRIPT_SOURCE = source_path()
local INSTANCE_ROOT = SCRIPT_SOURCE:match("^(.-)[/\\]Solarpunk[/\\]Binaries[/\\]Win64[/\\]ue4ss[/\\]Mods[/\\]SolarpunkModKit[/\\]Scripts[/\\]main%.lua$")
    or SCRIPT_SOURCE:match("^(.-)[/\\]ue4ss[/\\]Mods[/\\]SolarpunkModKit[/\\]Scripts[/\\]main%.lua$")
local LOG_DIR = (INSTANCE_ROOT and (INSTANCE_ROOT .. "\\UserDir\\Saved\\Logs\\Solarpunk")) or (APPDATA .. "\\Solarpunk")
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')

local SELF_LOG = LOG_DIR .. "\\SolarpunkModKit.log"
local function self_log(msg)
    local f = io.open(SELF_LOG, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkModKit] " .. tostring(msg))
end

self_log("SolarpunkModKit v" .. MODKIT_VERSION .. " loading")

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function get_mod_dir()
    local src = source_path()
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
        for _ = 1, 6 do
            table.insert(candidates, dir .. "\\SolarpunkServer")
            local parent = dir:match("^(.+)[\\/][^\\/]+$")
            if not parent or parent == dir then break end
            dir = parent
        end
    end
    local probe = io.popen and io.popen("cd") or nil
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
            self_log("SolarpunkServer dir: " .. c)
            return c
        end
    end
    return nil
end

local SOLARPUNK_DIR = find_solarpunkserver_dir()
local MODS_ROOT = nil
do
    local mod_dir = get_mod_dir()
    if mod_dir then MODS_ROOT = mod_dir:match("^(.+)[\\/][^\\/]+$") end
end

if not SOLARPUNK_DIR then
    self_log("WARN SolarpunkServer dir not located; file-IPC features will be disabled")
end

-- Sub-paths used by the file-IPC wire format.
local PATH_COMMANDS         = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\commands.json") or nil
local PATH_COMMAND_QUEUE    = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\command-queue.json") or nil
local DIR_COMMAND_REPLIES   = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\command-replies") or nil
local PATH_CHAT_OUTBOUND    = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\chat-outbound.json") or nil
local PATH_CHAT_INBOUND     = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\chat-inbound.json") or nil
local PATH_HTTP_ENDPOINTS   = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\http-endpoints.json") or nil
local DIR_HTTP_REPLIES      = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\http-replies") or nil
local PATH_ROSTER           = SOLARPUNK_DIR and (SOLARPUNK_DIR .. "\\roster.json") or nil

if SOLARPUNK_DIR then
    os.execute('mkdir "' .. DIR_COMMAND_REPLIES .. '" >NUL 2>NUL')
    os.execute('mkdir "' .. DIR_HTTP_REPLIES .. '" >NUL 2>NUL')
end

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder (decode goes through pcall-protected loadstring on
-- coerced literal tables — we only ever read JSON we ourselves write or that
-- SolarpunkServer writes following the same schema). Keeps the dep tree at zero.
-- ---------------------------------------------------------------------------

local json_encode
local function _encode_value(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "string" then
        return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"')
                       :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        return json_encode(v)
    end
    return "null"
end

json_encode = function(tbl)
    if type(tbl) ~= "table" then return _encode_value(tbl) end
    -- Detect array vs object: contiguous 1..n integer keys = array.
    local is_array = true
    local n = 0
    for k, _ in pairs(tbl) do
        n = n + 1
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then is_array = false; break end
    end
    if is_array and n > 0 then
        for i = 1, n do if tbl[i] == nil then is_array = false; break end end
    end
    if is_array then
        local parts = {}
        for i = 1, n do parts[i] = _encode_value(tbl[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    else
        local parts = {}
        for k, v in pairs(tbl) do
            parts[#parts + 1] = _encode_value(tostring(k)) .. ":" .. _encode_value(v)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
end

local function read_file(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

local function write_file_atomic(path, body)
    if not path then return false end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(body)
    f:close()
    -- Best-effort atomic rename; on Windows the rename succeeds only if the
    -- destination doesn't exist, so delete first. SolarpunkServer reads on a
    -- FileSystemWatcher so a brief gap is harmless.
    os.remove(path)
    return os.rename(tmp, path)
end

-- Tiny JSON value extractor — purpose-built for the schemas in modkit-v1.md.
-- Not a general parser. Reads { "key": "value", "key2": 123, "key3": [...] }
-- from a known-shape file. Returns table.
local function parse_object_list(body, root_key)
    if not body then return {} end
    -- Strip whitespace, find root_key array
    local arr = body:match('"' .. root_key .. '"%s*:%s*(%b[])')
    if not arr then return {} end
    local out = {}
    -- Iterate over top-level {…} objects inside [...].
    local depth, start = 0, nil
    for i = 1, #arr do
        local c = arr:sub(i, i)
        if c == "{" then
            depth = depth + 1
            if depth == 1 then start = i end
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 and start then
                out[#out + 1] = arr:sub(start, i)
                start = nil
            end
        end
    end
    return out
end

local function parse_value(obj_str, key)
    -- string (no escape handling — wire format we control writes only printable ASCII)
    local s = obj_str:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if s then return s end
    -- number
    local n = obj_str:match('"' .. key .. '"%s*:%s*(%-?%d+%.?%d*)')
    if n then return tonumber(n) end
    -- boolean
    local b = obj_str:match('"' .. key .. '"%s*:%s*(true)') or obj_str:match('"' .. key .. '"%s*:%s*(false)')
    if b then return b == "true" end
    return nil
end

local function parse_string_array(obj_str, key)
    local arr = obj_str:match('"' .. key .. '"%s*:%s*(%b[])')
    if not arr then return {} end
    local out = {}
    for v in arr:gmatch('"([^"]*)"') do out[#out + 1] = v end
    return out
end

-- ---------------------------------------------------------------------------
-- Game-thread runner — same shape SolarpunkRoster uses.
-- ---------------------------------------------------------------------------

local pending_gt_callbacks = {}
local function run_on_game_thread(fn)
    if type(ExecuteInGameThread) ~= "function" then
        return pcall(fn)
    end
    local key = tostring(os.clock()) .. ":" .. tostring(math.random(1000000))
    pending_gt_callbacks[key] = fn
    local ok = pcall(function()
        ExecuteInGameThread(function()
            local cb = pending_gt_callbacks[key]
            pending_gt_callbacks[key] = nil
            if cb then pcall(cb) end
        end)
    end)
    if not ok then
        pending_gt_callbacks[key] = nil
        return pcall(fn)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Namespace tables.
-- ---------------------------------------------------------------------------

local Solarpunk = _G.Solarpunk or {}

Solarpunk.ModKit = {
    Version = MODKIT_VERSION,
    BuildTag = "v1.0",
}

Solarpunk.Paths = {
    InstanceRoot    = INSTANCE_ROOT,
    SolarpunkServerDir = SOLARPUNK_DIR,
    LogDir          = LOG_DIR,
    ModsRoot        = MODS_ROOT,
}

-- ----- Solarpunk.Log -----
Solarpunk.Log = {}
function Solarpunk.Log.For(mod_name)
    local name = tostring(mod_name or "Unknown")
    local path = LOG_DIR .. "\\" .. name .. ".log"
    return function(msg)
        local f = io.open(path, "a")
        if f then
            f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
            f:close()
        end
        print("[" .. name .. "] " .. tostring(msg))
    end
end

-- ----- Solarpunk.GameThread -----
Solarpunk.GameThread = {
    Run = run_on_game_thread,
    IsOnGameThread = function() return false end,  -- UE4SS doesn't expose a clean check; conservative default
}

-- ----- Solarpunk.Commands -----
local command_registry = {}      -- name -> { handler, opts }
local commands_dirty = true

Solarpunk.Commands = {}

function Solarpunk.Commands.Register(name, handler, opts)
    if type(name) ~= "string" or name == "" then
        error("Solarpunk.Commands.Register: name must be non-empty string")
    end
    if type(handler) ~= "function" then
        error("Solarpunk.Commands.Register: handler must be function")
    end
    opts = opts or {}
    command_registry[name:lower()] = {
        handler    = handler,
        admin_only = opts.admin_only and true or false,
        help       = tostring(opts.help or ""),
        usage      = tostring(opts.usage or ("/" .. name)),
    }
    commands_dirty = true
    self_log("command registered: /" .. name)
end

function Solarpunk.Commands.Unregister(name)
    if type(name) ~= "string" then return end
    command_registry[name:lower()] = nil
    commands_dirty = true
end

function Solarpunk.Commands.List()
    local out = {}
    for n, c in pairs(command_registry) do
        out[#out + 1] = { name = n, help = c.help, usage = c.usage, admin_only = c.admin_only }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function Solarpunk.Commands.Dispatch(name, ctx)
    local entry = command_registry[(name or ""):lower()]
    if not entry then return nil, "unknown_command" end
    if entry.admin_only and not (ctx and ctx.caller and ctx.caller.is_admin) then
        return nil, "admin_required"
    end
    local ok, result = pcall(entry.handler, ctx or { args = {}, raw = "", caller = {} })
    if not ok then
        self_log("command /" .. name .. " errored: " .. tostring(result))
        return nil, "handler_error"
    end
    return result
end

local function flush_commands_file()
    if not commands_dirty or not PATH_COMMANDS then return end
    local body = {
        version = MODKIT_VERSION,
        updated = os.time(),
        commands = Solarpunk.Commands.List(),
    }
    if write_file_atomic(PATH_COMMANDS, json_encode(body)) then
        commands_dirty = false
    end
end

-- ----- Solarpunk.Players (reads roster.json published by SolarpunkRoster) -----
-- Producer schema (SolarpunkRoster/Scripts/main.lua write_roster()):
--   { unix_ms, players: [ { SolarpunkUserId, DisplayName, ConnectedAtUnixMs,
--                           LastPacketUnixMs, PingMs } ] }
-- SolarpunkUserId is the composite identity assembled by Solarpunk.dll —
-- either "<steam64>_<charHash8>" for client characters or
-- "server-<hash>" for the server-side host identity. Consumer mods
-- get a normalized table that surfaces both the raw id and a parsed
-- (steam, character) tuple, plus convenient lookup indexes.
local players_cache = { list = {}, by_name = {}, by_id = {}, by_steam = {} }

local function refresh_players_cache()
    local body = read_file(PATH_ROSTER)
    if not body then return end
    local entries = parse_object_list(body, "players")
    local list, by_name, by_id, by_steam = {}, {}, {}, {}
    for _, obj in ipairs(entries) do
        local id   = parse_value(obj, "SolarpunkUserId") or ""
        local name = parse_value(obj, "DisplayName") or ""
        local steam_id, character_id = id:match("^(%d+)_([%x]+)$")
        if not steam_id then steam_id = id:match("^(%d+)$") end
        local p = {
            id                   = id,
            name                 = name,
            steam_id             = steam_id or "",
            character_id         = character_id or "",
            joined_unix_ms       = tonumber(parse_value(obj, "ConnectedAtUnixMs")) or 0,
            last_seen_unix_ms    = tonumber(parse_value(obj, "LastPacketUnixMs")) or 0,
            ping_ms              = tonumber(parse_value(obj, "PingMs")) or 0,
        }
        list[#list + 1] = p
        if name ~= "" then by_name[name:lower()] = p end
        if id ~= "" then by_id[id] = p end
        if p.steam_id ~= "" then by_steam[p.steam_id] = p end
    end
    players_cache.list = list
    players_cache.by_name = by_name
    players_cache.by_id = by_id
    players_cache.by_steam = by_steam
end

Solarpunk.Players = {}
function Solarpunk.Players.List()           refresh_players_cache(); return players_cache.list end
function Solarpunk.Players.GetByName(name)  refresh_players_cache(); return players_cache.by_name[(name or ""):lower()] end
function Solarpunk.Players.GetById(id)      refresh_players_cache(); return players_cache.by_id[id or ""] end
function Solarpunk.Players.GetBySteamId(id) refresh_players_cache(); return players_cache.by_steam[id or ""] end
function Solarpunk.Players.Count()          refresh_players_cache(); return #players_cache.list end

-- ----- Solarpunk.Events -----
local event_handlers = { join = {}, leave = {}, tick = {}, ready = {} }
local event_handle_counter = 0
local last_seen_players = {}       -- SolarpunkUserId -> true
local server_ready_fired = false

local function next_handle() event_handle_counter = event_handle_counter + 1; return event_handle_counter end

Solarpunk.Events = {}

function Solarpunk.Events.OnPlayerJoin(cb)
    local h = next_handle(); event_handlers.join[h] = cb; return h
end
function Solarpunk.Events.OnPlayerLeave(cb)
    local h = next_handle(); event_handlers.leave[h] = cb; return h
end
function Solarpunk.Events.OnTick(interval_ms, cb)
    local h = next_handle()
    event_handlers.tick[h] = { interval_ms = tonumber(interval_ms) or 1000, cb = cb, last = 0 }
    return h
end
function Solarpunk.Events.OnServerReady(cb)
    if server_ready_fired then pcall(cb); return -1 end
    local h = next_handle(); event_handlers.ready[h] = cb; return h
end
function Solarpunk.Events.Unsubscribe(h)
    for _, bucket in pairs(event_handlers) do bucket[h] = nil end
end

local function fire_player_diffs()
    refresh_players_cache()
    local current = {}
    for _, p in ipairs(players_cache.list) do
        if p.id ~= "" then current[p.id] = p end
    end
    for id, p in pairs(current) do
        if not last_seen_players[id] then
            for _, cb in pairs(event_handlers.join) do pcall(cb, p) end
        end
    end
    for id, prev in pairs(last_seen_players) do
        if not current[id] then
            for _, cb in pairs(event_handlers.leave) do pcall(cb, prev) end
        end
    end
    last_seen_players = current
end

local function fire_ready_if_first_player()
    if server_ready_fired then return end
    if type(UEHelpers) == "table" and UEHelpers.GetGameStateBase then
        local ok, gs = pcall(UEHelpers.GetGameStateBase)
        if ok and gs and gs:IsValid() then
            server_ready_fired = true
            for _, cb in pairs(event_handlers.ready) do pcall(cb) end
            event_handlers.ready = {}
        end
    end
end

-- ----- Solarpunk.Chat (outbound writes; inbound delivery wired in pillar 3) -----
Solarpunk.Chat = {}
function Solarpunk.Chat.Send(target, msg, opts)
    if not PATH_CHAT_OUTBOUND then return false end
    opts = opts or {}
    local target_str
    if type(target) == "string" then target_str = target
    elseif type(target) == "table" and target.id and target.id ~= "" then target_str = target.id
    elseif type(target) == "table" and target.steam_id and target.steam_id ~= "" then target_str = target.steam_id
    else target_str = "all" end
    local entry = {
        ts          = os.time(),
        target      = target_str,
        msg         = tostring(msg or ""),
        channel     = opts.channel or "system",
        color       = opts.color,
    }
    -- Append-mode: read existing, append, rewrite. Single writer (this Lua state).
    local body = read_file(PATH_CHAT_OUTBOUND) or '{"version":1,"messages":[]}'
    local prefix, suffix = body:match('^(.*)"messages"%s*:%s*%[(.*)%]%s*}%s*$')
    if not prefix then
        body = '{"version":1,"messages":[]}'
        prefix, suffix = body:match('^(.*)"messages"%s*:%s*%[(.*)%]%s*}%s*$')
    end
    local new_entry = json_encode(entry)
    local rebuilt
    if suffix and suffix:match('%S') then
        rebuilt = prefix .. '"messages":[' .. suffix .. ',' .. new_entry .. ']}'
    else
        rebuilt = prefix .. '"messages":[' .. new_entry .. ']}'
    end
    return write_file_atomic(PATH_CHAT_OUTBOUND, rebuilt)
end
function Solarpunk.Chat.Broadcast(msg, opts) return Solarpunk.Chat.Send("all", msg, opts) end
function Solarpunk.Chat.OnMessage(cb)
    local h = next_handle()
    event_handlers.tick[h] = nil  -- chat-inbound polling lives in the main loop, no separate tick
    -- Store under a dedicated bucket
    event_handlers.chat = event_handlers.chat or {}
    event_handlers.chat[h] = cb
    return h
end

-- ----- Solarpunk.Http (registration only; SolarpunkServer-side reader lands later) -----
local http_registry = {}     -- path -> { handler, admin_only }
local http_dirty = true

Solarpunk.Http = {}
function Solarpunk.Http.RegisterEndpoint(path, handler, opts)
    if type(path) ~= "string" or not path:match("^/mod/") then
        error("Solarpunk.Http.RegisterEndpoint: path must start with /mod/")
    end
    opts = opts or {}
    http_registry[path] = {
        handler    = handler,
        admin_only = (opts.admin_only ~= false),
    }
    http_dirty = true
    self_log("http endpoint registered: " .. path)
end

local function flush_http_endpoints()
    if not http_dirty or not PATH_HTTP_ENDPOINTS then return end
    local list = {}
    for p, e in pairs(http_registry) do
        list[#list + 1] = { path = p, admin_only = e.admin_only }
    end
    local body = { version = MODKIT_VERSION, updated = os.time(), endpoints = list }
    if write_file_atomic(PATH_HTTP_ENDPOINTS, json_encode(body)) then
        http_dirty = false
    end
end

-- ---------------------------------------------------------------------------
-- Command-queue poll: drains SolarpunkServer's inbound command queue, dispatches
-- handlers, writes per-id reply files. Wire format documented in
-- protocol/modkit-v1.md.
-- ---------------------------------------------------------------------------

local function drain_command_queue()
    if not PATH_COMMAND_QUEUE then return end
    local body = read_file(PATH_COMMAND_QUEUE)
    if not body or body == "" then return end
    local entries = parse_object_list(body, "queue")
    if #entries == 0 then return end

    for _, obj in ipairs(entries) do
        local id   = parse_value(obj, "id") or ""
        local name = parse_value(obj, "name") or ""
        local raw  = parse_value(obj, "raw") or ""
        local args = parse_string_array(obj, "args")
        local caller_obj = obj:match('"caller"%s*:%s*(%b{})')
        local caller = {
            kind     = caller_obj and parse_value(caller_obj, "kind") or "unknown",
            name     = caller_obj and parse_value(caller_obj, "name") or nil,
            steam_id = caller_obj and parse_value(caller_obj, "steam_id") or nil,
            is_admin = caller_obj and parse_value(caller_obj, "is_admin") == true or false,
        }
        local reply, err = Solarpunk.Commands.Dispatch(name, { args = args, raw = raw, caller = caller })
        local reply_body = json_encode({
            id    = id,
            reply = reply or "",
            error = err,
            ts    = os.time(),
        })
        if id ~= "" then
            write_file_atomic(DIR_COMMAND_REPLIES .. "\\" .. id .. ".json", reply_body)
        end
    end

    -- Mark the queue drained by replacing with an empty queue.
    write_file_atomic(PATH_COMMAND_QUEUE, '{"version":1,"queue":[]}')
end

-- ---------------------------------------------------------------------------
-- Chat-inbound poll (no-op consumer side until pillar 3 wires SolarpunkServer
-- to actually publish chat-inbound.json; structure already drained here so
-- when it lands, this loop dispatches without code changes).
-- ---------------------------------------------------------------------------

local function drain_chat_inbound()
    if not PATH_CHAT_INBOUND then return end
    -- Only consume the inbound queue when a consumer mod actually registered
    -- a chat handler. SolarpunkChat (the in-game ClientMessage fanout) is the
    -- production drainer of chat-inbound.json; unconditionally draining here
    -- raced it and ATE inbound messages before they reached players.
    if not (event_handlers.chat and next(event_handlers.chat) ~= nil) then return end
    local body = read_file(PATH_CHAT_INBOUND)
    if not body or body == "" then return end
    local entries = parse_object_list(body, "messages")
    if #entries == 0 then return end
    if event_handlers.chat then
        for _, obj in ipairs(entries) do
            local msg = {
                sender  = parse_value(obj, "sender") or "",
                target  = parse_value(obj, "target") or "",
                channel = parse_value(obj, "channel") or "player",
                msg     = parse_value(obj, "msg") or "",
            }
            for _, cb in pairs(event_handlers.chat) do pcall(cb, msg) end
        end
    end
    write_file_atomic(PATH_CHAT_INBOUND, '{"version":1,"messages":[]}')
end

-- ---------------------------------------------------------------------------
-- Main poll loop. UE4SS LoopAsync — single shared loop for all polling +
-- event dispatch, runs every POLL_INTERVAL_MS.
-- ---------------------------------------------------------------------------

local tick_clock_ms = 0
local function poll_tick()
    tick_clock_ms = tick_clock_ms + POLL_INTERVAL_MS
    flush_commands_file()
    flush_http_endpoints()
    drain_command_queue()
    drain_chat_inbound()
    -- player diffs read+parse roster.json — throttle to 1s (consumer-mod
    -- join/leave latency, not a hot path).
    if tick_clock_ms % 1000 < POLL_INTERVAL_MS then
        fire_player_diffs()
        fire_ready_if_first_player()
    end
    -- User OnTick handlers
    for _, t in pairs(event_handlers.tick) do
        if type(t) == "table" and t.cb then
            t.last = (t.last or 0) + POLL_INTERVAL_MS
            if t.last >= t.interval_ms then
                t.last = 0
                local ok, stop = pcall(t.cb)
                if ok and stop == true then
                    -- handler asked to stop — find + remove
                    for h, v in pairs(event_handlers.tick) do
                        if v == t then event_handlers.tick[h] = nil; break end
                    end
                end
            end
        end
    end
    return false  -- continue looping
end

-- Preferred: run on SolarpunkServerRuntime's shared game-thread scheduler
-- (see the STABILITY CONTRACT there — no mod-owned LoopAsync, all work
-- serialized on the game thread). LoopAsync stays as a dev/standalone
-- fallback only.
if _G.SolarpunkSP and type(_G.SolarpunkSP.every) == "function" then
    _G.SolarpunkSP.every("modkit-poll", POLL_INTERVAL_MS, 125, poll_tick)
    self_log("poll loop on shared game-thread scheduler (" .. POLL_INTERVAL_MS .. "ms)")
elseif type(LoopAsync) == "function" then
    LoopAsync(POLL_INTERVAL_MS, poll_tick)
elseif type(require) == "function" then
    local ok, loop = pcall(require, "LoopAsync")
    if ok and type(loop) == "function" then
        loop(POLL_INTERVAL_MS, poll_tick)
    else
        self_log("WARN LoopAsync unavailable; poll loop disabled (Commands/Chat/Http will not dispatch)")
    end
else
    self_log("WARN no async loop available")
end

-- ---------------------------------------------------------------------------
-- Publish the namespace. After this point, any later mod can grab _G.Solarpunk.
-- ---------------------------------------------------------------------------

_G.Solarpunk = Solarpunk
self_log("SolarpunkModKit v" .. MODKIT_VERSION .. " ready")
