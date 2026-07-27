-- FName::FName(const TCHAR*, EFindName) for Solarpunk (UE 5.7.1)
-- Re-verified unique + correct against PDB on build 23665180 (2026-06-11); all disp32s already wildcarded.
-- Derived from shipped PDB: ??0FName@@QEAA@PEB_WW4EFindName@@@Z at .text RVA 0x122B68C.
-- Solarpunk uses sub rsp,0x40 (FFW used 0x30) which is why the FFW pattern failed here.
-- AOB = prologue through movups body; relative call disp wildcarded. Verified unique.
function Register()
    return "48 89 5C 24 08 57 48 83 EC 40 48 8B D9 41 8B F8 48 8D 4C 24 30 E8 ?? ?? ?? ?? 0F 10 00 48 8B 40 08 0F 29 44 24 20"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
