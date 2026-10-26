// SolarpunkEosIdentity - one Epic device identity per Solarpunk server process.
//
// Solarpunk 1.3.0 signs in to Epic Online Services through Redpoint EOS. A headless host
// signs in with an EOS
// Connect device id. The EOS SDK keeps that device credential in the Windows Credential
// Manager, which is per Windows user: every server under one account would share one Epic
// identity and one peer-to-peer address, and a process started from a service or a key-only
// remote logon has no credential vault at all.
//
// This DLL re-points the SDK's four advapi32 credential imports (CredReadW, CredWriteW,
// CredDeleteW, CredFree) at one file per server: the path in SP_EOS_IDENTITY_FILE when the
// launcher sets it, else <UserDir>\ss_eos_identity.cred (UserDir = the game's -UserDir=
// argument). Nothing in the engine is patched. The SDK only reads back what it wrote, so the
// file holds the CREDENTIALW fields verbatim.
//
// Redpoint signs in about 3 s after the game starts, before UE4SS mods load, so this DLL is
// injected right after the process starts. Its thread waits for EOSSDK-Win64-Shipping.dll and
// re-points the imports the moment the module appears. The file holds a secret: keep it with
// the server's private files and never ship it.
#include <windows.h>
#include <wincred.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

static char g_dir[MAX_PATH];
static char g_fallbackLog[MAX_PATH] = "solarpunk_eos_identity.log";
static char g_logPath[MAX_PATH];
static char g_identityFile[MAX_PATH];
static void* g_blocks[32];
static int g_armed;

static void L(const char* fmt, ...) {
    FILE* f = fopen(g_logPath[0] ? g_logPath : g_fallbackLog, "a"); if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d.%03d [%lu] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, (unsigned long)GetCurrentThreadId());
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); fputc('\n', f); fclose(f);
}

static int wr_u32(FILE* f, uint32_t v) { return fwrite(&v, 4, 1, f) == 1; }
static int wr_wstr(FILE* f, LPCWSTR w) { uint32_t n = w ? (uint32_t)wcslen(w) : 0xFFFFFFFFu; if (!wr_u32(f, n)) return 0; return n == 0xFFFFFFFFu || n == 0 || fwrite(w, 2, n, f) == n; }

static BOOL WINAPI my_CredWriteW(PCREDENTIALW c, DWORD Flags) {
    (void)Flags;
    if (!c) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
    char tmp[MAX_PATH]; snprintf(tmp, sizeof tmp, "%s.tmp", g_identityFile);
    FILE* f = fopen(tmp, "wb");
    if (!f) { L("identity write FAILED: cannot open %s", tmp); SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    int ok = wr_u32(f, 0x53534531u) && wr_u32(f, c->Flags) && wr_u32(f, c->Type) && wr_u32(f, c->Persist)
        && wr_wstr(f, c->TargetName) && wr_wstr(f, c->Comment) && wr_wstr(f, c->TargetAlias) && wr_wstr(f, c->UserName)
        && wr_u32(f, c->CredentialBlobSize) && (c->CredentialBlobSize == 0 || fwrite(c->CredentialBlob, 1, c->CredentialBlobSize, f) == c->CredentialBlobSize)
        && wr_u32(f, c->AttributeCount);
    for (DWORD i = 0; ok && i < c->AttributeCount; i++) {
        PCREDENTIAL_ATTRIBUTEW a = &c->Attributes[i];
        ok = wr_wstr(f, a->Keyword) && wr_u32(f, a->Flags) && wr_u32(f, a->ValueSize) && (a->ValueSize == 0 || fwrite(a->Value, 1, a->ValueSize, f) == a->ValueSize);
    }
    fclose(f);
    if (!ok || !MoveFileExA(tmp, g_identityFile, MOVEFILE_REPLACE_EXISTING)) { L("identity write FAILED (ok=%d err %lu)", ok, (unsigned long)GetLastError()); DeleteFileA(tmp); SetLastError(ERROR_WRITE_FAULT); return FALSE; }
    L("identity written: %s ('%ls', %lu-byte secret)", g_identityFile, c->TargetName ? c->TargetName : L"?", (unsigned long)c->CredentialBlobSize);
    SetLastError(0); return TRUE;
}

static BOOL WINAPI my_CredReadW(LPCWSTR TargetName, DWORD Type, DWORD Flags, PCREDENTIALW* out) {
    (void)Type; (void)Flags;
    if (!out) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
    FILE* f = fopen(g_identityFile, "rb");
    if (!f) { L("identity read '%ls': none yet (a new device identity will be minted)", TargetName ? TargetName : L"?"); SetLastError(ERROR_NOT_FOUND); return FALSE; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    if (len < 16 || len > (1 << 20)) { fclose(f); L("identity read: bad size %ld", len); SetLastError(ERROR_NOT_FOUND); return FALSE; }
    unsigned char* buf = (unsigned char*)malloc((size_t)len);
    if (!buf || fread(buf, 1, (size_t)len, f) != (size_t)len) { fclose(f); free(buf); SetLastError(ERROR_NOT_FOUND); return FALSE; }
    fclose(f);
    unsigned char* block = (unsigned char*)calloc(1, sizeof(CREDENTIALW) + 64 * sizeof(CREDENTIAL_ATTRIBUTEW) + (size_t)len * 2 + 64);
    if (!block) { free(buf); SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE; }
    PCREDENTIALW c = (PCREDENTIALW)block; unsigned char* heap = block + sizeof(CREDENTIALW) + 64 * sizeof(CREDENTIAL_ATTRIBUTEW);
    unsigned char* p = buf; unsigned char* e = buf + len; int bad = 0; uint32_t u;
    #define RD32(v) do { if (p + 4 > e) { bad = 1; v = 0; } else { memcpy(&v, p, 4); p += 4; } } while (0)
    #define RDW(dst) do { uint32_t n_; RD32(n_); if (n_ == 0xFFFFFFFFu) dst = NULL; else if (bad || p + (size_t)n_ * 2 > e) { bad = 1; dst = NULL; } else { memcpy(heap, p, (size_t)n_ * 2); ((wchar_t*)heap)[n_] = 0; dst = (LPWSTR)heap; heap += ((size_t)n_ + 1) * 2; p += (size_t)n_ * 2; } } while (0)
    #define RDB(dst, n) do { if (bad || p + (n) > e) { bad = 1; dst = NULL; } else { memcpy(heap, p, (n)); dst = heap; heap += (n) + 1; p += (n); } } while (0)
    RD32(u); if (u != 0x53534531u) bad = 1;
    RD32(u); c->Flags = u; RD32(u); c->Type = u; RD32(u); c->Persist = u;
    RDW(c->TargetName); RDW(c->Comment); RDW(c->TargetAlias); RDW(c->UserName);
    RD32(u); c->CredentialBlobSize = u; if (u) RDB(c->CredentialBlob, u);
    RD32(u); c->AttributeCount = u > 64 ? 0 : u; c->Attributes = (PCREDENTIAL_ATTRIBUTEW)(block + sizeof(CREDENTIALW));
    for (DWORD i = 0; !bad && i < c->AttributeCount; i++) { PCREDENTIAL_ATTRIBUTEW a = &c->Attributes[i]; RDW(a->Keyword); RD32(u); a->Flags = u; RD32(u); a->ValueSize = u; if (u) RDB(a->Value, u); }
    #undef RD32
    #undef RDW
    #undef RDB
    free(buf);
    if (bad) { free(block); L("identity read: %s is corrupt; minting a new identity", g_identityFile); SetLastError(ERROR_NOT_FOUND); return FALSE; }
    for (int i = 0; i < 32; i++) if (!g_blocks[i]) { g_blocks[i] = block; break; }
    L("identity read '%ls': %s (%lu-byte secret)", TargetName ? TargetName : L"?", g_identityFile, (unsigned long)c->CredentialBlobSize);
    *out = c; SetLastError(0); return TRUE;
}

static BOOL WINAPI my_CredDeleteW(LPCWSTR TargetName, DWORD Type, DWORD Flags) {
    (void)TargetName; (void)Type; (void)Flags;
    BOOL ok = DeleteFileA(g_identityFile); L("identity delete -> %s", ok ? "deleted" : "absent");
    if (!ok) { SetLastError(ERROR_NOT_FOUND); return FALSE; }
    SetLastError(0); return TRUE;
}

static VOID WINAPI my_CredFree(PVOID b) {
    for (int i = 0; i < 32; i++) if (g_blocks[i] == b) { g_blocks[i] = NULL; free(b); return; }
    CredFree(b);
}

static void* patch_import(HMODULE mod, const char* fn, void* repl) {
    unsigned char* base = (unsigned char*)mod;
    IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return NULL;
    for (IMAGE_IMPORT_DESCRIPTOR* d = (IMAGE_IMPORT_DESCRIPTOR*)(base + dir.VirtualAddress); d->Name; d++) {
        if (!d->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA* nm = (IMAGE_THUNK_DATA*)(base + d->OriginalFirstThunk);
        IMAGE_THUNK_DATA* iat = (IMAGE_THUNK_DATA*)(base + d->FirstThunk);
        for (; nm->u1.AddressOfData; nm++, iat++) {
            if (nm->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
            if (strcmp((const char*)((IMAGE_IMPORT_BY_NAME*)(base + nm->u1.AddressOfData))->Name, fn)) continue;
            void* orig = (void*)iat->u1.Function; DWORD old;
            if (!VirtualProtect(&iat->u1.Function, sizeof(void*), PAGE_READWRITE, &old)) return NULL;
            iat->u1.Function = (ULONGLONG)repl; VirtualProtect(&iat->u1.Function, sizeof(void*), old, &old);
            return orig;
        }
    }
    return NULL;
}

// -UserDir="C:\x\y" or -UserDir=C:\x\y from the command line
static int userdir_from_cmdline(char* out, size_t cap) {
    const char* cl = GetCommandLineA(); const char* k = strstr(cl, "-UserDir=");
    if (!k) k = strstr(cl, "-userdir=");
    if (!k) return 0;
    k += 9; size_t n = 0;
    if (*k == '"') { k++; while (k[n] && k[n] != '"') n++; } else { while (k[n] && k[n] != ' ') n++; }
    if (!n || n >= cap) return 0;
    memcpy(out, k, n); out[n] = 0; while (n && (out[n - 1] == '\\' || out[n - 1] == '/')) out[--n] = 0;
    return 1;
}

static int arm(void) {
    if (g_armed) return 1;
    if (!g_dir[0] && !userdir_from_cmdline(g_dir, sizeof g_dir)) { DWORD n_ = GetTempPathA(sizeof g_dir, g_dir); if (n_ && n_ < sizeof g_dir && g_dir[n_ - 1] == '\\') g_dir[n_ - 1] = 0; };
    snprintf(g_logPath, sizeof g_logPath, "%s\\ss_eos.log", g_dir);
    snprintf(g_identityFile, sizeof g_identityFile, "%s\\ss_eos_identity.cred", g_dir);
    {   // The launcher may keep the credential outside the server's own folder.
        char envFile[MAX_PATH]; DWORD n = GetEnvironmentVariableA("SP_EOS_IDENTITY_FILE", envFile, sizeof envFile);
        if (n > 0 && n < sizeof envFile) snprintf(g_identityFile, sizeof g_identityFile, "%s", envFile);
    }
    HMODULE sdk = GetModuleHandleA("EOSSDK-Win64-Shipping.dll");
    if (!sdk) return 0;
    void* r = patch_import(sdk, "CredReadW", (void*)my_CredReadW);
    void* w = patch_import(sdk, "CredWriteW", (void*)my_CredWriteW);
    void* d = patch_import(sdk, "CredDeleteW", (void*)my_CredDeleteW);
    void* f = patch_import(sdk, "CredFree", (void*)my_CredFree);
    if (!r || !w || !d) { L("REFUSED: SDK credential imports not found (read %p write %p delete %p)", r, w, d); return 0; }
    g_armed = 1;
    L("armed: SDK credential store -> %s (CredFree %s)", g_identityFile, f ? "hooked" : "not imported");
    return 1;
}

static DWORD WINAPI watcher(LPVOID p) {
    (void)p;
    DWORD t0 = GetTickCount();
    for (;;) {
        if (arm()) { L("armed %lu ms after inject", (unsigned long)(GetTickCount() - t0)); return 0; }
        if (g_dir[0] && GetModuleHandleA("EOSSDK-Win64-Shipping.dll")) { if (arm()) { L("armed %lu ms after inject", (unsigned long)(GetTickCount() - t0)); return 0; } L("SDK loaded but arm refused; giving up"); return 1; }
        if (GetTickCount() - t0 > 120000) { L("gave up: EOS SDK never loaded in 120 s"); return 1; }
        Sleep(1);
    }
}
__declspec(dllexport) int solarpunk_eos_identity_armed(void) { return g_armed; }
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        HANDLE t = CreateThread(NULL, 0, watcher, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
