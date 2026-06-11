@echo off
REM Build SolarpunkPlugin.dll (x64) with MSVC + MinHook.
REM Run from a "x64 Native Tools Command Prompt for VS 2022", or this script calls vcvars64 itself.
setlocal
set HERE=%~dp0

REM --- locate vcvars64 ---
if "%VSCMD_ARG_TGT_ARCH%"=="" (
  for %%V in (
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Preview\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
  ) do if exist %%V call %%V & goto :built
  :built
)

REM --- fetch MinHook if missing ---
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
