-- StaticConstructObject_Internal for Solarpunk (UE 5.7.1)
-- Re-verified unique + correct against PDB on build 23665180 (2026-06-11); all disp32s already wildcarded.
-- Derived from shipped PDB: ?StaticConstructObject_Internal@@YA... at .text RVA 0x13CEA9C
-- AOB = function prologue + distinctive param-read body (cookie disp wildcarded). Verified unique.
function Register()
    return "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 38 FE FF FF 48 81 EC A0 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 90 01 00 00 4C 8B 31 33 DB 4C 8B 61 08 48 8B F9 44 8B 79 18 44 8B 69 70 41 F7 86 D4 00 00 00 80 00 00 10"
end

function OnMatchFound(MatchAddress)
    -- Match address IS the function entry; UE4SS calls it directly.
    return MatchAddress
end
