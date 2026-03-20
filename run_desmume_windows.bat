@echo off
setlocal

cd /d "%~dp0"

set "DESMUME_EXE_ARG=%~1"
if defined DESMUME_EXE_ARG (
  set "DESMUME_EXE=%DESMUME_EXE_ARG%"
)

if not defined DESMUME_EXE (
  echo DeSmuME executable path is required.
  echo.
  echo Usage:
  echo   run_desmume_windows.bat "C:\path\to\DeSmuME.exe"
  echo.
  echo Or set DESMUME_EXE first:
  echo   set DESMUME_EXE=C:\path\to\DeSmuME.exe
  echo   run_desmume_windows.bat
  exit /b 1
)

if not exist "%DESMUME_EXE%" (
  echo DeSmuME executable not found:
  echo   %DESMUME_EXE%
  exit /b 1
)

set "PYTHON_LAUNCHER=python"
where python >NUL 2>NUL
if errorlevel 1 (
  where py >NUL 2>NUL
  if errorlevel 1 (
    echo Python was not found in PATH.
    exit /b 1
  )
  set "PYTHON_LAUNCHER=py -3"
)

set "LUA_SCRIPT=analysis\scripts\desmume_battle_state_detector.lua"
set "CLI_DAEMON=analysis\scripts\desmume_cli_move_daemon.py"

if not exist "%LUA_SCRIPT%" (
  echo Lua script not found:
  echo   %CD%\%LUA_SCRIPT%
  exit /b 1
)

if not exist "%CLI_DAEMON%" (
  echo CLI daemon not found:
  echo   %CD%\%CLI_DAEMON%
  exit /b 1
)

echo Starting DeSmuME with working directory:
echo   %CD%
start "DeSmuME" /D "%CD%" "%DESMUME_EXE%"
if errorlevel 1 (
  echo Failed to start DeSmuME.
  exit /b 1
)

echo.
echo In DeSmuME, load this Lua script:
echo   %CD%\%LUA_SCRIPT%
echo.
echo Starting CLI move daemon...
echo.

%PYTHON_LAUNCHER% "%CLI_DAEMON%"
exit /b %ERRORLEVEL%
