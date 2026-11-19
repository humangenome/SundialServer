#!/usr/bin/env python3
"""Licence notices in the release zips.

Every copy of what we ship has to carry the notices its licences ask for: our MIT licence,
the notice of each third-party loader beside the files it covers, and the .NET runtime's
licence and third-party notices beside each self-contained .NET program. The release refuses
a zip that misses one, has an empty one, or has one whose text is not the one it should be.

Usage:
    python scripts/verify-release-notices.py <kind> <zip>
    python3 scripts/verify-release-notices.py server <SundialServer-*.zip>
Exit code 0 = every notice present, 1 = something missing or wrong, 2 = usage or unreadable zip.
"""

import hashlib
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each rule: (entry in the zip, what its text must be)
#   ("same", <repo file>)  word for word the repository's copy (line endings ignored)
#   ("has", <text>)        contains this text
#   ("notices", <repo file>)  word for word the repository's THIRD-PARTY-NOTICES file, and that file still holds
#                          every licence text pinned in NOTICE_TEXTS word for word
#   ("upstream", <repo file>)  word for word the repository's copy of an upstream licence, and that copy
#                          is still the upstream text pinned in UPSTREAM (sha256 of the text with LF line
#                          endings and blank lines and spaces at both ends taken off)
DOTNET_LICENCE = ("has", "The MIT License (MIT)")
DOTNET_NOTICES = ("has", "uses third-party libraries or other resources that may be")

NOTICE_TEXTS = {}

# The supervisor is a self-contained .NET program with ASP.NET Core, so the runtime's licence and notices go beside it.
# (Our own LICENSE.txt and UE4SS's notice are checked by scripts/verify-server-bundle.py.)
REQUIRED = {
    "server": (
        ("SolarpunkServer/dotnet-LICENSE.txt", DOTNET_LICENCE),
        ("SolarpunkServer/dotnet-THIRD-PARTY-NOTICES.txt", DOTNET_NOTICES),
        ("SolarpunkServer/aspnetcore-THIRD-PARTY-NOTICES.txt", DOTNET_NOTICES),
    ),
}

# A notice sits beside the files it covers; if those are gone the package layout changed, so look again.
BESIDE = {
    "SolarpunkServer/dotnet-LICENSE.txt": "SolarpunkServer/SolarpunkServer.exe",
    "SolarpunkServer/dotnet-THIRD-PARTY-NOTICES.txt": "SolarpunkServer/SolarpunkServer.exe",
    "SolarpunkServer/aspnetcore-THIRD-PARTY-NOTICES.txt": "SolarpunkServer/SolarpunkServer.exe",
}


def norm(data):
    return data.decode("utf-8-sig", errors="replace").replace("\r\n", "\n").strip()


def check(kind, path):
    problems = []
    with zipfile.ZipFile(path) as z:
        entries = {}
        for info in z.infolist():
            if not info.filename.endswith("/"):
                entries[info.filename.replace("\\", "/")] = info
        for need, (how, what) in REQUIRED[kind]:
            covered = BESIDE.get(need)
            if covered is not None and covered not in entries:
                problems.append("%s is not in the zip, so %s cannot be checked beside it" % (covered, need))
                continue
            info = entries.get(need)
            if info is None or info.file_size <= 0:
                problems.append("missing licence notice %s" % need)
                continue
            text = norm(z.read(info))
            if how == "same":
                with open(os.path.join(ROOT, what), "rb") as f:
                    if text != norm(f.read()):
                        problems.append("%s is not the repository's %s" % (need, what))
            elif how == "has":
                if what not in text:
                    problems.append("%s does not contain %r" % (need, what))
            elif how == "notices":
                with open(os.path.join(ROOT, what), "rb") as f:
                    ours = norm(f.read())
                if text != ours:
                    problems.append("%s is not the repository's %s" % (need, what))
                lines = ours.split("\n")
                for key, (url, pin, count, first) in sorted(NOTICE_TEXTS.items()):
                    if not any(line == first and hashlib.sha256("\n".join(lines[i:i + count]).encode("utf-8")).hexdigest() == pin
                               for i, line in enumerate(lines)):
                        problems.append("%s no longer holds the %s licence word for word (%s)" % (what, key, url))
            elif how == "upstream":
                with open(os.path.join(ROOT, what), "rb") as f:
                    ours = norm(f.read())
                url, pin = UPSTREAM[what]
                got = hashlib.sha256(ours.encode("utf-8")).hexdigest()
                if got != pin:
                    problems.append("%s is no longer the upstream text pinned for it (%s, sha256 %s, got %s)"
                                    % (what, url, pin, got))
                elif text != ours:
                    problems.append("%s is not the repository's %s" % (need, what))
            else:
                problems.append("unknown rule %r for %s" % (how, need))
    return problems


def main(argv):
    if len(argv) != 3 or argv[1] not in REQUIRED:
        print("usage: python scripts/verify-release-notices.py {%s} <zip>" % "|".join(sorted(REQUIRED)), file=sys.stderr)
        return 2
    kind, path = argv[1], argv[2]
    try:
        problems = check(kind, path)
    except (OSError, zipfile.BadZipFile) as e:
        print("verify-release-notices: cannot read %s: %s" % (path, e), file=sys.stderr)
        return 2
    for p in problems:
        print("verify-release-notices: %s: %s" % (path, p), file=sys.stderr)
    if problems:
        return 1
    print("verify-release-notices: %s zip carries every licence notice (%d)" % (kind, len(REQUIRED[kind])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
