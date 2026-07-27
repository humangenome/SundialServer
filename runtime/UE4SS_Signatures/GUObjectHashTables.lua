-- FUObjectHashTables::Get() for Solarpunk (UE 5.7.1)
-- Re-verified unique + correct against PDB on build 23665180 (2026-06-11); all disp32s already wildcarded.
-- Derived from shipped PDB: function-local-static Singleton at .data RVA 0x7A72BE8;
-- the sole lea-to-Singleton site (RVA 0x13E1D92) is the tail of Get(); function
-- entry resolved by walking back to int3 padding -> RVA 0x13E1D74. Verified unique.
-- AOB = Get() prologue (guard size mov edx,0xFA0 makes it distinctive; lea/call disps wildcarded).
function Register()
    return "48 83 EC 28 BA A0 0F 00 00 48 8D 0D ?? ?? ?? ?? FF 15 ?? ?? ?? ?? 66 0F 6F 0D"
end

function OnMatchFound(MatchAddress)
    -- Match address IS the Get() function entry; UE4SS calls it to obtain the hash tables.
    return MatchAddress
end
