# In-game runtime

Everything the game process needs so a headless host loads the Sundial server
mod stack. The supervisor launches the game; it does **not** stage this folder
for you. Copy the assembled contents into `<GameInstallRoot>\Solarpunk\Binaries\Win64\`.

`scripts/package-server.sh` assembles this tree plus the Lua mods from
`../server-mods/` into the `ue4ss-server\` folder that ships inside the release
zip, so a released bundle already has everything.

## Layout
- `UE4SS-settings.ini` — engine version override plus the PDB-derived signature
  scan. UE4SS's built-in scanner does not resolve correctly on this engine
  version, so these overrides are required.
- `UE4SS_Signatures/` — five PDB-derived AOB patterns (`FName_Constructor`,
  `GNatives`, `GUObjectArray`, `GUObjectHashTables`, `StaticConstructObject`).
  Re-verify them after every game update with `scripts/verify-signatures.py`.
- `Mods/mods.txt` — enables only `SolarpunkServerRuntime`, which loads the
  feature mods in order. Do not enable the feature mods directly; see
  [docs/MODS.md](../docs/MODS.md).

## Not tracked here
`UE4SS.dll` and `dwmapi.dll` are the upstream UE4SS runtime binaries and
`SolarpunkPlugin.dll` is built from `native/SolarpunkPlugin/`. The packaging
script stages all three into the release bundle.
