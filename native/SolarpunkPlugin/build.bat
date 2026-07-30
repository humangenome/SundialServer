@echo off
REM Build SolarpunkPlugin.dll (x64) with MSVC + MinHook.
REM Run from a "x64 Native Tools Command Prompt for VS 2022", or this script calls vcvars64 itself.
setlocal
set HERE=%~dp0

REM --- locate vcvars64 ---
REM vswhere first: it finds every edition including Enterprise, which the
REM hardcoded list below did not, so a build on an Enterprise box (a GitHub
REM windows runner, for one) fell through to "cl is not recognized".
REM
REM None of this may live inside a parenthesised if-block. cmd parses a whole
REM block before it evaluates the condition, and %ProgramFiles(x86)% closes the
REM block early -- "\Microsoft was unexpected at this time", even on the branch
REM that is not taken. goto labels instead.
if not "%VSCMD_ARG_TGT_ARCH%"=="" goto :vcready

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :vcfallback
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%I\VC\Auxiliary\Build\vcvars64.bat" call "%%I\VC\Auxiliary\Build\vcvars64.bat" & goto :vcready

:vcfallback
for %%V in (
  "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Preview\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) do if exist %%V call %%V & goto :vcready

:vcready

REM --- fetch MinHook if missing ---
REM The release workflow checks this out at a pinned commit before calling this
REM script, so the clone below only runs for a local build. Pin it there too if
REM you need the exact bytes a release produced.
if not exist "%HERE%minhook\src\hook.c" (
  git clone --depth 1 https://github.com/TsudaKageyu/minhook.git "%HERE%minhook"
)

set MH=%HERE%minhook
set OUT=%HERE%build
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /LD /O2 /EHsc /std:c++17 /MT ^
  /I "%MH%\include" ^
  "%HERE%src\dllmain.cpp" ^
  "%MH%\src\hook.c" "%MH%\src\buffer.c" "%MH%\src\trampoline.c" ^
  "%MH%\src\hde\hde64.c" ^
  /Fe:"%OUT%\SolarpunkPlugin.dll" /Fo:"%OUT%\\" ^
  /link psapi.lib

echo.
if exist "%OUT%\SolarpunkPlugin.dll" (echo BUILD OK: %OUT%\SolarpunkPlugin.dll) else (echo BUILD FAILED)
endlocal
