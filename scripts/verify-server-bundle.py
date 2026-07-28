#!/usr/bin/env python3
"""Verify a Sundial server bundle zip before it is published or pinned.

The bundle is the hoster artifact: the .NET supervisor PLUS the in-game runtime
under `SolarpunkServer/ue4ss-server/` (the UE4SS runtime binaries, the
PDB-derived signatures, the native plugin and the server mod stack).

A zip carrying only the supervisor publish output is a valid, internally
consistent, correctly checksummed zip -- and a completely broken server. The
supervisor comes up and supervises a game process that never loads a single
mod, which a player experiences as connecting and bouncing straight back out.

    python3 scripts/verify-server-bundle.py <bundle.zip>

Exit 0 only when the zip is a complete bundle. Any other outcome exits 1,
including anything this script cannot positively confirm.

Assert LAYOUT, not size and not a checksum. A bundle that is missing its whole
runtime tree can still be within a few percent of the correct byte count, and a
hash comparison between two copies of the wrong artifact passes happily.
"""

import argparse
import os
import sys
import zipfile

ROOT = "SolarpunkServer"
RT = ROOT + "/ue4ss-server"

# Every one of these must be present and non-empty.
REQUIRED_ENTRIES = (
    ROOT + "/SolarpunkServer.exe",
    ROOT + "/SolarpunkServer.dll",
    ROOT + "/SolarpunkServer.runtimeconfig.json",
    ROOT + "/appsettings.json",
    RT + "/UE4SS.dll",
    RT + "/dwmapi.dll",
    RT + "/UE4SS-settings.ini",
    RT + "/SolarpunkPlugin.dll",
    RT + "/Mods/mods.txt",
    RT + "/Mods/SolarpunkServerRuntime/Scripts/main.lua",
    RT + "/Mods/SolarpunkHost/Scripts/main.lua",
    RT + "/Mods/SolarpunkAuth/Scripts/main.lua",
    RT + "/Mods/SolarpunkRoster/Scripts/main.lua",
    RT + "/Mods/SolarpunkChat/Scripts/main.lua",
    RT + "/Mods/SolarpunkNoPhantomHost/Scripts/main.lua",
    RT + "/Mods/SolarpunkModKit/Scripts/main.lua",
    # The 5 PDB-derived AOB signatures are mandatory on UE5.7. Without them
    # UE4SS falls back to its built-in scanner and hangs at object construction.
    RT + "/UE4SS_Signatures/FName_Constructor.lua",
    RT + "/UE4SS_Signatures/GNatives.lua",
    RT + "/UE4SS_Signatures/GUObjectArray.lua",
    RT + "/UE4SS_Signatures/GUObjectHashTables.lua",
    RT + "/UE4SS_Signatures/StaticConstructObject.lua",
)

# UE4SS.dll is ~16 MB. A truncated or placeholder file is not a runtime.
MIN_UE4SS_DLL_BYTES = 1_000_000

# The native identity plugin is ~440 KB.
MIN_PLUGIN_BYTES = 50_000

# Seven server mod directories ship today.
MIN_MOD_DIRS = 7

# The self-contained supervisor publish output is ~350 files.
MIN_SUPERVISOR_ENTRIES = 300

# Publish output at the zip root is the signature of a supervisor-only artifact.
FLAT_ROOT_MARKERS = (
    "solarpunkserver.exe",
    "solarpunkserver.dll",
    "hostfxr.dll",
    "coreclr.dll",
)


def normalise(name):
    return name.replace("\\", "/").lstrip("./")


def enabled_mods(text):
    """Parse a UE4SS Mods/mods.txt -> the names with a trailing ': 1'."""
    names = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        name, _, state = line.partition(":")
        if state.strip() == "1":
            names.append(name.strip())
    return names


def verify(path):
    failures = []

    if not os.path.isfile(path):
        return ["not a file: {}".format(path)]

    try:
        zf = zipfile.ZipFile(path)
    except Exception as exc:  # noqa: BLE001 - fail closed on anything
        return ["cannot open as a zip: {}".format(exc)]

    with zf:
        bad = zf.testzip()
        if bad is not None:
            failures.append("corrupt entry: {}".format(bad))

        sizes = {}
        for info in zf.infolist():
            name = normalise(info.filename)
            if name.endswith("/"):
                continue
            sizes[name.lower()] = info.file_size

        for entry in REQUIRED_ENTRIES:
            key = entry.lower()
            if key not in sizes:
                failures.append("missing required entry: {}".format(entry))
            elif sizes[key] == 0:
                failures.append("required entry is empty: {}".format(entry))

        for marker in FLAT_ROOT_MARKERS:
            if marker in sizes:
                failures.append(
                    "'{}' sits at the zip root -- this is a bare publish output, "
                    "not the bundle (the supervisor belongs under {}/)".format(
                        marker, ROOT
                    )
                )

        dll = sizes.get((RT + "/UE4SS.dll").lower())
        if dll is not None and dll < MIN_UE4SS_DLL_BYTES:
            failures.append(
                "UE4SS.dll is {:,} bytes, below the {:,} byte floor".format(
                    dll, MIN_UE4SS_DLL_BYTES
                )
            )

        plugin = sizes.get((RT + "/SolarpunkPlugin.dll").lower())
        if plugin is not None and plugin < MIN_PLUGIN_BYTES:
            failures.append(
                "SolarpunkPlugin.dll is {:,} bytes, below the {:,} byte "
                "floor".format(plugin, MIN_PLUGIN_BYTES)
            )

        supervisor = [
            n for n in sizes
            if n.startswith(ROOT.lower() + "/") and not n.startswith(RT.lower() + "/")
        ]
        if len(supervisor) < MIN_SUPERVISOR_ENTRIES:
            failures.append(
                "only {} files under {}/ (expected at least {}) -- the supervisor "
                "publish output is incomplete".format(
                    len(supervisor), ROOT, MIN_SUPERVISOR_ENTRIES
                )
            )

        prefix = (RT + "/Mods/").lower()
        mod_dirs = set()
        for name in sizes:
            if name.startswith(prefix):
                rest = name[len(prefix):]
                if "/" in rest:
                    mod_dirs.add(rest.split("/", 1)[0])
        if len(mod_dirs) < MIN_MOD_DIRS:
            failures.append(
                "only {} mod directories under {}/Mods/ (expected at least {}): "
                "{}".format(len(mod_dirs), RT, MIN_MOD_DIRS, sorted(mod_dirs) or "none")
            )

        # Anything mods.txt switches on has to actually be in the zip, or UE4SS
        # boots with a mod list that references nothing. Only our own mods are
        # shipped here; the rest of the list is UE4SS built-ins.
        try:
            manifest = zf.read(RT + "/Mods/mods.txt").decode("utf-8-sig", "replace")
        except KeyError:
            manifest = None
        except Exception as exc:  # noqa: BLE001
            manifest = None
            failures.append("cannot read {}/Mods/mods.txt: {}".format(RT, exc))
        if manifest:
            for mod in enabled_mods(manifest):
                if not mod.lower().startswith("solarpunk"):
                    continue
                key = "{}/mods/{}/scripts/main.lua".format(RT.lower(), mod.lower())
                if key not in sizes:
                    failures.append(
                        "mods.txt enables '{}' but the zip has no "
                        "{}/Mods/{}/Scripts/main.lua".format(mod, RT, mod)
                    )

    return failures


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", help="path to the server bundle zip")
    args = parser.parse_args(argv)

    try:
        failures = verify(args.zip)
    except Exception as exc:  # noqa: BLE001 - never pass on an unexpected error
        print("FAIL {}: unexpected error: {}".format(args.zip, exc))
        return 1

    if failures:
        print("FAIL {} is not a complete Sundial server bundle:".format(args.zip))
        for line in failures:
            print("  - {}".format(line))
        print(
            "\nDo not publish or pin this artifact. The bundle carries the UE4SS "
            "runtime, the signatures, the native plugin and the server mods "
            "alongside the supervisor; without them the supervisor babysits a "
            "game process that players cannot stay connected to."
        )
        return 1

    print(
        "OK {} is a complete server bundle ({:,} bytes)".format(
            args.zip, os.path.getsize(args.zip)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
