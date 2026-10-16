-- SolarpunkServerRuntime: load the Solarpunk server mod stack from one UE4SS
-- Lua mod, in a fixed order, and publish a runtime-status file the .NET
-- supervisor (SolarpunkServer) can poll.
--
-- Port of Beacon's BeaconServerRuntime. UE4SS starts one async event loop per
-- enabled Lua mod; production enables ONLY this mod in mods.txt and the
-- feature modules live as sibling folders loaded via dofile.
--
-- Load order (security/boot critical first):
--   SolarpunkHost   transport swap -> world select/persist -> HostGame ->
--                   per-player net-id save/load keying. THE host pipeline.
--   SolarpunkAuth   password gate (K2_PostLogin) + .solarpunk-auth-status
--   SolarpunkRoster GameState scan -> roster.json for A2S/HTTP players
--   SolarpunkChat   chat-inbound fanout + MOTD + join/leave outbound
--
-- Status files (all in the located SolarpunkServer\ dir):
--   .solarpunk-auth-status     written by SolarpunkAuth (and pre-invalidated
--                              here, ready=0 reason=runtime_init, so a stale
--                              ready=1 from a previous process can never be
--                              trusted by the watchdog — Beacon round-5 fix)
--   .solarpunk-runtime-status  written here. key=value lines:
--                              ready=0|1, mods=<csv loaded>, failed=<csv>,
--                              updated=<unix>, reason=<short string>
--                              ready=1 means every module dofile'd OK.
--                              (Host "hosting=1 world=<name>" lives in
--                              .solarpunk-host-status, written by SolarpunkHost.)

local APPDATA = os.getenv("APPDATA") or "C:\\Users\\Default\\AppData\\Roaming"
local function source_path()
    local src = tostring((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src
end

local SCRIPT_SOURCE = source_path()
local LOG_DIR = APPDATA .. "\\Solarpunk"
os.execute('mkdir "' .. LOG_DIR .. '" >NUL 2>NUL')
local LOG_FILE = LOG_DIR .. "\\SolarpunkServerRuntime.log"

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\r\n")
        f:close()
    end
    print("[SolarpunkServerRuntime] " .. tostring(msg) .. "\n")
end

local function dirname(path)
    return path and path:match("^(.+)[/\\][^/\\]+$") or nil
end

local script_path = SCRIPT_SOURCE
local scripts_dir = dirname(script_path)
local runtime_dir = dirname(scripts_dir)
local mods_root = dirname(runtime_dir)

local server_mods = {
    "SolarpunkModKit",   -- consumer-mod API surface (_G.Solarpunk); load first so any consumer mod has it
    "SolarpunkHost",
    "SolarpunkAuth",
    "SolarpunkRoster",
    "SolarpunkChat",
    "SolarpunkNoPhantomHost",   -- hide the listen-host's server-<hex> pawn + force remote display names
}

log("starting runtime script=" .. tostring(script_path) .. " mods_root=" .. tostring(mods_root))

if not mods_root then
    error("SolarpunkServerRuntime could not resolve Mods root from " .. tostring(script_path))
end

-- ---------------------------------------------------------------------------
-- Locate the SolarpunkServer dir (sibling of the game install root) so we can
-- (a) pre-invalidate .solarpunk-auth-status and (b) write runtime status.
-- ---------------------------------------------------------------------------

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function find_solarpunkserver_dir()
    local candidates = {}
    local seen = {}
    local function add(dir)
        if dir and not seen[dir] then
            seen[dir] = true
            table.insert(candidates, dir)
        end
    end
    local dir = mods_root
    for _ = 1, 8 do
        add(dir)
        local parent = dir:match("^(.+)[\\/][^\\/]+$")
        if not parent or parent == dir then break end
        dir = parent
    end
    local probe = io.popen("cd")
    if probe then
        local cwd = probe:read("*l")
        probe:close()
        if cwd and #cwd > 0 then
            local d = cwd
            for _ = 1, 8 do
                add(d)
                local parent = d:match("^(.+)\\[^\\]+$")
                if not parent or parent == d then break end
                d = parent
            end
        end
    end
    for _, c in ipairs(candidates) do
        if file_exists(c .. "\\SolarpunkServer\\appsettings.json") then
            return c .. "\\SolarpunkServer"
        end
    end
    return nil
end

local SP_DIR = find_solarpunkserver_dir()
log("SolarpunkServer dir: " .. tostring(SP_DIR))

local function write_kv_atomic(path, lines)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    for attempt = 1, 5 do
        os.remove(path)
        local ok = os.rename(tmp, path)
        if ok then return true end
        if attempt < 5 then os.execute('ping -n 1 -w 100 127.0.0.1 >NUL 2>NUL') end
    end
    os.remove(tmp)
    return false
end

-- Stale-status invalidation BEFORE any module loads: overwrite (not delete)
-- .solarpunk-auth-status with a current-boot ready=0 marker so the watchdog
-- can never trust a previous process's ready=1 if SolarpunkAuth subsequently
-- fails to load. Fatal on failure (fail-closed > silently-open).
if SP_DIR then
    local ok = write_kv_atomic(SP_DIR .. "\\.solarpunk-auth-status", {
        "ready=0", "passwordConfigured=0",
        "updated=" .. tostring(os.time()), "reason=runtime_init",
    })
    if ok then
        log(".solarpunk-auth-status overwritten with ready=0 (runtime_init)")
    else
        error("SolarpunkServerRuntime: could not invalidate previous-process auth status; aborting to force fail-closed")
    end
    write_kv_atomic(SP_DIR .. "\\.solarpunk-runtime-status", {
        "ready=0", "mods=", "failed=",
        "updated=" .. tostring(os.time()), "reason=loading",
    })
else
    log("WARN: SolarpunkServer dir not located — status files disabled (standalone/dev layout)")
end

-- ---------------------------------------------------------------------------
-- Shared game-thread scheduler + cross-mod state (_G.SolarpunkSP).
--
-- STABILITY CONTRACT (the 2026-06-10 full-stack crash fix). The unhardened
-- stack ran 7 independent LoopAsync loops: every callback executed Lua on
-- UE4SS's async thread (file I/O, JSON parsing, FindAllOf/FindFirstOf and
-- even RegisterHook calls off-thread) CONCURRENTLY with game-thread hook
-- callbacks in the same lua_State. On UE4SS-on-UE5.7 (build 23659698) that
-- raced ~25s-2min after a client join into varied CRT AbortHandler / hook-
-- dispatch AV crashes. The fix:
--   * ONE LoopAsync trampoline (250ms) whose only async-thread work is
--     queueing ExecuteInGameThread(runner). Every mod registers periodic
--     tasks here instead of owning a LoopAsync; ALL real work (native
--     object access, file I/O, RegisterHook) is serialized on the game
--     thread.
--   * ONE BeginLoadData hook (owned by SolarpunkHost — net-id needs it).
--     SolarpunkAuth no longer registers its own (its 1s sweep enforces).
--   * SP.transition[addr]: stamped by the hook on every BeginLoadData fire;
--     SP.settled(addr) is false for SETTLE_S after the last fire. Roster/
--     Chat/Auth never touch (position reads, ClientMessage, kicks) a
--     controller mid-join-transition — the AV window UE4SS 5.7 is fragile in.
--   * SP.kicked[addr]: marked by SolarpunkAuth; every mod skips a kicked
--     (dying) controller entirely — never re-touch a PC after kick.
--   * SP.controllers(): the player-controller list, shared by all tasks in a
--     tick and KEPT between ticks (see "Kept objects" below).
-- ---------------------------------------------------------------------------

local SP = {}
_G.SolarpunkSP = SP

local TICK_MS = 250
local SETTLE_S = 3

SP.tick = 0
SP.transition = {}   -- [controller addr] = os.time() of last BeginLoadData fire
SP.kicked = {}       -- [controller addr] = true once auth kicked it (dying; hands off)

function SP.settled(addr)
    local t = SP.transition[addr]
    return (not t) or (os.time() - t >= SETTLE_S)
end

-- ---------------------------------------------------------------------------
-- Kept objects instead of whole-list searches (2026-10-16).
--
-- FindAllOf / FindFirstOf walk every object the engine has (tens of ms each on
-- a busy host), on the game thread. The host runs a fixed 30 fps step, so a
-- stalled frame is world time that never happens: one controller search plus
-- one GameState search every 250 ms held Solarpunk worlds at 95-96.5% of real
-- time with nobody on (the Grounded 2 / Bellwright bug class).
--
-- Found objects are kept while IsValid() (UE4SS checks the live object map and
-- the unreachable flag, so a freed object reads false) and still of the class
-- they had when found (an address can be reused; FindAllOf/FindFirstOf also
-- return subclasses, so the object's own class is recorded, not the searched
-- name). They are searched again:
--   * after a map load (LoadMap / InitGameState post hooks bump map_gen), or
--     when a kept object is gone (a travel's garbage collection),
--   * for the controller list: when the GameState's PlayerArray length
--     changes (a join or a leave) or a BeginLoadData transition is newer than
--     the last search,
--   * and as a backstop: the controller list every RESEARCH_S seconds, a kept
--     single object (GameState, World, GameInstance, SaveManager) every
--     KEPT_RESEARCH_S seconds.
-- A class that is not there (the menu has no GameState) is retried every
-- MISS_RETRY_TICKS ticks, not every tick.
-- ---------------------------------------------------------------------------
local RESEARCH_S = 30
local KEPT_RESEARCH_S = 120
local MISS_RETRY_TICKS = 8          -- 2 s
local CTRL_CLASS = "BP_MainPlayerController_C"
local GS_CLASS = "BP_SkyGameGameState_C"

SP.scan = { walks = 0, ctrl = 0, kept = 0, why = {} }
local function note_search(kind, why)
    SP.scan.walks = SP.scan.walks + 1
    SP.scan[kind] = SP.scan[kind] + 1
    SP.scan.why[why] = (SP.scan.why[why] or 0) + 1
end

local map_gen = 0
local function bump_map_gen() map_gen = map_gen + 1 end
pcall(function() RegisterLoadMapPostHook(bump_map_gen) end)
pcall(function() RegisterInitGameStatePostHook(bump_map_gen) end)
function SP.map_gen() return map_gen end

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function class_of(o)
    local ok, cls = pcall(function() return o:GetClass():GetFName():ToString() end)
    if ok and type(cls) == "string" then return cls end
    return nil
end
-- IsValid + still the class it had when it was found. Touches nothing else.
local function alive(o, cls)
    return cls ~= nil and valid(o) and class_of(o) == cls
end

-- The first object of a class (FindFirstOf semantics), kept between calls.
local kept = {}
function SP.kept(cname)
    local e = kept[cname]
    if not e then e = { gen = -1, at = 0, tick = -1000000 }; kept[cname] = e end
    local now = os.time()
    if e.gen == map_gen and now - e.at < KEPT_RESEARCH_S then
        if e.obj ~= nil and alive(e.obj, e.cls) then return e.obj end
        if e.obj == nil and SP.tick - e.tick < MISS_RETRY_TICKS then return nil end
    end
    local why = (e.gen ~= map_gen) and "map" or ((now - e.at >= KEPT_RESEARCH_S) and "age" or (e.obj == nil and "miss" or "gone"))
    note_search("kept", why)
    local o = nil
    pcall(function() o = FindFirstOf(cname) end)
    local cls = valid(o) and class_of(o) or nil
    if cls == nil then o = nil end
    e.obj, e.cls, e.gen, e.at, e.tick = o, cls, map_gen, now, SP.tick
    return o
end

-- Players in the GameState's PlayerArray (nil while there is no GameState).
function SP.player_count()
    local gs = SP.kept(GS_CLASS)
    if gs == nil then return nil end
    local n = nil
    pcall(function() n = gs.PlayerArray:GetArrayNum() end)
    return n
end

local function newest_transition()
    local m = 0
    for _, t in pairs(SP.transition) do
        if t > m then m = t end
    end
    return m
end

local ctrl = { list = nil, cls = nil, gen = -1, at = 0, tick = -1000000, players = nil, stamp = 0 }
local function ctrl_search_reason(now)
    if ctrl.list == nil or ctrl.gen ~= map_gen then return "map" end
    if now - ctrl.at >= RESEARCH_S then return "age" end
    if #ctrl.list == 0 then
        return (SP.tick - ctrl.tick >= MISS_RETRY_TICKS) and "miss" or nil
    end
    for i, c in ipairs(ctrl.list) do
        if not alive(c, ctrl.cls[i]) then return "gone" end
    end
    if SP.player_count() ~= ctrl.players then return "players" end
    if newest_transition() > ctrl.stamp then return "transition" end
    return nil
end

local ctrl_cache_tick, ctrl_cache = -1, nil
function SP.controllers()
    if ctrl_cache_tick == SP.tick then return ctrl_cache end
    ctrl_cache_tick = SP.tick
    local now = os.time()
    local why = ctrl_search_reason(now)
    if why then
        note_search("ctrl", why)
        local found = nil
        pcall(function() found = FindAllOf(CTRL_CLASS) end)
        local list, clss = {}, {}
        if found then
            for _, c in ipairs(found) do
                local cls = valid(c) and class_of(c) or nil
                if cls then list[#list + 1] = c; clss[#clss + 1] = cls end
            end
        end
        ctrl.list, ctrl.cls, ctrl.gen, ctrl.at, ctrl.tick = list, clss, map_gen, now, SP.tick
        ctrl.players = SP.player_count()
        ctrl.stamp = newest_transition()
    end
    ctrl_cache = (#ctrl.list > 0) and ctrl.list or nil
    return ctrl_cache
end

local sched_tasks = {}
-- Register a periodic game-thread task. period/offset in ms (rounded to the
-- 250ms tick grid; offsets stagger tasks so the 1s sweeps don't all land in
-- the same engine-tick slice).
function SP.every(name, period_ms, offset_ms, fn)
    local period = math.max(1, math.floor((period_ms or TICK_MS) / TICK_MS))
    table.insert(sched_tasks, {
        name = tostring(name),
        period = period,
        offset = math.floor((offset_ms or 0) / TICK_MS) % period,
        fn = fn,
        errs = 0,
    })
end

local function sched_runner()
    SP.tick = SP.tick + 1
    -- prune stale transition stamps (dead controller addrs) so the table
    -- can't grow unbounded; an old stamp is "settled" anyway, so pruning is
    -- never behavior-changing.
    if SP.tick % 240 == 0 then
        local now = os.time()
        for k, t in pairs(SP.transition) do
            if now - t > 60 then SP.transition[k] = nil end
        end
    end
    for _, t in ipairs(sched_tasks) do
        if (SP.tick % t.period) == t.offset then
            local ok, err = pcall(t.fn)
            if not ok then
                t.errs = t.errs + 1
                if t.errs <= 5 or t.errs % 100 == 0 then
                    log("sched task '" .. t.name .. "' error #" .. t.errs .. ": " .. tostring(err))
                end
            end
        end
    end
end

-- The ONLY async-thread Lua in the whole stack: queue the runner.
LoopAsync(TICK_MS, function()
    ExecuteInGameThread(sched_runner)
    return false
end)
log("game-thread scheduler started (tick " .. TICK_MS .. "ms)")

-- ---------------------------------------------------------------------------
-- Load modules in order. A module failure logs + records but does NOT abort
-- the stack (the host pipeline must come up even if a secondary module
-- faults) — EXCEPT SolarpunkHost itself: without the host there is no
-- server, so that failure is fatal.
-- ---------------------------------------------------------------------------

local loaded = {}
local failed = {}

for _, mod_name in ipairs(server_mods) do
    local path = mods_root .. "\\" .. mod_name .. "\\Scripts\\main.lua"
    log("loading " .. mod_name .. " from " .. path)
    local ok, err = pcall(dofile, path)
    if ok then
        table.insert(loaded, mod_name)
        log("loaded " .. mod_name)
    else
        table.insert(failed, mod_name)
        log("FAILED " .. mod_name .. ": " .. tostring(err))
        if mod_name == "SolarpunkHost" then
            if SP_DIR then
                write_kv_atomic(SP_DIR .. "\\.solarpunk-runtime-status", {
                    "ready=0",
                    "mods=" .. table.concat(loaded, ","),
                    "failed=" .. table.concat(failed, ","),
                    "updated=" .. tostring(os.time()),
                    "reason=host_load_failed",
                })
            end
            error(err)
        end
    end
end

local function write_runtime_status(reason)
    if not SP_DIR then return end
    write_kv_atomic(SP_DIR .. "\\.solarpunk-runtime-status", {
        "ready=" .. (#failed == 0 and "1" or "0"),
        "mods=" .. table.concat(loaded, ","),
        "failed=" .. table.concat(failed, ","),
        "updated=" .. tostring(os.time()),
        "reason=" .. tostring(reason or (#failed == 0 and "all_modules_loaded" or "partial_load")),
    })
end

write_runtime_status(#failed == 0 and "all_modules_loaded" or "partial_load")

SP.every("runtime-heartbeat", 30000, 1000, function()
    write_runtime_status(#failed == 0 and "all_modules_loaded" or "partial_load")
end)

-- Object searches made through SP.controllers / SP.kept, every 5 minutes.
local scan_ticks_at = 0
SP.every("runtime-scan-stats", 300000, 1500, function()
    local why = {}
    for k, v in pairs(SP.scan.why) do why[#why + 1] = k .. "=" .. v end
    table.sort(why)
    log("scan stats: ticks=" .. (SP.tick - scan_ticks_at) .. " searches=" .. SP.scan.walks ..
        " controllers=" .. SP.scan.ctrl .. " kept=" .. SP.scan.kept ..
        " why=" .. table.concat(why, ",") .. " map_gen=" .. map_gen)
    scan_ticks_at = SP.tick
    SP.scan = { walks = 0, ctrl = 0, kept = 0, why = {} }
end)

log("server module load complete: loaded=" .. table.concat(loaded, ",") ..
    (#failed > 0 and (" failed=" .. table.concat(failed, ",")) or ""))
