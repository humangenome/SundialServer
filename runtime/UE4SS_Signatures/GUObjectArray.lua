-- GUObjectArray (FUObjectArray) base for Solarpunk (UE 5.7.1)
-- Built-in scanner resolved base+0x68 -> GetNumElements read garbage -> infinite
-- "Waiting for object construction" spin. PDB ?GUObjectArray@@3VFUObjectArray@@A = .data RVA 0x76CD910.
-- Anchor: sole unique site (RVA 0x1319E53):
--   mov rdi,[rip+disp] ; lea rcx,[rip+GUObjectArray] ; movsxd rsi,eax ; mov rax,[rdi+rsi*8]
-- Resolve the RIP-relative lea to return the true FUObjectArray base.
-- Build 23665180 (2026-06-11): the original AOB hardcoded 3 tail bytes of the
-- NEIGHBORING mov's rip-relative disp32 ("7D 75 06") and broke when the data
-- layout shifted on the 23659698 -> 23665180 update. Every disp32 is now
-- wildcarded so pure layout shifts can't break it. Verified unique on 23665180.
function Register()
    return "48 8B 3D ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 48 63 F0 48 8B 04 F7"
end

function OnMatchFound(MatchAddress)
    -- lea rcx,[rip+rel] at MatchAddress+7 (3-byte opcode 48 8D 0D + 4-byte disp)
    local leaInstr = MatchAddress + 7
    local nextInstr = leaInstr + 7
    local offset = DerefToInt32(leaInstr + 3)
    return nextInstr + offset
end
