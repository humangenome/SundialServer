#!/usr/bin/env bash
# Cross-compile SolarpunkEosIdentity.dll with mingw-w64.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
x86_64-w64-mingw32-gcc -O2 -Wall -shared -o "$here/SolarpunkEosIdentity.dll" "$here/solarpunk_eos_identity.c" -ladvapi32 -static-libgcc
sha256sum "$here/SolarpunkEosIdentity.dll"
