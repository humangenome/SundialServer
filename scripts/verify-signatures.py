#!/usr/bin/env python3
"""Verify (and re-derive) the 5 UE4SS AOB signatures against a Solarpunk build.

Run this after EVERY Steam game update, before customers report anything:

    scripts/verify-signatures.py \
        "/path/to/SolarpunkSteam-Win64-Shipping.exe" \
        "/path/to/SolarpunkSteam-Win64-Shipping.pdb"

For each of the 5 signatures shipped in runtime/UE4SS_Signatures/
(and mirrored in the client app's matching signature set) it checks:
  1. the AOB matches EXACTLY ONCE in the new exe, and
  2. the match resolves to the PDB-authoritative address for that symbol
     (function entry for the entry-style sigs; the rip-relative lea inside the
     match resolves to the .data symbol for the anchor-style sigs).

If an anchor-style signature (GNatives / GUObjectArray) goes stale, the script
scans .text for every `lea r64,[rip+symbol]` site and prints fully-disp32-
wildcarded candidate AOBs (unique-verified) so the .lua can be updated in
minutes. This is the build-churn playbook from the 23659698 -> 23665180 break:
the GUObjectArray AOB had hardcoded a neighboring instruction's disp32 tail and
died on a pure data-layout shift.

Requires: llvm-pdbutil (llvm-pdbutil-18 or llvm-pdbutil on PATH).
Exit code 0 = all 5 verified; 1 = at least one signature needs attention.
"""

import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# The shipped signatures. Keep in lockstep with UE4SS_Signatures/*.lua.
#   kind="entry":  AOB must match once AT the symbol's function entry.
#   kind="anchor": AOB must match once; the lea at match+lea_off must resolve
#                  to the symbol's address (OnMatchFound returns that).
SIGS = {
    "FName_Constructor": dict(
        kind="entry",
        symbol=r"\?\?0FName@@QEAA@PEB_WW4EFindName@@@Z",
        aob="48 89 5C 24 08 57 48 83 EC 40 48 8B D9 41 8B F8 48 8D 4C 24 30 E8 ?? ?? ?? ?? 0F 10 00 48 8B 40 08 0F 29 44 24 20",
    ),
    "StaticConstructObject": dict(
        kind="entry",
        symbol=r"\?StaticConstructObject_Internal@@YA[^`]*",
        aob="48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 38 FE FF FF 48 81 EC A0 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 90 01 00 00 4C 8B 31 33 DB 4C 8B 61 08 48 8B F9 44 8B 79 18 44 8B 69 70 41 F7 86 D4 00 00 00 80 00 00 10",
    ),
    "GUObjectHashTables": dict(
        # Entry-style: the AOB is FUObjectHashTables::Get()'s prologue. The PDB
        # public is the function-local static Singleton (.data); the prologue's
        # lea (at +9) must resolve to it, proving we matched the real Get().
        kind="anchor",
        symbol=r"\?Singleton@\?1\?\?Get@FUObjectHashTables@@SAAEAV2@XZ@4V2@A",
        aob="48 83 EC 28 BA A0 0F 00 00 48 8D 0D ?? ?? ?? ?? FF 15 ?? ?? ?? ?? 66 0F 6F 0D",
        lea_off=9,
    ),
    "GNatives": dict(
        kind="anchor",
        symbol=r"\?GNatives@@3V[^`]*",
        aob="41 8B C1 4C 8D 0D ?? ?? ?? ?? 49 8B CA 4D 8B 0C C1",
        lea_off=3,
    ),
    "GUObjectArray": dict(
        kind="anchor",
        symbol=r"\?GUObjectArray@@3VFUObjectArray@@A",
        aob="48 8B 3D ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 48 63 F0 48 8B 04 F7",
        lea_off=7,
    ),
}


def pdbutil():
    for name in ("llvm-pdbutil-18", "llvm-pdbutil"):
        if shutil.which(name):
            return name
    sys.exit("llvm-pdbutil not found (apt install llvm-18 or similar)")


def load_sections(data):
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, e_lfanew + 6)[0]
    optsize = struct.unpack_from("<H", data, e_lfanew + 20)[0]
    base = e_lfanew + 24 + optsize
    secs = []
    for i in range(nsec):
        off = base + i * 40
        name = data[off:off + 8].rstrip(b"\0").decode()
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        secs.append((name, va, vsize, rawptr, rawsize))
    return secs


def dump_symbols(pdb_path, patterns):
    """One streaming pass over `dump -publics`; returns {pattern: rva_segoff}."""
    pat = re.compile("|".join(f"({p})" for p in patterns))
    addr_re = re.compile(r"addr = (\d+):(\d+)")
    found = {}
    proc = subprocess.Popen(
        [pdbutil(), "dump", "-publics", str(pdb_path)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
    pending = None
    for line in proc.stdout:
        if pending is not None:
            m = addr_re.search(line)
            if m:
                found.setdefault(pending, (int(m.group(1)), int(m.group(2))))
            pending = None
        m = pat.search(line)
        if m and "S_PUB32" in line:
            pending = m.group(0)
    proc.wait()
    return found


def aob_regex(aob):
    out = b""
    for tok in aob.split():
        out += b"." if tok == "??" else re.escape(bytes([int(tok, 16)]))
    return re.compile(out, re.DOTALL)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    exe_path, pdb_path = Path(sys.argv[1]), Path(sys.argv[2])
    data = exe_path.read_bytes()
    secs = load_sections(data)
    text = next(s for s in secs if s[0] == ".text")
    _, text_va, _, text_raw, text_rawsize = text

    def segoff_to_rva(segoff):
        segno, off = segoff
        return secs[segno - 1][1] + off

    def file_to_rva(fo):
        return fo - text_raw + text_va

    # Resolve all 5 symbols in one PDB pass.
    sym_patterns = {name: cfg["symbol"] for name, cfg in SIGS.items()}
    raw = dump_symbols(pdb_path, sym_patterns.values())

    def sym_rva(name):
        cfg = SIGS[name]
        for pat, segoff in raw.items():
            if re.fullmatch(cfg["symbol"], pat) or re.match(cfg["symbol"], pat):
                return segoff_to_rva(segoff)
        return None

    failures = []
    for name, cfg in SIGS.items():
        rva = sym_rva(name)
        if rva is None:
            print(f"[FAIL] {name}: symbol not found in PDB ({cfg['symbol']})")
            failures.append(name)
            continue
        hits = [m.start() for m in aob_regex(cfg["aob"]).finditer(data)]
        if len(hits) != 1:
            print(f"[FAIL] {name}: AOB matched {len(hits)} times (need exactly 1)")
            failures.append(name)
            if cfg["kind"] == "anchor":
                propose_anchors(data, secs, text_va, text_raw, text_rawsize, rva, name)
            continue
        hit = hits[0]
        if cfg["kind"] == "entry":
            ok = file_to_rva(hit) == rva
            detail = f"entry rva {file_to_rva(hit):#x} vs pdb {rva:#x}"
        else:
            lea = hit + cfg["lea_off"]
            disp = struct.unpack_from("<i", data, lea + 3)[0]
            target = file_to_rva(lea) + 7 + disp
            ok = target == rva
            detail = f"lea target {target:#x} vs pdb {rva:#x}"
        if ok:
            print(f"[ OK ] {name}: unique match, {detail}")
        else:
            print(f"[FAIL] {name}: unique match but WRONG address ({detail})")
            failures.append(name)
            if cfg["kind"] == "anchor":
                propose_anchors(data, secs, text_va, text_raw, text_rawsize, rva, name)

    if failures:
        print(f"\n{len(failures)} signature(s) need re-derivation: {', '.join(failures)}")
        print("Update runtime/UE4SS_Signatures/ and "
              "the client app's matching signature set, then re-ship "
              "(bundle pin + launcher release).")
        sys.exit(1)
    print("\nAll 5 signatures verified against this build.")


def propose_anchors(data, secs, text_va, text_raw, text_rawsize, target_rva, name):
    """Find every lea r64,[rip+target] site; print wildcarded candidate AOBs."""
    text = data[text_raw:text_raw + text_rawsize]
    sites = []
    for m in re.finditer(rb"[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", text):
        i = m.start()
        disp = struct.unpack_from("<i", text, i + 3)[0]
        if text_va + i + 7 + disp == target_rva:
            sites.append(i)
    print(f"       {name}: {len(sites)} lea-site candidate(s) for {target_rva:#x}")
    for i in sites[:8]:
        # Window: lea (7 bytes, disp wildcarded) + 16 following bytes, with any
        # plausible embedded disp32s left literal — human must wildcard those if
        # the candidate spans another rip-relative instruction.
        window = text[i:i + 23]
        toks = [f"{b:02X}" for b in window]
        for w in range(3, 7):
            toks[w] = "??"
        aob = " ".join(toks)
        n = len(aob_regex(aob).findall(data))
        print(f"         file+{text_raw + i:#x}: '{aob}' -> {n} match(es)"
              f"{'  <-- UNIQUE, usable (lea_off=0)' if n == 1 else ''}")


if __name__ == "__main__":
    main()
