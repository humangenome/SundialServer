local source = assert(io.open(arg[1] or 'server-mods/SolarpunkServerRuntime/Scripts/main.lua', 'r')):read('*a')
local files, timers, modules = {}, {}, {}
local now, game_thread, queries = 100, false, 0
local env
local function open(path, mode)
    if mode == 'rb' then
        if path == 'C:\\lab\\SolarpunkServer\\appsettings.json' then
            return { close = function() end }
        end
        return nil
    end
    local body = mode == 'a' and (files[path] or '') or ''
    return {
        write = function(_, ...) body = body .. table.concat({...}) end,
        close = function() files[path] = body end,
    }
end
env = setmetatable({
    debug = { getinfo = function() return { source = '@C:\\lab\\game\\ue4ss\\Mods\\SolarpunkServerRuntime\\Scripts\\main.lua' } end },
    os = {
        getenv = function() return 'C:\\lab\\Roaming' end,
        time = function() return now end,
        date = function() return 'time' end,
        execute = function() return true end,
        remove = function(path) files[path] = nil end,
        rename = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
    },
    io = { open = open, popen = function() return { read = function() return 'C:\\lab\\game' end, close = function() end } end },
    print = function() end,
    LoopAsync = function() error('runtime must not enter the async Lua thread') end,
    ExecuteInGameThread = function() error('runtime must not allocate callbacks from an async loop') end,
    LoopInGameThreadWithDelay = function(period, callback)
        assert(#modules == 6, 'timer must start after every module finishes loading')
        timers[#timers + 1] = { period = period, callback = callback }
    end,
    FindAllOf = function()
        assert(game_thread, 'controller lookup must run on the game thread')
        queries = queries + 1
        return {}
    end,
    dofile = function(path)
        assert(#timers == 0, 'module initialization must not overlap a running timer')
        assert(files['C:\\lab\\SolarpunkServer\\.solarpunk-auth-status']:find('ready=0', 1, true), 'old auth status must be invalidated first')
        modules[#modules + 1] = path
    end,
}, { __index = _G })
env._G = env
assert(load(source, '@runtime', 't', env))()
assert(#timers == 1 and timers[1].period == 250)
local calls, survived = 0, 0
env.SolarpunkSP.every('test-failure', 250, 0, function()
    assert(game_thread)
    calls = calls + 1
    error('task failure must not kill heartbeat scheduling')
end)
env.SolarpunkSP.every('test-survivor', 1000, 0, function()
    survived = survived + 1
    assert(env.SolarpunkSP.controllers() == env.SolarpunkSP.controllers(), 'controller snapshot must be shared inside a tick')
end)
for i = 1, 240 do
    now = 100 + math.floor(i / 4)
    game_thread = true
    timers[1].callback()
    game_thread = false
end
assert(calls == 240 and survived == 60 and queries == 60)
local status = assert(files['C:\\lab\\SolarpunkServer\\.solarpunk-runtime-status'])
assert(status:find('ready=1', 1, true) and not status:find('updated=100', 1, true), 'heartbeat must continue after task failures')
print('runtime scheduler: serialized startup, one game-thread timer, isolated errors and live heartbeats passed')
