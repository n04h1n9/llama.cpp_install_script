@echo off
setlocal
pushd "%~dp0"

rem Pick the script matching the Windows UI language.
rem Do NOT use HKCU\...\International\LocaleName: that is the regional FORMAT,
rem which can differ from the UI language (this machine: en-US format, zh-CN UI).
set "UILANG="
for /f "tokens=3" %%a in ('reg query "HKCU\Control Panel\Desktop\MuiCached" /v MachinePreferredUILanguages 2^>nul') do set "UILANG=%%a"

rem Fallback 1: the language Windows was installed with (LCID).
if not defined UILANG (
    set "INSTLANG="
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language" /v InstallLanguage 2^>nul') do set "INSTLANG=%%a"
    if /i "%INSTLANG%"=="0804" set "UILANG=zh-CN"
    if /i "%INSTLANG%"=="0404" set "UILANG=zh-TW"
    if /i "%INSTLANG%"=="0c04" set "UILANG=zh-HK"
    if /i "%INSTLANG%"=="1004" set "UILANG=zh-SG"
    if /i "%INSTLANG%"=="0409" set "UILANG=en-US"
)

rem Fallback 2: ask PowerShell (works on both 5.1 and 7).
if not defined UILANG (
    for /f "delims=" %%a in ('powershell -NoProfile -Command "(Get-WinUserLanguageList)[0].LanguageTag" 2^>nul') do set "UILANG=%%a"
)

set "WANT=en"
if /i "%UILANG:~0,2%"=="zh" set "WANT=zh"

if /i "%WANT%"=="zh" (
    set "SCRIPT=llm_install.zh-CN.ps1"
    set "ALT=llm_install.ps1"
) else (
    set "SCRIPT=llm_install.ps1"
    set "ALT=llm_install.zh-CN.ps1"
)
if not exist "%SCRIPT%" set "SCRIPT=%ALT%"
if not exist "%SCRIPT%" (
    echo [ERROR] No llm_install*.ps1 found next to this .cmd file.
    popd
    endlocal
    exit /b 1
)

echo [INFO] UI language : %UILANG%
echo [INFO] Script      : %SCRIPT%
echo.

rem Prefer PowerShell 7. -ExecutionPolicy Bypass affects only this one
rem invocation; it changes no machine or user policy.
where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    echo [INFO] pwsh not found, falling back to Windows PowerShell 5.1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

set "RC=%errorlevel%"
popd

rem Keep the window open when launched by double-click (no arguments given)
if "%~1"=="" (
    echo.
    echo [exit code %RC%]  Press any key to close this window . . .
    pause >nul
)

endlocal & exit /b %RC%
