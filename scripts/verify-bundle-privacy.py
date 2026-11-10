#!/usr/bin/env python3
"""Refuse to publish a bundle that carries private material.

This is the gate that v0.1.68 did not have. That bundle was hand-built and
hand-uploaded, and it shipped a build machine's home directory in twelve
binaries plus two identifiers in readable Lua -- to the public release page and,
byte-identical, to every host that installed it.

    python3 scripts/verify-bundle-privacy.py [--require-rules] <archive-or-file> [...]

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

The rules are not in this public file: written out here, encoded or not, they
would publish the exact strings they exist to keep out of public artifacts.
They come from the environment: SUNDIAL_PRIVACY_RULES holds a JSON document
{"tokens": [...], "patterns": [[id, regex], ...]} (or that document base64-
encoded), or SUNDIAL_PRIVACY_RULES_FILE names a file that holds it. The Release
workflow passes them from a repository secret on tag pushes only. With
--require-rules a run without them is refused; without the flag (a manual run,
which publishes nothing) only the archive checks run, and it says so.

A hit names the rule by its number and the member, never the matched text,
because CI logs are public.

Exit: 0 clean, 1 violation, 2 error.
"""

import base64
import json
import os
import re
import sys
import zipfile

MAX_MEMBER = 256 * 1024 * 1024


def rules():
    """The tokens and patterns from SUNDIAL_PRIVACY_RULES or SUNDIAL_PRIVACY_RULES_FILE, or None when neither is set."""
    raw = os.environ.get("SUNDIAL_PRIVACY_RULES", "")
    if not raw.strip() and os.environ.get("SUNDIAL_PRIVACY_RULES_FILE"):
        with open(os.environ["SUNDIAL_PRIVACY_RULES_FILE"], encoding="utf-8") as fh:
            raw = fh.read()
    raw = raw.strip()
    if not raw:
        return None
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = json.loads(base64.b64decode(raw).decode("utf-8"))
    return list(doc["tokens"]), [re.compile(rx) for _rid, rx in doc["patterns"]]


def utf16_printable(blob):
    """Reconstruct the UTF-16LE printable runs so a pattern can be matched
    against text that only exists in a .NET string table."""
    return "\n".join(
        m.group().decode("utf-16-le", "replace")
        for m in re.finditer(rb"(?:[\x20-\x7e]\x00){6,}", blob)
    )


def scan(member, blob, hits, ruleset):
    if ruleset is None:
        return
    tokens, patterns = ruleset
    for n, tok in enumerate(tokens, 1):
        seen = []
        if tok.encode("utf-8", "ignore") in blob:
            seen.append("ascii")
        if tok.encode("utf-16-le", "ignore") in blob:
            seen.append("utf-16le")
        if seen:
            hits.append((member, "token #%d" % n, "found (%s); text not shown" % "+".join(seen)))
    latin = blob.decode("latin-1", "replace")
    wide = utf16_printable(blob)
    for n, rx in enumerate(patterns, 1):
        if rx.search(latin):
            hits.append((member, "pattern #%d" % n, "ascii match; text not shown"))
        if rx.search(wide):
            hits.append((member, "pattern #%d" % n, "utf-16le match; text not shown"))


def check_archive(path, hits, ruleset):
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
            scan(i.filename, blob, hits, ruleset)
        return listed, read


def main(argv):
    require = bool(argv) and argv[0] == "--require-rules"
    if require:
        argv = argv[1:]
    if not argv:
        print(__doc__)
        return 2
    try:
        ruleset = rules()
    except Exception as exc:  # noqa: BLE001 - fail closed
        print("FAIL: the privacy rules could not be read (%s)" % type(exc).__name__)
        return 2
    if ruleset is None:
        if require:
            print("FAIL: no privacy rules supplied (repository secret SUNDIAL_PRIVACY_RULES); refusing to publish unchecked files")
            return 2
        print("privacy rules not supplied here; archive checks only (the release run checks the rules)")
    rc = 0
    for path in argv:
        hits = []
        if not os.path.isfile(path):
            print("FAIL %s: not a file" % path)
            rc = 2
            continue
        try:
            if path.lower().endswith(".zip"):
                listed, read = check_archive(path, hits, ruleset)
                print("%s: %d entries listed, %d scanned" % (os.path.basename(path), listed, read))
                if listed == 0:
                    hits.append((path, "SCAN-EMPTY", "archive parsed to zero file entries"))
                elif listed != read:
                    hits.append((path, "SCAN-INCOMPLETE",
                                 "%d of %d entries could not be read" % (listed - read, listed)))
            else:
                with open(path, "rb") as fh:
                    scan(os.path.basename(path), fh.read(), hits, ruleset)
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
