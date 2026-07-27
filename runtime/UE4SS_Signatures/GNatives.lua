-- GNatives array for Solarpunk (UE 5.7.1)
-- Re-verified unique + correct against PDB on build 23665180 (2026-06-11); all disp32s already wildcarded.
-- Derived from shipped PDB: ?GNatives@@3... at .data RVA 0x76A01D0.
-- Anchored on the sole native-dispatch site (RVA 0x13B11A4):
--   mov eax,r9d ; lea r9,[rip+GNatives] ; mov rcx,r10 ; mov r9,[r9+rax*8]
-- Resolve the RIP-relative lea to return the GNatives base address. Verified unique.
function Register()
    return "41 8B C1 4C 8D 0D ?? ?? ?? ?? 49 8B CA 4D 8B 0C C1"
end

function OnMatchFound(MatchAddress)
    -- lea r9,[rip+rel] is at MatchAddress+3 (3-byte opcode 4C 8D 0D + 4-byte disp)
    local leaInstr = MatchAddress + 3
    local nextInstr = leaInstr + 7
    local offset = DerefToInt32(leaInstr + 3)
    return nextInstr + offset
end
