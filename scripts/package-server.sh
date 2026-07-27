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
if [[ -f "$PLUGIN_DLL" ]]; then
  cp "$PLUGIN_DLL" "$RT/SolarpunkPlugin.dll"
  echo "    native plugin staged OK"
else
  echo "    !! SolarpunkPlugin.dll not found at $PLUGIN_DLL" >&2
  echo "    !! Bundle will be incomplete (the native identity hook will not load)." >&2
fi

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
  echo "    !! Bundle will be incomplete (mods will not load without UE4SS.dll + dwmapi.dll)." >&2
fi
[[ -f "$RT/UE4SS.dll" && -f "$RT/dwmapi.dll" ]] && echo "    runtime staged OK" || echo "    runtime MISSING (see above)"

echo "==> Zipping SundialServer-${TAG}.zip"
ZIP="$OUT/SundialServer-${TAG}.zip"; rm -f "$ZIP"
( cd "$STAGE" && zip -rq "$ZIP" SolarpunkServer )
SHA="$(openssl dgst -sha256 "$ZIP" | awk '{print $2}')"
echo
echo "==> $ZIP"
echo "    sha256 = $SHA"
echo "    attach it to the ${TAG} release and pin that sha wherever the bundle is verified"
