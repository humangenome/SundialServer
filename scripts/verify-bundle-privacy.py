#!/usr/bin/env python3
"""Refuse to publish a bundle that carries private material.

This is the gate that v0.1.68 did not have. That bundle was hand-built and
hand-uploaded, and it shipped a build machine's home directory in twelve
binaries plus two identifiers in readable Lua -- to the public release page and,
byte-identical, to every host that installed it.

    python3 scripts/verify-bundle-privacy.py <archive-or-file> [...]

What it checks, on every member of every archive:

  * literal tokens in BOTH encodings -- ASCII/UTF-8 and UTF-16LE. .NET string
    tables are UTF-16, so an ASCII-only scan reports a leaking assembly clean.
    A previous pass found exactly that: a token present only as UTF-16.
  * patterns over a latin-1 view of the raw bytes and over a reconstructed view
    of the UTF-16LE printable runs, for the classes that are shaped rather than
    literal (an identifier with a number in it, a build path).

It never converts encodings with an external tool and never guesses at a
member's type from its filename. It reads the archive's own central directory,
scans every listed file entry, and fails closed if the number of entries it
managed to read does not equal the number the directory listed.

What it deliberately does NOT check: a CI runner's checkout path. Third-party
NuGet packages in the publish output carry their own project's runner path, so a
rule for it fails every release on somebody else's public build directory. Our
own assemblies are covered where it belongs -- the AssertNoBuildPathInAssembly
target in Directory.Build.props fails the compile, not the publish.

The pattern list is stored encoded. Written out plainly it would publish, in a
public repository, the exact strings it exists to keep out of public artifacts,
which is self-defeating -- the same reasoning as the source guard in
.github/workflows/release.yml. Decode it if you need to read it:

    python3 -c "import base64,sys;print(base64.b64decode(open(sys.argv[1],'rb').read().split(b'PATTERNS_B64 = \"')[1].split(b'\"')[0]).decode())" scripts/verify-bundle-privacy.py

Exit: 0 clean, 1 violation, 2 error.
"""

import base64
import json
import os
import re
import sys
import zipfile

# base64 of a JSON document: {"tokens": [...], "patterns": [[id, regex], ...]}
PATTERNS_B64 = "eyJ0b2tlbnMiOiBbInNzcGFuZWwiLCAic3NwYW5lbC1yZW1vdGUiLCAiQzpcXHNzcGFuZWwiLCAicGFzc3Jjb24iLCAicnlhbnBlbm5pbmd0b24iLCAiL2hvbWUvcnlhbnBlbm5pbmd0b24iLCAicHJvamVjdHMvc3Vydml2YWxzZXJ2ZXJzIiwgIlN1bmRpYWxDbGllbnQiLCAicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsICJiLWNkbi5uZXQiXSwgInBhdHRlcm5zIjogW1sic3VwcG9ydC10aWNrZXQtaWRlbnRpZmllciIsICIoP2kpdGlja2V0WyBcXHRfIy1dP1swLTldezYsN30iXSwgWyJob3N0LWluc3RhbmNlLWlkZW50aWZpZXIiLCAiXFxiZ3NbIF8tXT9bMC05XXs1LDd9XFxiIl0sIFsiZGV2ZWxvcGVyLWhvbWUtZGlyZWN0b3J5IiwgIi9ob21lL1tBLVphLXowLTlfLi1dKy9wcm9qZWN0cyJdLCBbIm9wZXJhdG9yLW5ldHdvcmstYWRkcmVzcyIsICJcXGIoPzo1MVxcLjE2MVxcLjEyXFwuMTAzfDUxXFwuNzdcXC4xMTlcXC4xN1s1Nl18MTk4XFwuMTk5XFwuODZcXC4xOSlcXGIiXV19"

MAX_MEMBER = 256 * 1024 * 1024


def rules():
    doc = json.loads(base64.b64decode(PATTERNS_B64).decode("utf-8"))
    return doc["tokens"], [(rid, re.compile(rx)) for rid, rx in doc["patterns"]]


TOKENS, PATTERNS = rules()


def utf16_printable(blob):
    """Reconstruct the UTF-16LE printable runs so a pattern can be matched
    against text that only exists in a .NET string table."""
    return "\n".join(
        m.group().decode("utf-16-le", "replace")
        for m in re.finditer(rb"(?:[\x20-\x7e]\x00){6,}", blob)
    )


def scan(member, blob, hits):
    for tok in TOKENS:
        seen = []
        if tok.encode("utf-8", "ignore") in blob:
            seen.append("ascii")
        if tok.encode("utf-16-le", "ignore") in blob:
            seen.append("utf-16le")
        if seen:
            hits.append((member, "token", "%r (%s)" % (tok, "+".join(seen))))
    latin = blob.decode("latin-1", "replace")
    wide = utf16_printable(blob)
    for rid, rx in PATTERNS:
        m = rx.search(latin)
        if m:
            hits.append((member, rid, "ascii: %r" % m.group()[:100]))
        m = rx.search(wide)
        if m:
            hits.append((member, rid, "utf-16le: %r" % m.group()[:100]))


def check_archive(path, hits):
    with zipfile.ZipFile(path) as zf:
        bad = zf.testzip()
        if bad is not None:
            hits.append((bad, "SCAN-CORRUPT", "member fails its CRC"))
            return 0, 0
        infos = [i for i in zf.infolist() if not i.is_dir()]
        listed = len(infos)
        read = 0
        for i in infos:
            if i.file_size > MAX_MEMBER:
                hits.append((i.filename, "SCAN-TOO-LARGE",
                             "%d bytes exceeds the scan ceiling" % i.file_size))
                continue
            try:
                blob = zf.read(i)
            except Exception as exc:  # noqa: BLE001 - fail closed
                hits.append((i.filename, "SCAN-UNREADABLE", str(exc)[:160]))
                continue
            read += 1
            scan(i.filename, blob, hits)
        return listed, read


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    rc = 0
    for path in argv:
        hits = []
        if not os.path.isfile(path):
            print("FAIL %s: not a file" % path)
            rc = 2
            continue
        try:
            if path.lower().endswith(".zip"):
                listed, read = check_archive(path, hits)
                print("%s: %d entries listed, %d scanned" % (os.path.basename(path), listed, read))
                if listed == 0:
                    hits.append((path, "SCAN-EMPTY", "archive parsed to zero file entries"))
                elif listed != read:
                    hits.append((path, "SCAN-INCOMPLETE",
                                 "%d of %d entries could not be read" % (listed - read, listed)))
            else:
                with open(path, "rb") as fh:
                    scan(os.path.basename(path), fh.read(), hits)
                print("%s: 1 file scanned" % os.path.basename(path))
        except Exception as exc:  # noqa: BLE001 - fail closed
            print("FAIL %s: %s" % (os.path.basename(path), str(exc)[:200]))
            rc = 2
            continue
        if hits:
            rc = 1
            print("FAIL %s" % os.path.basename(path))
            for member, rid, detail in sorted(set(hits)):
                print("   %-28s %-62s %s" % (rid, member[-62:], detail))
        else:
            print("OK   %s" % os.path.basename(path))
    if rc == 1:
        print("\nREFUSING: private material in a publishable artifact. Do not publish or pin it.")
    elif rc == 0:
        print("\n%d artifact(s) checked, nothing private found." % len(argv))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
