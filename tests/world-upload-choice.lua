-- Regression test for the world-upload choice in SolarpunkHost (run: lua5.4 tests/world-upload-choice.lua).
-- 2026-10-13: a customer re-uploaded a single-player save over FTP; the FTP program kept the
-- file's original (older) time, the host picked "the newest .sav by file time" (its own copy)
-- and archived the upload unloaded. The choice must go by content the host has never seen,
-- newest by creation time first, whatever the file time says.
local src = assert(io.open("server-mods/SolarpunkHost/Scripts/main.lua", "r")):read("a")
local block = src:match("%-%- BEGIN world_upload_choice.-\n(.-)%-%- END world_upload_choice")
assert(block, "world_upload_choice block not found in SolarpunkHost main.lua")
local WU = assert(load(block .. "\nreturn WU", "world_upload_choice", "t", { string = string, math = math, ipairs = ipairs, tostring = tostring }))()

local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print("FAIL " .. msg) else print("ok   " .. msg) end end

-- FNV-1a 64 published vectors
check(WU.fnv1a64("") == "cbf29ce484222325", "fnv1a64 of the empty string")
check(WU.fnv1a64("a") == "af63dc4c8601ec8c", "fnv1a64 of 'a'")
check(WU.fnv1a64("foobar") == "85944171f73967e8", "fnv1a64 of 'foobar'")
local big = string.rep("solarpunk", 20000)
check(WU.fingerprint(big) == tostring(#big) .. ":" .. WU.fnv1a64(big), "fingerprint is size plus hash")
check(WU.fingerprint(big) ~= WU.fingerprint(big .. "x"), "one changed byte changes the fingerprint")
check(WU.fingerprint("") == nil and WU.fingerprint(nil) == nil, "empty or missing data has no fingerprint")

-- The incident: the host's own copy (sb.sav) and the game's slot are known; the upload is
-- back-dated (older file time) but landed last (newest creation time, so it is listed first).
local host_copy, game_slot, upload = "CSAV-host-copy-108391", "CSAV-game-slot-108391b", "CSAV-customer-upload-123486"
local known = { [WU.fingerprint(host_copy)] = true, [WU.fingerprint(game_slot)] = true }
local by_creation = {
    { name = "SB61E303DD44BD45A59338FF8FA10854.sav", fp = WU.fingerprint(upload), mtime = 1447 },
    { name = "C02A284D4A3303ECA77B24A79C376C33.sav", fp = WU.fingerprint(game_slot), mtime = 1452 },
}
local pick = WU.choose(by_creation, known)
check(pick and pick.name == "SB61E303DD44BD45A59338FF8FA10854.sav", "a back-dated upload wins over the host's own copies")
-- what the old rule did: newest by file time, which is the game's slot (and the upload got archived)
table.sort(by_creation, function(a, b) return a.mtime > b.mtime end)
check(by_creation[1].name ~= "SB61E303DD44BD45A59338FF8FA10854.sav", "(the old file-time rule would have missed it)")

-- Only the host's own content: nothing to adopt.
check(WU.choose({ { name = "slot.sav", fp = WU.fingerprint(game_slot) } }, known) == nil, "known content is never adopted")
check(WU.choose({}, known) == nil, "no candidates, no change")
-- Two fresh uploads: the one that landed last (listed first) wins.
local two = { { name = "second.sav", fp = WU.fingerprint("B") }, { name = "first.sav", fp = WU.fingerprint("A") } }
check(WU.choose(two, known).name == "second.sav", "of two uploads the newest by creation time wins")

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("world-upload-choice: all passed")
