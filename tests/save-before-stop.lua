-- Save before stop (run from the repository root: lua5.4 tests/save-before-stop.lua [path/to/server-mods]).
--
-- Stopping the game ends its process, and the game writes nothing when it is ended, so everything
-- since the last autosave (every 150 s of world time) was lost at every stop. The stop step now
-- writes <SolarpunkServer>\runtime.save-request and waits for runtime.save-done. This loads the real
-- SolarpunkServerRuntime and the six real modules against a stub engine and checks:
--   * "save" in the world: the game's own SaveToDisk is called once, the answer comes after the
--     game log's "Saving to '<slot>' was successful", and the new save is the world file and in the
--     upload ledger (so the next start does not take it for a customer upload);
--   * "mirror": no save call, the newest slot is copied into the world file;
--   * outside the world: skipped, no save call;
--   * a SaveToDisk that throws, and a save that never logs: answered, bounded, no hang.
-- Mocked engine: it checks the host mod's bookkeeping, not a retail server.
local MODS = arg[1] or "server-mods"

local failures = 0
local function check(cond, label)
    if cond then print("ok   " .. label) else print("FAIL " .. label); failures = failures + 1 end
end

local function read_file(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local s = f:read("a"); f:close(); return s
end

local host_src = read_file(MODS .. "/SolarpunkHost/Scripts/main.lua")
local wu_block = host_src:match("%-%- BEGIN world_upload_choice.-\n(.-)%-%- END world_upload_choice")
assert(wu_block, "world_upload_choice block not found in SolarpunkHost main.lua")
local WU = assert(load(wu_block .. "\nreturn WU", "world_upload_choice", "t",
    { string = string, math = math, ipairs = ipairs, tostring = tostring }))()

local SRV = "C:\\srv\\host1"
local SAVES = SRV .. "\\UserDir\\Saved\\SaveGames"
local GAME_LOG = SRV .. "\\UserDir\\sp-ue.log"
local REQ = SRV .. "\\SolarpunkServer\\runtime.save-request"
local DONE = SRV .. "\\SolarpunkServer\\runtime.save-done"
local SLOT = "12CBC1CD4AF1836F9472849EE1247568"

local function run_stack(opts)
    opts = opts or {}
    local W = { objs = {}, loadmap = {}, initgs = {}, files = {}, mtime = {}, ctime = {}, stamp = 0,
        loop = nil, save_calls = 0, game_saves = 0 }

    local next_addr = 0x1000
    local function uobj(cls, fields)
        local o = fields or {}
        next_addr = next_addr + 0x10
        o.__addr, o.__cls, o.__alive = next_addr, cls, true
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
    local function new_controller(is_local, name)
        local pc = uobj("BP_MainPlayerController_C")
        pc.__local = is_local
        function pc:IsLocalPlayerController() return self.__local end
        local ps = uobj("BP_SkyPlayerState_C", { __name = name })
        function ps:GetPlayerName() return fstr(name) end
        pc.PlayerState = ps
        return pc
    end

    -- in-memory files with write order (dir /o-d) and creation order (/t:c)
    local function touch(path)
        W.stamp = W.stamp + 1
        W.mtime[path] = W.stamp
        if not W.ctime[path] then W.ctime[path] = W.stamp end
    end
    function W.write(path, data) W.files[path] = data; touch(path) end
    function W.log(line) W.files[GAME_LOG] = (W.files[GAME_LOG] or "") .. line .. "\r\n" end

    local function memfile(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "r" then
            local data = W.files[path]
            if data == nil then return nil end
            local pos = 1
            local h = {}
            function h:read(fmt)
                if type(fmt) == "number" then
                    if pos > #data then return nil end
                    local r = data:sub(pos, pos + fmt - 1); pos = pos + #r; return r
                end
                fmt = tostring(fmt or "l"):gsub("^%*", "")
                if pos > #data then return (fmt == "a") and "" or nil end
                if fmt == "a" then local r = data:sub(pos); pos = #data + 1; return r end
                local e = data:find("\n", pos, true) or (#data + 1)
                local line = data:sub(pos, e - 1):gsub("\r$", ""); pos = e + 1
                return line
            end
            function h:lines() return function() return h:read("l") end end
            function h:seek(whence, off)
                whence, off = whence or "cur", off or 0
                if whence == "set" then pos = off + 1 elseif whence == "end" then pos = #data + off + 1 else pos = pos + off end
                return pos - 1
            end
            function h:close() end
            return h
        end
        if mode:sub(1, 1) == "w" or W.files[path] == nil then W.files[path] = "" end
        touch(path)
        local h = {}
        function h:write(...) for _, x in ipairs({ ... }) do W.files[path] = W.files[path] .. tostring(x) end touch(path) return h end
        function h:close() end
        function h:flush() end
        function h:setvbuf() end
        function h:seek() return #W.files[path] end
        return h
    end
    W.files[SRV .. "\\SolarpunkServer\\appsettings.json"] =
        '{ "Solarpunk": { "InstanceId": "host1", "WorldName": "World1", "Transport": "eos", "SolarpunkAuthPassword": "" } }'
    W.write(SAVES .. "\\World1.sav", "CSAV-world-boot")
    W.files[GAME_LOG] = ""

    local function dir_list(cmd)
        local dir = cmd:match('dir [^"]*"(.-)\\%*%.sav"')
        if not dir then return {} end
        local by_creation = cmd:find("/t:c", 1, true) ~= nil
        local out = {}
        for p in pairs(W.files) do
            local name = p:sub(#dir + 2)
            if p:sub(1, #dir + 1) == dir .. "\\" and not name:find("\\", 1, true) and name:lower():match("%.sav$") then
                out[#out + 1] = { name = name, t = by_creation and W.ctime[p] or W.mtime[p] }
            end
        end
        if cmd:find("/o-d", 1, true) then table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end) end
        local names = {}
        for i, e in ipairs(out) do names[i] = e.name end
        return names
    end
    local stub_io = {
        open = memfile,
        popen = function(cmd)
            local lines = {}
            if cmd == "cd" then lines = { SRV } elseif cmd:sub(1, 4) == "dir " then lines = dir_list(cmd) end
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
    W.now = function() return clock end
    local stub_os = {
        time = function(t) if t then return os.time(t) end return clock end,
        clock = function() return clock end,
        date = os.date,
        getenv = function(k) if k == "APPDATA" then return "C:\\appdata" end return nil end,
        execute = function() return true end,
        remove = function(p) W.files[p] = nil; return true end,
        rename = function(a, b)
            if W.files[a] == nil then return nil, "no such file" end
            W.files[b] = W.files[a]; W.files[a] = nil
            W.mtime[b] = W.mtime[a]; W.ctime[b] = W.ctime[b] or W.ctime[a]
            return true
        end,
        tmpname = os.tmpname,
    }

    -- the game's own save: SaveToDisk writes the slot one frame later and logs it
    function W.game_save(content)
        W.game_saves = W.game_saves + 1
        local data = content or ("CSAV-world-save-" .. W.game_saves)
        W.log("[2026.10.26-19.00.00:000][100]LogExtendedSavegameSubsystem: [UExtendedSavegameSubsystem::AsyncSaveCompressedGameToSlot] Saving game to slot '" .. SLOT .. "'")
        W.write(SAVES .. "\\" .. SLOT .. ".sav", data)
        W.log("[2026.10.26-19.00.00:033][101]LogExtendedSavegameSubsystem: [UExtendedSavegameSubsystem::AsyncSaveCompressedGameToSlot::<lambda_1>::()::<lambda_1>::operator ()] Saving to '" .. SLOT .. "' was successful")
        return data
    end

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
        function W.save:SaveToDisk()
            W.save_calls = W.save_calls + 1
            if opts.save == "throws" then error("SaveToDisk: no UFunction") end
            if opts.save ~= "silent" then W.pending_save = true end
        end
        for _, cb in ipairs(W.initgs) do cb() end
        for _, cb in ipairs(W.loadmap) do cb() end
        W.game_save("CSAV-world-first-autosave")
    end

    W.gi = uobj("BP_SkyGameInstance_C", { HostGame = function() W.hostgame = true end })
    W.engine = uobj("GameEngine", { NetDriverDefinitions = tarray({}) })
    W.menu()

    local function FindAllOf(cls)
        local out = {}
        for _, o in ipairs(W.objs) do if o.__alive and o.__cls == cls then out[#out + 1] = o end end
        return (#out > 0) and out or nil
    end
    local function FindFirstOf(cls)
        for _, o in ipairs(W.objs) do if o.__alive and o.__cls == cls then return o end end
        return INVALID
    end

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
        StaticFindObject = function() return INVALID end,
        FName = function(s) return fstr(s) end, FText = function(s) return fstr(s) end,
        RegisterHook = function() return 1, 1 end,
        LoopAsync = function(_, fn) W.loop = fn end,
        ExecuteInGameThread = function(fn) fn() end,
        ExecuteWithDelay = function() end,
        RegisterLoadMapPostHook = function(fn) table.insert(W.loadmap, fn) end,
        RegisterInitGameStatePostHook = function(fn) table.insert(W.initgs, fn) end,
    }, { __index = _G })
    env._G = env

    load_mod_file(SRV .. "\\SolarpunkServer\\ue4ss-server\\Mods\\SolarpunkServerRuntime\\Scripts\\main.lua")
    assert(W.loop, "runtime registered no scheduler loop")

    W.tick_count = 0
    function W.ticks(n)
        for _ = 1, n do
            W.loop()
            W.tick_count = W.tick_count + 1
            if W.tick_count % 4 == 0 then clock = clock + 1 end
            if W.pending_save then W.pending_save = false; W.game_save() end
            if W.hostgame and W.map == "MainMenu" and not opts.stay_in_menu then W.host_world() end
        end
    end
    -- write a request; tick until runtime.save-done carries its token (or give up); seconds waited
    function W.ask(token, mode, max_s)
        W.files[DONE] = nil
        W.write(REQ, token .. " " .. mode .. "\n")
        local start = clock
        for _ = 1, (max_s or 40) * 4 do
            W.ticks(1)
            local d = W.files[DONE]
            if d and d:sub(1, #token + 1) == token .. " " then return d, clock - start end
        end
        return nil, clock - start
    end
    function W.ledger_has(data)
        local l = W.files[SAVES .. "\\sundial-world-ledger.txt"] or ""
        return l:find(WU.fingerprint(data), 1, true) ~= nil
    end
    return W
end

local TICKS_PER_S = 4

-- 1. save, in the world
do
    local W = run_stack()
    W.ticks(TICKS_PER_S * 40)
    check(W.map == "MainLevel", "[save] the host reached its world")
    local calls = W.save_calls
    local answer, waited = W.ask("stop-20261026190000", "save")
    check(answer ~= nil, "[save] the stop step gets an answer (runtime.save-done)")
    answer = answer or ""
    check(answer:find("^stop%-20261026190000 saved slot=" .. SLOT .. " world=copied ", 1, false) ~= nil, "[save] the answer says saved, which slot, world copied (" .. answer:gsub("%s+$", "") .. ")")
    check(waited <= 3, "[save] answered within 3 s of the request (" .. tostring(waited) .. " s)")
    check(W.save_calls == calls + 1, "[save] the game's SaveToDisk was called exactly once")
    local slot_data = W.files[SAVES .. "\\" .. SLOT .. ".sav"]
    check(W.files[SAVES .. "\\World1.sav"] == slot_data and slot_data ~= "CSAV-world-first-autosave", "[save] the new save is the world file")
    check(slot_data ~= nil and W.ledger_has(slot_data), "[save] the new save is in the upload ledger (not an 'upload' at the next start)")
    check(W.files[REQ] == nil, "[save] the request file is gone")
    W.ticks(TICKS_PER_S * 10)
    check(W.save_calls == calls + 1, "[save] no further save calls after the answer")
    local again = W.ask("stop-20261026190100", "save")
    check(again and again:find("^stop%-20261026190100 saved") ~= nil and W.save_calls == calls + 2, "[save] a second request is served the same way")
end

-- 2. mirror: the game saved moments ago and the 15 s copy has not run yet
do
    local W = run_stack()
    W.ticks(TICKS_PER_S * 40)
    local calls = W.save_calls
    local fresh = W.game_save("CSAV-world-just-saved")
    local answer, waited = W.ask("stop-20261026190200", "mirror")
    answer = answer or ""
    check(answer:find("^stop%-20261026190200 mirrored world=copied") ~= nil, "[mirror] answered mirrored, world copied (" .. answer:gsub("%s+$", "") .. ")")
    check(waited <= 2, "[mirror] answered within 2 s")
    check(W.save_calls == calls, "[mirror] no SaveToDisk call")
    check(W.files[SAVES .. "\\World1.sav"] == fresh and W.ledger_has(fresh), "[mirror] the newest slot is the world file and in the ledger")
end

-- 3. outside the world (still in the menu)
do
    local W = run_stack({ stay_in_menu = true })
    W.ticks(TICKS_PER_S * 20)
    local answer = W.ask("stop-20261026190300", "save") or ""
    check(answer:find("^stop%-20261026190300 skipped: not in the game world") ~= nil, "[menu] skipped outside the world (" .. answer:gsub("%s+$", "") .. ")")
    check(W.save_calls == 0, "[menu] no SaveToDisk call")
end

-- 4. SaveToDisk throws (a game build without it)
do
    local W = run_stack({ save = "throws" })
    W.ticks(TICKS_PER_S * 40)
    local answer, waited = W.ask("stop-20261026190400", "save")
    answer = answer or ""
    check(answer:find("^stop%-20261026190400 failed: SaveToDisk") ~= nil, "[throws] answered failed (" .. answer:gsub("%s+$", "") .. ")")
    check(waited <= 2, "[throws] answered at once")
    check(answer:find("\n", 1, true) == #answer, "[throws] the answer is one line")
    check(answer:find(" world=current ", 1, true) ~= nil, "[throws] says the world file is already the newest save")
end

-- 5. the save never logs: bounded
do
    local W = run_stack({ save = "silent" })
    W.ticks(TICKS_PER_S * 40)
    local answer, waited = W.ask("stop-20261026190500", "save")
    answer = answer or ""
    check(answer:find("^stop%-20261026190500 timeout: no save line in 12 s") ~= nil, "[silent] answered timeout (" .. answer:gsub("%s+$", "") .. ")")
    check(waited >= 12 and waited <= 14, "[silent] after 12-14 s (" .. tostring(waited) .. " s)")
end

-- 6. junk in the request: a token is cleaned, an unknown mode is refused
do
    local W = run_stack()
    W.ticks(TICKS_PER_S * 40)
    local calls = W.save_calls
    local answer = W.ask("stop-1", "reboot") or ""
    check(answer:find("^stop%-1 skipped: unknown mode 'reboot'") ~= nil and W.save_calls == calls, "[junk] an unknown mode is refused without a save")
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("save before stop: all passed")
