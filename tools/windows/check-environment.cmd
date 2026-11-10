@echo off
setlocal DisableDelayedExpansion
set "ERRORLEVEL="
set "NO_PAUSE="
set "APPLY="
set "BAD_ARGS="
:args
if "%~1"=="" (
    if "%~2"=="" goto parsed
    set "BAD_ARGS=1"
    shift
    goto args
)
if /I "%~1"=="-NonInteractive" goto noninteractive
if /I "%~1"=="-ApplyIdentity" goto apply
set "BAD_ARGS=1"
shift
goto args
:noninteractive
set "NO_PAUSE=1"
shift
goto args
:apply
set "APPLY=-ApplyIdentity"
shift
goto args
:parsed
if defined BAD_ARGS goto bad_args
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" goto no_powershell
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -File "%~dp0check-environment.ps1" %APPLY%
set "CHECK_EXIT=%ERRORLEVEL%"
goto done
:bad_args
echo Usage: check-environment.cmd [-ApplyIdentity] [-NonInteractive]
set "CHECK_EXIT=2"
goto done
:no_powershell
echo Windows PowerShell 5.1 is required.
set "CHECK_EXIT=1"
:done
if not defined NO_PAUSE pause
endlocal & exit /b %CHECK_EXIT%
