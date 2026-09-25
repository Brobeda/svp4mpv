@echo off
setlocal enabledelayedexpansion
title svp4mpv Universal Auto-Installer

echo ====================================================
echo  svp4mpv Interactive Setup Script
echo ====================================================
echo.

:: ==========================================
:: STEP 1: Choose Player (MPV vs MPV.NET)
:: ==========================================
:choose_player
echo [1/3] Select your media player flavor:
echo  1) Standard MPV (mpv)
echo  2) MPV.NET (mpv.net)
set /p "PLAYER_CHOICE=Enter choice (1-2): "

if "%PLAYER_CHOICE%"=="1" (
    set "PLAYER_NAME=mpv"
) else if "%PLAYER_CHOICE%"=="2" (
    set "PLAYER_NAME=mpv.net"
) else (
    echo Invalid choice, try again.
    echo.
    goto choose_player
)
echo Selected Player: %PLAYER_NAME%
echo.

:: ==========================================
:: STEP 2: Choose Config Structure (AppData vs portable_config)
:: ==========================================
:choose_config
echo [2/3] Choose your configuration type:
echo  1) Standard System-wide (%%APPDATA%%\%PLAYER_NAME%\)
echo  2) Local Portable Mode (Inside an adjacent 'portable_config' folder)
set /p "CONFIG_CHOICE=Enter choice (1-2): "

if "%CONFIG_CHOICE%"=="1" (
    set "BASE_CONFIG_DIR=%APPDATA%\%PLAYER_NAME%"
) else if "%CONFIG_CHOICE%"=="2" (
    if exist "%~dp0..\..\portable_config" (
        set "BASE_CONFIG_DIR=%~dp0..\..\portable_config"
    ) else if exist "%~dp0..\portable_config" (
        set "BASE_CONFIG_DIR=%~dp0..\portable_config"
    ) else (
        set "BASE_CONFIG_DIR=%~dp0portable_config"
    )
) else (
    echo Invalid choice, try again.
    echo.
    goto choose_config
)
echo Target Configuration Root: %BASE_CONFIG_DIR%
echo.

set "SCRIPT_FOLDER=%BASE_CONFIG_DIR%\scripts\svp4mpv"
set "PORTABLE_VS_FOLDER=%SCRIPT_FOLDER%\vapoursynth"
set "TEMP_DIR=%TEMP%\svp4mpv_install"

:: ==========================================
:: STEP 3: Choose VapourSynth Installation Mode
:: ==========================================
:choose_vs
echo [3/3] VapourSynth Deployment Option:
echo  1) Download and configure localized VapourSynth R72 automatically
echo  2) Skip (I already have VapourSynth R72 installed on system PATH or root)
set /p "VS_CHOICE=Enter choice (1-2): "

if "%VS_CHOICE%"=="1" (
    set "RUN_VS_INSTALL=YES"
) else if "%VS_CHOICE%"=="2" (
    set "RUN_VS_INSTALL=NO"
) else (
    echo Invalid choice, try again.
    echo.
    goto choose_vs
)
echo.

:: ==========================================
:: EXECUTION PHASE: Deploying Scripts
:: ==========================================
echo ====================================================
echo  Executing Installation Plan...
echo ====================================================

if not exist "%BASE_CONFIG_DIR%" mkdir "%BASE_CONFIG_DIR%"
if not exist "%SCRIPT_FOLDER%" mkdir "%SCRIPT_FOLDER%"
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

echo [1/3] Downloading latest repository archive (master branch)...
powershell.exe -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -Uri 'https://github.com/Brobeda/svp4mpv/archive/refs/heads/master.zip' -OutFile '%TEMP_DIR%\repo.zip';" ^
    "Expand-Archive -Path '%TEMP_DIR%\repo.zip' -DestinationPath '%TEMP_DIR%\repo' -Force;" ^
    "Copy-Item -Path '%TEMP_DIR%\repo\svp4mpv-master\*' -Destination '%SCRIPT_FOLDER%' -Recurse -Force;"

if "%RUN_VS_INSTALL%"=="YES" (
    echo [2/3] Downloading and compiling Portable VapourSynth R72 into %PORTABLE_VS_FOLDER%...
    powershell.exe -ExecutionPolicy Bypass -Command ^
        "Invoke-WebRequest -Uri 'https://github.com/vapoursynth/vapoursynth/releases/download/R72/Install-Portable-VapourSynth-R72.ps1' -OutFile '%TEMP_DIR%\Install-VS.ps1';" ^
        "& '%TEMP_DIR%\Install-VS.ps1' -VSVersion 72 -TargetFolder '%PORTABLE_VS_FOLDER%' -PythonVersionMajor 3 -PythonVersionMinor 13 -Unattended;"
) else (
    echo [2/3] Skipping VapourSynth download per request.
)

:: ==========================================
:: CONFIGURATION PHASE: Editing mpv.conf
:: ==========================================
echo [3/3] Checking hardware acceleration in mpv.conf...
set "CONF_FILE=%BASE_CONFIG_DIR%\mpv.conf"

if not exist "%CONF_FILE%" (
    echo hwdec=d3d11va-copy > "%CONF_FILE%"
) else (
    findstr /i "hwdec=" "%CONF_FILE%" >nul
    if errorlevel 1 (
        echo hwdec=d3d11va-copy >> "%CONF_FILE%"
    )
)

:: Clean up temporary workspace directory
rmdir /s /q "%TEMP_DIR%" >nul 2>&1

echo.
echo ====================================================
echo  SUCCESS! Installation complete.
echo  Target Script Location: %SCRIPT_FOLDER%
echo ====================================================
echo.
pause