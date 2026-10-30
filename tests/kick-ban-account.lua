-- Kick and ban by account id, kicks enforced on the server
-- (run from the repository root: lua5.4 tests/kick-ban-account.lua [path/to/server-mods]).
--
-- Loads the real SolarpunkServerRuntime and the six real modules against a stub engine (the
-- harness from save-before-stop.lua) and checks, on an invite-code ("eos") server:
--   * the roster keys players by their account id: two players named "Player 1" are two entries;
--   * a ban by account id kicks that player only, with the ban message; a synthetic-id ban
--     (a name hash) never touches a player who has an account id, and still kicks a player
--     without one;
--   * GameSession:KickPlayer is not callable (as on 1.3.0): a player who ignores the kick
--     message loses character and controller on the server 3 s later; one who leaves does not;
--   * RCON kick through runtime.kick-request / runtime.kick-done.
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
    local W = { objs = {}, loadmap = {}, initgs = {}, files = {}, mtime = {}, ctime = {}, stamp = 0, hooks = {},
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
            return { GetFName = function() return { ToString = function() return c end } end,
                GetFullName = function() return "BlueprintGeneratedClass /Game/Code/Framework/" .. c:gsub("_C$", "") .. "." .. c end }
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
    W.messages, W.removed = {}, {}
    local function new_controller(is_local, name, account_id, obeys)
        local pc = uobj("BP_MainPlayerController_C")
        pc.__local = is_local
        function pc:IsLocalPlayerController() return self.__local end
        local ps = uobj("SkyGamePlayerState", { __name = name })
        function ps:GetPlayerName() return fstr(name) end
        if account_id then ps.SkyGameNativeId = fstr(account_id) end
        pc.PlayerState = ps
        local pawn = uobj("BP_MainPlayerCharacter_C")
        function pawn:K2_DestroyActor() table.insert(W.removed, { who = name, what = "character" }); self.__alive = false end
        pc.Pawn = pawn
        function pc:ClientReturnToMainMenuWithTextReason(reason)
            table.insert(W.messages, { who = name, text = reason and reason:ToString() or "" })
            if obeys ~= false then self.__alive = false; pawn.__alive = false; ps.__alive = false end
        end
        function pc:K2_DestroyActor() table.insert(W.removed, { who = name, what = "controller" }); self.__alive = false end
        return pc
    end
    function W.join(name, account_id, obeys)
        local pc = new_controller(false, name, account_id, obeys)
        if W.gs then table.insert(W.gs.PlayerArray.items, pc.PlayerState) end
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
        W.session = uobj("GameSession")
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
        RegisterHook = function(path, pre) W.hooks[path] = pre; return 1, 1 end,
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
local SP_DIR = SRV .. "\\SolarpunkServer"
local A = "00025a60dcf249c8899393a3f13e46b6"
local B = "0002b54ef4294a8b832cf84bb6ad73da"
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = c ~ string.byte(s, i)
        for _ = 1, 8 do local m = -(c & 1); c = (c >> 1) ~ (0xEDB88320 & m) end
    end
    return (~c) & 0xFFFFFFFF
end
local function synth(name) return string.format("765611900%09d", crc32(string.lower(name)) % 1000000000) end
local function messages_for(W, who) local n, last = 0, nil; for _, m in ipairs(W.messages) do if m.who == who then n = n + 1; last = m.text end end; return n, last end
local function removed_for(W, who) local t = {}; for _, r in ipairs(W.removed) do if r.who == who then t[#t + 1] = r.what end end; return table.concat(t, "+") end
local function auth_log(W) return W.files["C:\\appdata\\Solarpunk\\SolarpunkAuth.log"] or "" end
local function in_world()
    local W = run_stack()
    W.ticks(TICKS_PER_S * 40)
    assert(W.map == "MainLevel", "the host never reached its world")
    return W
end

-- 1. roster: players who share the game's default name stay apart
do
    local W = in_world()
    W.join("Player 1", A); W.join("Player 1", B); W.join("Oak", nil)
    W.ticks(TICKS_PER_S * 7)
    local roster = W.files[SP_DIR .. "\\roster.json"] or ""
    check(roster:find('"SolarpunkUserId":"' .. A .. '"', 1, true) and roster:find('"SolarpunkUserId":"' .. B .. '"', 1, true),
        "[roster] two players named Player 1 are two entries, each under its account id")
    check(roster:find('"SolarpunkUserId":"' .. synth("Oak") .. '"', 1, true) ~= nil,
        "[roster] a player without an account id keeps the synthetic id")
    local n = 0; for _ in roster:gmatch('"DisplayName"') do n = n + 1 end
    check(n == 3, "[roster] three entries (" .. n .. ")")
end

-- 2. a ban by account id kicks that player only, with the ban message; an honest client leaves
do
    local W = in_world()
    W.join("Player 1", A); W.join("Player 1", B)
    W.ticks(TICKS_PER_S * 3)
    W.write(SP_DIR .. "\\bans.txt", A:upper() .. "\n")
    W.ticks(TICKS_PER_S * 8)
    local na, ta = messages_for(W, "Player 1")
    check(na == 1 and ta == "You are banned from this server.", "[ban] the banned player got the ban message once (" .. tostring(na) .. ", " .. tostring(ta) .. ")")
    check(auth_log(W):find("auth DENY (banned) id=" .. A, 1, true) ~= nil, "[ban] the log names the account id, not the name")
    check(#W.removed == 0 and auth_log(W):find("kick done (ban)", 1, true) ~= nil, "[ban] a player who leaves on the message is not removed by force")
end

-- 3. a client that ignores the message is removed on the server 3 s later
do
    local W = in_world()
    W.join("Maple", A, false)
    W.ticks(TICKS_PER_S * 3)
    W.write(SP_DIR .. "\\bans.txt", A .. "\n")
    for _ = 1, TICKS_PER_S * 10 do
        if select(1, messages_for(W, "Maple")) > 0 then break end
        W.ticks(1)
    end
    check(select(1, messages_for(W, "Maple")) == 1, "[enforce] the message went out once")
    W.ticks(TICKS_PER_S * 2)
    check(removed_for(W, "Maple") == "", "[enforce] nothing removed in the first 2 s after the message")
    W.ticks(TICKS_PER_S * 3)
    check(removed_for(W, "Maple") == "character+controller", "[enforce] character and controller removed on the server (" .. removed_for(W, "Maple") .. ")")
    check(auth_log(W):find("kick enforced (ban)", 1, true) ~= nil, "[enforce] the log says the kick was enforced")
    W.ticks(TICKS_PER_S * 10)
    check(select(1, messages_for(W, "Maple")) == 1 and removed_for(W, "Maple") == "character+controller", "[enforce] never touched twice")
end

-- 4. a synthetic id (a name hash) never bans a player with an account id; it still bans one without
do
    local W = in_world()
    W.join("Player 1", A); W.join("Oak", nil)
    W.ticks(TICKS_PER_S * 3)
    W.write(SP_DIR .. "\\bans.txt", synth("Player 1") .. "\n" .. synth("Oak") .. "\n")
    W.ticks(TICKS_PER_S * 8)
    check(select(1, messages_for(W, "Player 1")) == 0, "[synthetic] the name-hash ban does not touch the player who has an account id")
    local no, to = messages_for(W, "Oak")
    check(no == 1 and to == "You are banned from this server.", "[synthetic] the old synthetic-id ban still kicks a player without an account id")
end

-- 5. RCON kick through the request file
do
    local W = in_world()
    W.join("Player 1", A); W.join("Player 1", B)
    W.ticks(TICKS_PER_S * 3)
    local function ask(line)
        W.files[SP_DIR .. "\\runtime.kick-done"] = nil
        W.write(SP_DIR .. "\\runtime.kick-request", line .. "\n")
        W.ticks(TICKS_PER_S * 2)
        return W.files[SP_DIR .. "\\runtime.kick-done"] or ""
    end
    check(ask("t1 " .. B):find("^t1 kicked ") ~= nil, "[kick] a kick by account id answers kicked")
    local nb, tb = messages_for(W, "Player 1")
    check(nb == 1 and tb == "You were removed from this server by its admin.", "[kick] exactly one player got the admin message (" .. tostring(nb) .. ")")
    check(ask("t2 0002ffffffffffffffffffffffffffff"):find("^t2 not%-online ") ~= nil, "[kick] an id nobody has answers not-online")
    check(ask("t3 " .. synth("server-1a2b")):find("^t3 not%-online ") ~= nil, "[kick] the host's own controller is never a target")
    check(W.files[SP_DIR .. "\\runtime.kick-request"] == nil, "[kick] the request file is consumed")
end

print(failures == 0 and "kick ban account: all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
