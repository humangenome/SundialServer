#!/usr/bin/env bash
# Build SolarpunkPlugin.dll (x64) with mingw-w64 + MinHook, from Linux.
#
# This is the toolchain the SHIPPED plugin was built with, and it is what the
# release workflow runs. Established by reading the published v0.1.68 bundle:
# its SolarpunkPlugin.dll carries mingw CRT symbols, an .edata export table GCC
# generates by default, and an msvcrt.dll import -- none of which MSVC produces.
# Rebuilding with this recipe reproduces that artifact at exactly its 445,820
# bytes, differing only in the fields a linker stamps per build.
#
# build.bat is the MSVC path for a Windows workstation. It compiles the same
# source and is checked in CI, but its output is ~200 KB with no export table,
# so the two are not interchangeable byte-for-byte. Ship this one.
#
# Usage: native/SolarpunkPlugin/build.sh
# Optional: MINHOOK_COMMIT=<sha> to pin the MinHook revision (recommended; the
# release workflow always sets it).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CXX="${CXX:-x86_64-w64-mingw32-g++}"
MH="$HERE/minhook"
OUT="$HERE/build"

if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "!! $CXX not found. On Debian/Ubuntu: apt-get install g++-mingw-w64-x86-64" >&2
  exit 1
fi

if [[ ! -f "$MH/src/hook.c" ]]; then
  echo "==> Fetching MinHook"
  if [[ -n "${MINHOOK_COMMIT:-}" ]]; then
    mkdir -p "$MH"
    git -C "$MH" init -q
    git -C "$MH" remote add origin https://github.com/TsudaKageyu/minhook.git 2>/dev/null || true
    git -C "$MH" fetch -q --depth 1 origin "$MINHOOK_COMMIT"
    git -C "$MH" checkout -q FETCH_HEAD
  else
    git clone -q --depth 1 https://github.com/TsudaKageyu/minhook.git "$MH"
  fi
fi
if [[ -n "${MINHOOK_COMMIT:-}" ]]; then
  have="$(git -C "$MH" rev-parse HEAD)"
  if [[ "$have" != "$MINHOOK_COMMIT" ]]; then
    echo "!! MinHook is at $have, pinned $MINHOOK_COMMIT" >&2
    exit 1
  fi
  echo "    MinHook pinned at $have"
fi

mkdir -p "$OUT"
echo "==> Compiling SolarpunkPlugin.dll"
"$CXX" -O2 -std=c++17 -shared -static \
  -I "$MH/include" \
  "$HERE/src/dllmain.cpp" \
  "$MH/src/hook.c" "$MH/src/buffer.c" "$MH/src/trampoline.c" "$MH/src/hde/hde64.c" \
  -o "$OUT/SolarpunkPlugin.dll" \
  -lpsapi

echo "    $OUT/SolarpunkPlugin.dll  $(stat -c%s "$OUT/SolarpunkPlugin.dll") bytes"
echo "    sha256 = $(sha256sum "$OUT/SolarpunkPlugin.dll" | awk '{print $1}')"
