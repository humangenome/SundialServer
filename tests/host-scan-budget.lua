-- Whole-list search budget for the server mod stack (run from the repository root:
--   lua5.4 tests/host-scan-budget.lua [path/to/server-mods]).
--
-- FindAllOf / FindFirstOf walk every object the engine has, on the game thread. The host runs a
-- fixed 30 fps step, so every stalled frame is world time that never happens: up to v0.1.93 the
-- stack searched 8.3 times a second (the controller list and the GameState every 250 ms), and
-- hosted worlds ran at 95-96.5% of real time with nobody on.
--
-- This loads the real SolarpunkServerRuntime and the six real modules against a stub engine and
-- counts every FindAllOf / FindFirstOf per window:
--   * settled host world, nobody on, and with one player in: at most 0.1 searches a second;
--   * a joiner is in SP.controllers() on the first tick after its PlayerState joins the
--     PlayerArray; a leave drops it the next tick;
--   * a travel (map load) finds the new world's GameState and controller, with or without the
--     engine's map-load hooks (without them the old objects going away triggers it);
--   * an address reused by an object of another class is not mistaken for the kept one.
-- Mocked engine: it checks the mods' bookkeeping, not a retail server.
local MODS = arg[1] or "server-mods"

local failures = 0
local function check(cond, label)
    if cond then print("ok   " .. label) else print("FAIL " .. label); failures = failures + 1 end
end

local function read_file(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local s = f:read("a"); f:close(); return s
end

local function run_stack(opts)
    opts = opts or {}
    local W = { searches = 0, by = {}, objs = {}, loadmap = {}, initgs = {}, files = {}, loop = nil }

    -- ── stub engine objects ────────────────────────────────────────────────
    local next_addr = 0x1000
    local function uobj(cls, fields)
        local o = fields or {}
        next_addr = next_addr + 0x10
        o.__addr, o.__cls, o.__alive = o.__addr or next_addr, cls, true
        function o:IsValid() return self.__alive end
        function o:GetAddress() return self.__addr end
        function o:GetClass()
            local c = self.__cls
            return { GetFName = function() return { ToString = function() return c end } end }
        end
        function o:GetFullName() return self.__cls .. " /Game/Maps/" .. tostring(W.map) .. "." .. self.__cls end
        function o:GetName() return self.__name or self.__cls end
        function o:GetWorld() return W.world end
        table.insert(W.objs, o)
        return o
    end
    local INVALID = { IsValid = function() return false end }
    local function fstr(s) return { ToString = function() return s end } end
    local function tarray(t)
        local a = { items = t }
        function a:GetArrayNum() return #self.items end
        function a:ForEach(fn) for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end end
        return setmetatable(a, { __index = function(self, k) return rawget(self, "items")[k] end })
    end

    local function new_ps(name)
        local ps = uobj("BP_SkyPlayerState_C", { __name = name })
        function ps:GetPlayerName() return fstr(name) end
        return ps
    end
    local function new_controller(is_local, name)
        local pc = uobj("BP_MainPlayerController_C")
        pc.__local = is_local
        function pc:IsLocalPlayerController() return self.__local end
        pc.PlayerState = new_ps(name)
        return pc
    end

    function W.kill(o) o.__alive = false end
    function W.menu()
        W.map = "MainMenu"
        W.world = uobj("World", { __name = "MainMenu" })
    end
    function W.host_world()
        W.map = "MainLevel"
        W.world = uobj("World", { __name = "MainLevel" })
        W.host = new_controller(true, "server-1a2b")
        W.gs = uobj("BP_SkyGameGameState_C", { PlayerArray = tarray({ W.host.PlayerState }),
            UniqueIDToPlayerNames = tarray({}) })
        W.save = uobj("BPC_SaveManager_C", { CachedSave = nil })
        if opts.hooks ~= false then
            for _, cb in ipairs(W.initgs) do cb() end
            for _, cb in ipairs(W.loadmap) do cb() end
        end
    end
    function W.join(name, subclass)
        local pc = new_controller(false, name)
        if subclass then pc.__supers = { pc.__cls }; pc.__cls = subclass end
        table.insert(W.gs.PlayerArray.items, pc.PlayerState)
        return pc
    end
    function W.leave(pc)
        for i, ps in ipairs(W.gs.PlayerArray.items) do
            if ps == pc.PlayerState then table.remove(W.gs.PlayerArray.items, i); break end
        end
        W.kill(pc); W.kill(pc.PlayerState)
    end
    function W.travel()
        for _, o in ipairs(W.objs) do
            if o.__cls ~= "BP_SkyGameInstance_C" and o.__cls ~= "GameEngine" then o.__alive = false end
        end
        W.host_world()
    end

    W.gi = uobj("BP_SkyGameInstance_C", { HostGame = function() W.hostgame = true end })
    W.engine = uobj("GameEngine", { NetDriverDefinitions = tarray({}) })
    W.menu()

    -- ── stub UE4SS ─────────────────────────────────────────────────────────
    local function search(cls)
        W.searches = W.searches + 1
        W.by[cls] = (W.by[cls] or 0) + 1
    end
    -- like UE4SS: an object matches its own class or any class above it
    local function is_of(o, cls)
        if o.__cls == cls then return true end
        for _, sup in ipairs(o.__supers or {}) do if sup == cls then return true end end
        return false
    end
    local function FindAllOf(cls)
        search(cls)
        local out = {}
        for _, o in ipairs(W.objs) do if o.__alive and is_of(o, cls) then out[#out + 1] = o end end
        return (#out > 0) and out or nil
    end
    local function FindFirstOf(cls)
        search(cls)
        for _, o in ipairs(W.objs) do if o.__alive and is_of(o, cls) then return o end end
        return INVALID
    end

    -- in-memory files (paths are Windows strings)
    local function memfile(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "r" then
            local data = W.files[path]
            if data == nil then return nil end
            local pos = 1
            local h = {}
            function h:read(fmt)
                fmt = tostring(fmt or "l"):gsub("^%*", "")
                if pos > #data then return (fmt == "a") and "" or nil end
                if fmt == "a" then local r = data:sub(pos); pos = #data + 1; return r end
                local e = data:find("\n", pos, true) or (#data + 1)
                local line = data:sub(pos, e - 1):gsub("\r$", ""); pos = e + 1
                return line
            end
            function h:lines() return function() return h:read("l") end end
            function h:close() end
            function h:seek() return #data end
            return h
        end
        if mode:sub(1, 1) == "w" or W.files[path] == nil then W.files[path] = "" end
        local h = {}
        function h:write(...) for _, x in ipairs({ ... }) do W.files[path] = W.files[path] .. tostring(x) end return h end
        function h:close() end
        function h:flush() end
        function h:setvbuf() end
        function h:seek() return #W.files[path] end
        return h
    end
    local SRV = "C:\\srv\\host1"
    W.files[SRV .. "\\SolarpunkServer\\appsettings.json"] =
        '{ "Solarpunk": { "InstanceId": "host1", "WorldName": "World1", "Transport": "eos", "SolarpunkAuthPassword": "" } }'
    local stub_io = {
        open = memfile,
        popen = function(cmd)
            local lines = {}
            if cmd == "cd" then lines = { SRV } end
            local i = 0
            return {
                read = function() i = i + 1; return lines[i] end,
                lines = function() return function() i = i + 1; return lines[i] end end,
                close = function() return true end,
            }
        end,
        lines = function(path) local h = memfile(path, "r"); return h and h:lines() or function() return nil end end,
        write = function() end,
    }
    local clock = os.time()
    local stub_os = {
        time = function(t) if t then return os.time(t) end return clock end,
        clock = function() return clock end,
        date = os.date,
        getenv = function(k) if k == "APPDATA" then return "C:\\appdata" end return nil end,
        execute = function() return true end,
        remove = function(p) W.files[p] = nil; return true end,
        rename = function(a, b) if W.files[a] == nil then return nil, "no such file" end W.files[b] = W.files[a]; W.files[a] = nil; return true end,
        tmpname = os.tmpname,
    }

    local env
    local function load_mod_file(win_path)
        local mod = win_path:match("\\Mods\\([^\\]+)\\Scripts\\main%.lua$")
        assert(mod, "unexpected dofile " .. tostring(win_path))
        local chunk = assert(load(read_file(MODS .. "/" .. mod .. "/Scripts/main.lua"), "@" .. win_path, "t", env))
        return chunk()
    end
    env = setmetatable({
        io = stub_io, os = stub_os, print = function() end, dofile = load_mod_file,
        FindAllOf = FindAllOf, FindFirstOf = FindFirstOf,
        -- NoPhantom's name-array struct resolves on a live host about 6 s after boot, which is
        -- what turns its 250 ms GameState lookup on: resolve it here too.
        StaticFindObject = function(path)
            if tostring(path):find("S_UniqueIDToPlayerName", 1, true) then
                return { IsValid = function() return true end, ForEachProperty = function(_, fn)
                    for _, nm in ipairs({ "UniqueID_3_B562", "PlayerName_4_5A63" }) do
                        fn({ GetFName = function() return fstr(nm) end })
                    end
                end }
            end
            return INVALID
        end,
        FName = function(s) return fstr(s) end, FText = function(s) return fstr(s) end,
        RegisterHook = function() return 1, 1 end,
        LoopAsync = function(_, fn) W.loop = fn end,
        ExecuteInGameThread = function(fn) fn() end,
        ExecuteWithDelay = function() end,
        RegisterLoadMapPostHook = function(fn) table.insert(W.loadmap, fn) end,
        RegisterInitGameStatePostHook = function(fn) table.insert(W.initgs, fn) end,
    }, { __index = _G })
    env._G = env
    if opts.hooks == false then
        env.RegisterLoadMapPostHook = nil
        env.RegisterInitGameStatePostHook = nil
    end

    load_mod_file(SRV .. "\\SolarpunkServer\\ue4ss-server\\Mods\\SolarpunkServerRuntime\\Scripts\\main.lua")
    assert(W.loop, "runtime registered no scheduler loop")
    W.SP = env.SolarpunkSP

    function W.ticks(n)
        for _ = 1, n do
            W.loop()
            W.tick_count = (W.tick_count or 0) + 1
            if W.tick_count % 4 == 0 then clock = clock + 1 end
            -- the host travels from the menu to its world right after HostGame()
            if W.hostgame and W.map == "MainMenu" then W.host_world() end
        end
    end
    function W.window(n)
        local before = W.searches
        local by_before = {}
        for k, v in pairs(W.by) do by_before[k] = v end
        W.ticks(n)
        local by = {}
        for k, v in pairs(W.by) do if v ~= (by_before[k] or 0) then by[#by + 1] = k .. "=" .. (v - (by_before[k] or 0)) end end
        table.sort(by)
        return W.searches - before, table.concat(by, " ")
    end
    function W.has_controller(pc)
        for _, c in ipairs(W.SP.controllers() or {}) do if c == pc then return true end end
        return false
    end
    return W
end

local TICKS_PER_S = 4
local WINDOW_S = 120
local BUDGET = 0.1      -- searches a second, settled

for _, hooks in ipairs({ true, false }) do
    local tag = hooks and "[map hooks]" or "[no map hooks]"
    local W = run_stack({ hooks = hooks })
    W.ticks(TICKS_PER_S * 60)                       -- boot, HostGame, travel, settle
    check(W.map == "MainLevel", tag .. " the host reached its world")
    check(W.has_controller(W.host), tag .. " the host's controller is in SP.controllers()")

    local n, by = W.window(TICKS_PER_S * WINDOW_S)
    local rate = n / WINDOW_S
    print(string.format("     %s idle: %d searches in %d s = %.3f/s (%s)", tag, n, WINDOW_S, rate, by))
    check(rate <= BUDGET, string.format("%s idle world: at most %.2f searches a second", tag, BUDGET))

    local p1 = W.join("Ada")
    W.ticks(1)
    check(W.has_controller(p1), tag .. " a joiner is in SP.controllers() on the next tick")
    n, by = W.window(TICKS_PER_S * WINDOW_S)
    rate = n / WINDOW_S
    print(string.format("     %s one player: %d searches in %d s = %.3f/s (%s)", tag, n, WINDOW_S, rate, by))
    check(rate <= BUDGET, string.format("%s one player in: at most %.2f searches a second", tag, BUDGET))

    local p2 = W.join("Bo")
    W.ticks(1)
    check(W.has_controller(p2) and W.has_controller(p1), tag .. " a second joiner is picked up, the first kept")
    W.leave(p1)
    W.ticks(1)
    check(not W.has_controller(p1) and W.has_controller(p2), tag .. " a leave drops the player on the next tick")

    -- a controller of a subclass (FindAllOf returns subclasses too)
    local p3 = W.join("Cy", "BP_MainPlayerController_Child_C")
    W.ticks(1)
    check(W.has_controller(p3), tag .. " a subclass controller is picked up")
    W.ticks(8)
    check(W.has_controller(p3), tag .. " and kept on the following ticks")
    W.leave(p3)
    W.ticks(1)

    -- an address reused by an object of another class
    local reused = p2.__addr
    p2.__cls = "BP_SomethingElse_C"
    W.ticks(1)
    check(not W.has_controller(p2), tag .. " a reused address of another class is not kept (" .. string.format("0x%x", reused) .. ")")
    p2.__cls = "BP_MainPlayerController_C"

    local old_gs, old_host = W.gs, W.host
    W.travel()
    W.ticks(2)
    check(W.has_controller(W.host) and not W.has_controller(old_host), tag .. " a travel finds the new world's controller")
    local kept_gs = W.SP.kept and W.SP.kept("BP_SkyGameGameState_C")
    check(kept_gs == W.gs and W.gs ~= old_gs, tag .. " a travel finds the new GameState (SP.kept)")
    n = W.window(TICKS_PER_S * WINDOW_S)
    check(n / WINDOW_S <= BUDGET, tag .. " settled again after the travel")
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
