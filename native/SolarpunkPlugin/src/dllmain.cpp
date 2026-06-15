// SolarpunkPlugin (Beacon.dll analog) — CLIENT-side stable net identity for headless co-op.
//
// ROLE (post-investigation 2026-06-09): give the OSS=Null client a valid, stable Steam-shaped
// FUniqueNetId via ULocalPlayer::GetPreferredUniqueNetId. Empirically this also makes the client's
// `?Name=<char>` option stick on the server (without it, the engine fabricates a random per-session
// machine name, so the player name — and therefore any name-derived save key — changes every join).
// A stable player name is what the HOST mod (server-mods/host_netid_enforcer.lua) needs: it derives
// the per-player save AND load key from GetPlayerName, so persistence requires the name to be stable
// across reconnects. In production the launcher passes a fixed ?Name=<character> and injects this DLL.
//
// WHAT THIS PLUGIN IS *NOT* FOR (proven dead end — do not re-add):
//   The server's BeginLoadData load key is a Blueprint FString PARAM that the join chain hardcodes to
//   "TESTING UID"; it is NOT read from APlayerState::UniqueId. A native write to PlayerState->UniqueId
//   lands and persists but the load path ignores it. The load-key fix lives entirely in the host Lua
//   mod (it re-issues BeginLoadData(synth) so the per-player key lands last). See IMPLEMENTATION-SPEC.md.
//
// Targets are AOB-scanned at load (RVAs shift per game patch). Patterns derived from the shipped PDB
// of build SolarpunkSteam-Win64-Shipping. Build: MSVC (x64) + MinHook (see build.bat).
//
// Load note: UE4SS unloads non-SDK DLLs, so inject this AFTER the game is up (tools/inject-plugin-all.ps1),
// keep it DISABLED in UE4SS mods.txt. Diagnostics go to C:\Users\Public\sp-plugin.log.

#include <windows.h>
#include <psapi.h>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cwchar>
#include "MinHook.h"

// ----------------------------------------------------------------------------
// Minimal UE type shims (x64, UE 5.7 layout)
// ----------------------------------------------------------------------------
struct FString {            // wraps TArray<TCHAR>
    wchar_t* Data;
    int32_t  Num;           // includes null terminator
    int32_t  Max;
};
struct FSharedPtr {         // TSharedPtr<const FUniqueNetId>
    void* Object;
    void* RefController;
};

// ----------------------------------------------------------------------------
// Resolved function signatures (x64 MSVC ABI). Struct-by-value returns use an
// sret hidden pointer in RDX (after RCX=this).
// ----------------------------------------------------------------------------
// TSharedPtr<const FUniqueNetId> FOnlineIdentitySteam::CreateUniquePlayerId(const FString&)
typedef void* (__fastcall* CreateSteamId_t)(void* self, FSharedPtr* retShared, const FString* str);
// void FUniqueNetIdRepl::SetUniqueNetId(const TSharedPtr<const FUniqueNetId>&)
typedef void  (__fastcall* SetUniqueNetId_t)(void* self, const FSharedPtr* shared);
// FUniqueNetIdRepl ULocalPlayer::GetPreferredUniqueNetId() const  (sret return)
typedef void* (__fastcall* GetPreferredId_t)(void* self, void* sretRepl);

static CreateSteamId_t   g_createSteamId      = nullptr;
static SetUniqueNetId_t  g_setUniqueNetId     = nullptr;
static GetPreferredId_t  g_origGetPreferred   = nullptr;

// ----------------------------------------------------------------------------
// AOB scan over the main module's .text (PDB-derived, see IMPLEMENTATION-SPEC.md)
// ----------------------------------------------------------------------------
static const char* AOB_CreateSteamId =
    "48 89 5C 24 08 48 89 74 24 18 57 48 83 EC 30 B9";
static const char* AOB_SetUniqueNetId =
    "48 89 5C 24 08 57 48 83 EC 30 4C 8D 49 20 48 8B FA 49 8D 41 0C 41 C7 41 08 00 00 00 00";
static const char* AOB_GetPreferredId =
    "48 89 5C 24 18 56 57 41 56 48 83 EC 60 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 44 24 50 48 8B DA 48";

static bool match_at(const uint8_t* p, const char* pat) {
    while (*pat) {
        if (*pat == ' ') { ++pat; continue; }
        if (pat[0] == '?' ) { pat += (pat[1]=='?'?2:1); ++p; continue; }
        int hi = (pat[0]<='9'?pat[0]-'0':(pat[0]|0x20)-'a'+10);
        int lo = (pat[1]<='9'?pat[1]-'0':(pat[1]|0x20)-'a'+10);
        if (*p != (uint8_t)((hi<<4)|lo)) return false;
        p += 1; pat += 2;
    }
    return true;
}
static uint8_t* aob_scan(const char* pat) {
    MODULEINFO mi{}; HMODULE h = GetModuleHandleW(nullptr);
    GetModuleInformation(GetCurrentProcess(), h, &mi, sizeof(mi));
    uint8_t* base = (uint8_t*)mi.lpBaseOfDll;
    size_t size = mi.SizeOfImage;
    for (size_t i = 0; i + 64 < size; ++i)
        if (match_at(base + i, pat)) return base + i;
    return nullptr;
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------
static uint32_t crc32(const wchar_t* s) {
    uint32_t c = 0xFFFFFFFFu;
    for (; s && *s; ++s) {
        c ^= (uint32_t)towlower(*s);
        for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int)(c & 1)));
    }
    return ~c;
}

static void plog(const char* fmt, ...) {
    FILE* f = nullptr; fopen_s(&f, "C:\\Users\\Public\\sp-plugin.log", "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); fclose(f);
}

// Synthetic id string. Same shape the host Lua keys off (765611900 + 9-digit crc) so any consumer
// that round-trips this id stays in the documented key space.
static void synth_str(const wchar_t* seed, wchar_t* out, int outLen) {
    swprintf(out, outLen, L"765611900%09u", (unsigned)(crc32(seed) % 1000000000u));
}
// Mint a Steam-typed FUniqueNetId from the synthetic id string. CreateUniquePlayerId only parses the
// string, so a dummy `this` is safe with no live Steam OSS. out->Object non-null on success.
static bool mint_from_str(const wchar_t* idstr, FSharedPtr* out) {
    if (!g_createSteamId) return false;
    int32_t n = (int32_t)(wcslen(idstr) + 1);
    FString idStr{ (wchar_t*)idstr, n, n };
    uint8_t dummyThis[64] = {0};
    out->Object = nullptr; out->RefController = nullptr;
    g_createSteamId(dummyThis, out, &idStr);
    return out->Object != nullptr;
}

static bool read_identity_file(wchar_t* idstr, int idLen, wchar_t* seed, int seedLen) {
    wchar_t appdata[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;

    wchar_t path[MAX_PATH];
    swprintf(path, MAX_PATH, L"%ls\\Solarpunk\\client-identity.txt", appdata);
    FILE* f = nullptr;
    if (_wfopen_s(&f, path, L"rb") != 0 || !f) return false;

    char buf[256] = {0};
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (got == 0) return false;
    buf[got] = 0;

    char steam[40] = {0};
    char hash[32] = {0};
    if (sscanf(buf, "STEAM %39[0-9] %31[0-9A-Fa-f]", steam, hash) < 1)
        return false;
    size_t len = strlen(steam);
    if (len < 17 || len >= (size_t)idLen) return false;
    for (size_t i = 0; i < len; ++i) {
        if (steam[i] < '0' || steam[i] > '9') return false;
        idstr[i] = (wchar_t)steam[i];
    }
    idstr[len] = 0;
    const wchar_t* prefix = L"client-identity:";
    wcsncpy_s(seed, seedLen, prefix, _TRUNCATE);
    size_t off = wcslen(seed);
    const char* h = hash[0] ? hash : "nohash";
    for (size_t i = 0; h[i] && off + i + 1 < (size_t)seedLen; ++i)
        seed[off + i] = (wchar_t)h[i];
    seed[seedLen - 1] = 0;
    return true;
}

// CLIENT-side: the local player's preferred id is what gets SENT in the NMT_Login handshake. Call the
// original (constructs the repl in sret), then replace its inner id with the launcher-written
// per-character identity. Falling back to the machine name is only for diagnostics/manual dev launches;
// the launcher requires this hook to load before it writes the connect target.
static void* __fastcall hk_GetPreferredUniqueNetId(void* self, void* sretRepl) {
    void* r = g_origGetPreferred(self, sretRepl);
    wchar_t seed[180] = L"";
    wchar_t idstr[32] = L"";
    bool fromIdentity = read_identity_file(idstr, 32, seed, 180);
    if (!fromIdentity) {
        wchar_t comp[160]; DWORD n = 160;
        if (!GetComputerNameW(comp, &n)) wcscpy_s(comp, L"sp-machine");
        synth_str(comp, idstr, 32);
        swprintf(seed, 180, L"fallback-machine:%ls", comp);
    }
    FSharedPtr shared{ nullptr, nullptr };
    if (g_setUniqueNetId && mint_from_str(idstr, &shared)) {
        g_setUniqueNetId(sretRepl, &shared);
        plog("GetPreferredUniqueNetId -> injected id=%ls (seed=%ls identity=%d)\n",
             idstr, seed, fromIdentity ? 1 : 0);
    }
    return r;
}

// ----------------------------------------------------------------------------
// Bootstrap (worker thread so the game module is fully mapped)
// ----------------------------------------------------------------------------
static DWORD WINAPI Init(LPVOID) {
    if (MH_Initialize() != MH_OK) return 0;
    g_createSteamId  = (CreateSteamId_t)aob_scan(AOB_CreateSteamId);
    g_setUniqueNetId = (SetUniqueNetId_t)aob_scan(AOB_SetUniqueNetId);
    uint8_t* pGetPref = aob_scan(AOB_GetPreferredId);
    if (!g_createSteamId || !g_setUniqueNetId || !pGetPref) {
        plog("SolarpunkPlugin scan failed: create=%p set=%p getpref=%p\n",
             g_createSteamId, g_setUniqueNetId, pGetPref);
        return 0;
    }
    if (MH_CreateHook(pGetPref, (LPVOID)&hk_GetPreferredUniqueNetId, (LPVOID*)&g_origGetPreferred) == MH_OK) {
        MH_EnableHook(pGetPref);
        plog("hook installed: GetPreferredUniqueNetId=%p create=%p set=%p\n",
             pGetPref, g_createSteamId, g_setUniqueNetId);
    } else {
        plog("GetPreferredUniqueNetId hook failed\n");
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) CreateThread(nullptr, 0, Init, nullptr, 0, nullptr);
    return TRUE;
}
