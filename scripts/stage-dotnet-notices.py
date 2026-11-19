#!/usr/bin/env python3
"""Put the .NET runtime's licence and third-party notices beside a self-contained program.

A self-contained publish copies the .NET runtime (and, for a web host, ASP.NET Core) into the program's
folder, so every copy we ship carries Microsoft's MIT licence and its third-party notices. The texts
come from the runtime packs the program was published with, read from its .deps.json, so they always
match the runtime that ships:

    dotnet-LICENSE.txt                   dotnet-THIRD-PARTY-NOTICES.txt       (Microsoft.NETCore.App)
    aspnetcore-LICENSE.txt (10.0 on)     aspnetcore-THIRD-PARTY-NOTICES.txt   (Microsoft.AspNetCore.App)
    windowsdesktop-LICENSE.txt                                                (Microsoft.WindowsDesktop.App)

Usage:
    python scripts/stage-dotnet-notices.py <publish folder> [<publish folder> ...]

The NuGet package folder is $NUGET_PACKAGES, else what `dotnet nuget locals global-packages --list`
prints, else ~/.nuget/packages. Exit 0 = staged, 1 = a folder is not a self-contained publish or a
pack's licence text is missing, 2 = usage.
"""

import glob
import json
import os
import shutil
import subprocess
import sys

# Runtime pack -> (short name, licence file required, notices file required)
PACKS = {
    "microsoft.netcore.app.runtime": ("dotnet", True, True),
    # ASP.NET Core's runtime pack carried no licence file of its own before 10.0 (the same .NET
    # Foundation MIT text as dotnet-LICENSE.txt); its notices are always there.
    "microsoft.aspnetcore.app.runtime": ("aspnetcore", False, True),
    "microsoft.windowsdesktop.app.runtime": ("windowsdesktop", True, False),
}
LICENCE_NAMES = ("LICENSE.TXT", "LICENSE.txt", "LICENSE")
NOTICE_NAMES = ("THIRD-PARTY-NOTICES.TXT", "THIRD-PARTY-NOTICES.txt", "ThirdPartyNotices.txt")


def packages_root():
    env = os.environ.get("NUGET_PACKAGES")
    if env:
        return env
    try:
        out = subprocess.run(["dotnet", "nuget", "locals", "global-packages", "--list"],
                             capture_output=True, text=True, timeout=120).stdout
        for line in out.splitlines():
            if line.strip().lower().startswith("global-packages:"):
                return line.split(":", 1)[1].strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.join(os.path.expanduser("~"), ".nuget", "packages")


def runtime_packs(folder):
    """(pack id, version) for every runtime pack named in the folder's .deps.json files."""
    found = set()
    for deps in glob.glob(os.path.join(folder, "*.deps.json")):
        with open(deps, encoding="utf-8-sig") as f:
            data = json.load(f)
        for key, lib in data.get("libraries", {}).items():
            if lib.get("type") != "runtimepack":
                continue
            name, _, version = key.partition("/")
            if name.lower().startswith("runtimepack."):
                name = name[len("runtimepack."):]
            found.add((name, version))
    return sorted(found)


def first(folder, names):
    for n in names:
        p = os.path.join(folder, n)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p
    return None


def stage(folder, root):
    problems, staged = [], []
    packs = runtime_packs(folder)
    if not any(n.lower().startswith("microsoft.netcore.app.runtime.") for n, _ in packs):
        return ["%s: no .deps.json names the .NET runtime pack, so this is not a self-contained publish" % folder], staged
    for name, version in packs:
        lower = name.lower()
        base = next((k for k in PACKS if lower.startswith(k + ".")), None)
        if base is None:
            problems.append("%s: runtime pack %s/%s is not one this script knows; add its notices here" % (folder, name, version))
            continue
        short, need_licence, need_notice = PACKS[base]
        pack_dir = os.path.join(root, lower, version)
        if not os.path.isdir(pack_dir):
            problems.append("%s: runtime pack %s/%s is not in %s" % (folder, name, version, root))
            continue
        for names, need, out in ((LICENCE_NAMES, need_licence, short + "-LICENSE.txt"),
                                 (NOTICE_NAMES, need_notice, short + "-THIRD-PARTY-NOTICES.txt")):
            src = first(pack_dir, names)
            if src is None:
                if need:
                    problems.append("%s: %s/%s carries no %s" % (folder, name, version, names[0]))
                continue
            shutil.copyfile(src, os.path.join(folder, out))
            staged.append("%s (%s/%s)" % (out, name, version))
    return problems, staged


def main(argv):
    if len(argv) < 2:
        print("usage: python scripts/stage-dotnet-notices.py <publish folder> [<publish folder> ...]", file=sys.stderr)
        return 2
    root = packages_root()
    bad = False
    for folder in argv[1:]:
        if not os.path.isdir(folder):
            print("stage-dotnet-notices: not a folder: %s" % folder, file=sys.stderr)
            bad = True
            continue
        problems, staged = stage(folder, root)
        for p in problems:
            print("stage-dotnet-notices: %s" % p, file=sys.stderr)
        bad = bad or bool(problems)
        if staged:
            print("stage-dotnet-notices: %s <- %s" % (folder, ", ".join(staged)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
