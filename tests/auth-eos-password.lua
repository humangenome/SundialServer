-- Regression test for the password gate in SolarpunkAuth (run: lua5.4 tests/auth-eos-password.lua).
-- 2026-10-16: on a "Transport": "eos" server players join through the game's own invite code and
-- cannot send the Sundial name-channel token, so a configured SolarpunkAuthPassword kicked every
-- one of them after the 120 s grace. On eos the invite code is the gate and the password is not
-- enforced; on the address transport ("ip", the default) nothing changes.
local src = assert(io.open("server-mods/SolarpunkAuth/Scripts/main.lua", "r")):read("a")
local block = src:match("%-%- BEGIN auth_password_choice.-\n(.-)%-%- END auth_password_choice")
assert(block, "auth_password_choice block not found in SolarpunkAuth main.lua")
local AUTHCFG = assert(load(block .. "\nreturn AUTHCFG", "auth_password_choice", "t", { type = type, string = string }))()

local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print("FAIL " .. msg) else print("ok   " .. msg) end end

local function eff(pw, transport) return AUTHCFG.effective_password(pw, transport) end

local p, aside = eff("hunter2", "eos")
check(p == "" and aside == true, "eos with a password: not enforced, reported as set aside")
p, aside = eff("hunter2", "EOS")
check(p == "" and aside == true, "eos is matched whatever its case")
p, aside = eff("", "eos")
check(p == "" and aside == false, "eos without a password: open, nothing set aside")
p, aside = eff("hunter2", "ip")
check(p == "hunter2" and aside == false, "ip with a password: enforced as before")
p, aside = eff("hunter2", nil)
check(p == "hunter2" and aside == false, "no Transport key (the default address join): enforced as before")
p, aside = eff(nil, nil)
check(p == "" and aside == false, "no password and no Transport: open")
p, aside = eff("hunter2", "eosx")
check(p == "hunter2" and aside == false, "only the exact value eos turns the gate off")

-- The module must take the gate's password from this choice, not from the raw setting.
check(src:find("CONFIGURED_PASSWORD, set_aside = AUTHCFG.effective_password(configured, transport)", 1, true) ~= nil,
    "the loaded password goes through effective_password")
check(src:find('extract_json_string(body, "Transport")', 1, true) ~= nil, "the module reads the Transport setting")

if failures > 0 then print(failures .. " failed"); os.exit(1) end
print("auth eos password: all passed")
