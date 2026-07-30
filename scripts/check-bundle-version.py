#!/usr/bin/env python3
"""Assert the built bundle reports the tag it is about to be published under.

    python3 scripts/check-bundle-version.py dist/SundialServer-v0.1.69.zip v0.1.69

The version is not cosmetic: /api/v1/info reports it, the panel reads it, and a
bundle that reports a different version from its tag is a support surface that
cannot be corrected after publication. v0.1.68 shipped reporting 0.1.66 because
the packager published whatever Directory.Build.props said at build time and
nothing compared the two.

Two independent axes inside the shipped artifact, not the build directory:

  * the win-x64 apphost's VS_FIXEDFILEINFO FileVersion and ProductVersion
  * every first-party library version recorded in SolarpunkServer.deps.json

Exit 0 only when both agree with the tag.
"""

import json
import struct
import sys
import zipfile

ROOT = "SolarpunkServer"
FIXEDFILEINFO_SIGNATURE = 0xFEEF04BD


def quad(ms, ls):
    return (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)


def apphost_versions(blob):
    """Every VS_FIXEDFILEINFO block in the PE, as (file, product) quads."""
    sig = struct.pack("<I", FIXEDFILEINFO_SIGNATURE)
    found = []
    at = blob.find(sig)
    while at != -1:
        if at + 24 <= len(blob):
            fms, fls, pms, pls = struct.unpack_from("<IIII", blob, at + 8)
            found.append((quad(fms, fls), quad(pms, pls)))
        at = blob.find(sig, at + 4)
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    path, tag = argv
    version = tag[1:] if tag.startswith("v") else tag
    numeric = version.split("-", 1)[0]
    try:
        parts = tuple(int(p) for p in numeric.split("."))
    except ValueError:
        print("FAIL: %r is not a numeric version" % numeric)
        return 2
    if len(parts) != 3:
        print("FAIL: expected a three-part version, got %r" % numeric)
        return 2
    expected = parts + (0,)

    failures = []
    try:
        with zipfile.ZipFile(path) as zf:
            exe = zf.read(ROOT + "/SolarpunkServer.exe")
            deps = json.loads(zf.read(ROOT + "/SolarpunkServer.deps.json"))
    except Exception as exc:  # noqa: BLE001 - fail closed
        print("FAIL: cannot read %s: %s" % (path, exc))
        return 2

    blocks = apphost_versions(exe)
    if not blocks:
        failures.append("SolarpunkServer.exe carries no version resource at all")
    for file_v, product_v in blocks:
        if file_v != expected:
            failures.append("apphost FileVersion is %s, tag says %s"
                            % (".".join(map(str, file_v)), ".".join(map(str, expected))))
        if product_v != expected:
            failures.append("apphost ProductVersion is %s, tag says %s"
                            % (".".join(map(str, product_v)), ".".join(map(str, expected))))

    libs = {k: v for k, v in deps.get("libraries", {}).items()
            if k.lower().startswith("solarpunk")}
    if not libs:
        failures.append("deps.json names no first-party libraries")
    for name in sorted(libs):
        stamped = name.split("/", 1)[1]
        if stamped != numeric:
            failures.append("%s is stamped %s, tag says %s" % (name.split("/")[0], stamped, numeric))

    if failures:
        print("FAIL %s does not report %s:" % (path, tag))
        for line in failures:
            print("  - %s" % line)
        print("\nBump <Version>/<AssemblyVersion>/<FileVersion> in Directory.Build.props "
              "in the same commit as the tag.")
        return 1

    print("OK %s reports %s on the apphost and on all %d first-party libraries"
          % (path, numeric, len(libs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
