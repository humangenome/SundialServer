#!/usr/bin/env bash
# Package the Sundial headless-server bundle.
#
# Produces SundialServer-<tag>.zip = the .NET supervisor (self-contained
# win-x64) plus the in-game runtime under ue4ss-server\ (UE4SS settings, the
# PDB-derived signatures, the Solarpunk server mod stack, the native plugin and
# the pinned UE4SS runtime binaries). The sha256 it prints is the value to pin
# wherever your deployment verifies the bundle.
#
# Usage: scripts/package-server.sh v0.1.0
#
# This script FAILS CLOSED. It used to print "runtime MISSING" and then exit 0,
# zip anyway, and print a clean sha ready to pin — a build that knew it was
# incomplete and reported success. Every incomplete-bundle path now exits 1, and
# the finished zip is checked against scripts/verify-server-bundle.py before the
# sha is printed.
#
# UE4SS runtime binaries are not in this repo. Set UE4SS_RUNTIME_DIR to a folder
# containing UE4SS.dll + dwmapi.dll, or UE4SS_ZIP_URL to fetch and unzip one.
set -euo pipefail
TAG="${1:-}"; [[ -z "$TAG" ]] && { echo "usage: $0 <git tag e.g. v0.1.0>" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/dist"; STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"

SRC_VERSION="$(sed -n 's/.*<Version>\(.*\)<\/Version>.*/\1/p' "$HERE/Directory.Build.props" | head -1)"
if [[ "v$SRC_VERSION" != "$TAG" ]]; then
  echo "!! Directory.Build.props is $SRC_VERSION but the tag is $TAG." >&2
  echo "!! Bump the source version in the same commit as the tag." >&2
  exit 1
fi

echo "==> Publishing SolarpunkServer (.NET 8, self-contained win-x64)"
dotnet publish "$HERE/SolarpunkServer/SolarpunkServer.csproj" \
  -c Release -r win-x64 --self-contained -o "$STAGE/SolarpunkServer" --nologo >/dev/null

echo "==> Staging the in-game runtime (settings + signatures + mods)"
RT="$STAGE/SolarpunkServer/ue4ss-server"
mkdir -p "$RT/Mods"
cp "$HERE/runtime/UE4SS-settings.ini" "$RT/"
cp -r "$HERE/runtime/UE4SS_Signatures" "$RT/"
cp "$HERE/runtime/Mods/mods.txt" "$RT/Mods/"
for mod in "$HERE"/server-mods/*/; do
  name="$(basename "$mod")"
  mkdir -p "$RT/Mods/$name/Scripts"
  cp "$mod/Scripts/main.lua" "$RT/Mods/$name/Scripts/"
done
echo "    $(find "$RT/Mods" -name main.lua | wc -l) mod script(s) staged"

PLUGIN_DLL="$HERE/native/SolarpunkPlugin/build/SolarpunkPlugin.dll"
if [[ ! -f "$PLUGIN_DLL" ]]; then
  echo "    !! SolarpunkPlugin.dll not found at $PLUGIN_DLL" >&2
  echo "    !! Build it before packaging - the native identity hook will not load." >&2
  exit 1
fi
cp "$PLUGIN_DLL" "$RT/SolarpunkPlugin.dll"
echo "    native plugin staged OK"

echo "==> Staging UE4SS runtime binaries (UE4SS.dll + dwmapi.dll)"
if [[ -n "${UE4SS_RUNTIME_DIR:-}" ]]; then
  cp "$UE4SS_RUNTIME_DIR/UE4SS.dll" "$UE4SS_RUNTIME_DIR/dwmapi.dll" "$RT/"
elif [[ -n "${UE4SS_ZIP_URL:-}" ]]; then
  curl -fsSL "$UE4SS_ZIP_URL" -o "$STAGE/ue4ss.zip"
  unzip -oq "$STAGE/ue4ss.zip" UE4SS.dll dwmapi.dll -d "$RT/" || \
    unzip -oq "$STAGE/ue4ss.zip" -d "$STAGE/ue4ss-rt" && \
    cp "$STAGE"/ue4ss-rt/**/UE4SS.dll "$STAGE"/ue4ss-rt/**/dwmapi.dll "$RT/" 2>/dev/null || true
else
  echo "    !! UE4SS runtime not provided — set UE4SS_RUNTIME_DIR or UE4SS_ZIP_URL." >&2
  exit 1
fi
if [[ ! -f "$RT/UE4SS.dll" || ! -f "$RT/dwmapi.dll" ]]; then
  echo "    !! runtime MISSING — UE4SS.dll and dwmapi.dll are not both in $RT" >&2
  echo "    !! Without them no mod loads, so the supervisor babysits a game" >&2
  echo "    !! process players cannot stay connected to. Refusing to package." >&2
  exit 1
fi
echo "    runtime staged OK"

echo "==> Zipping SundialServer-${TAG}.zip"
ZIP="$OUT/SundialServer-${TAG}.zip"; rm -f "$ZIP"
( cd "$STAGE" && zip -rq "$ZIP" SolarpunkServer )

# Last gate before anything is published or pinned. Every check above looks at
# the staging tree; this one reads the artifact that actually ships. A zip that
# is missing its runtime is internally consistent and correctly checksummed, so
# the sha printed below cannot tell you anything about whether it works.
echo "==> Verifying the bundle layout"
python3 "$HERE/scripts/verify-server-bundle.py" "$ZIP"

SHA="$(openssl dgst -sha256 "$ZIP" | awk '{print $2}')"
echo
echo "==> $ZIP"
echo "    sha256 = $SHA"
echo "    attach it to the ${TAG} release and pin that sha wherever the bundle is verified"
