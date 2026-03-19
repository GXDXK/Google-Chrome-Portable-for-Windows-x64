:: GBK
@echo off
setlocal enabledelayedexpansion

title Chrome 便携版

:MENU
cls
echo.
echo ==============================================
echo                Chrome 便携版
echo ==============================================
echo.
echo    [1] 自动配置(构建或检查更新)
echo    [2] 关于
echo    [0] 退出
echo.
echo ==============================================
choice /C 012 /M "请输入选项"
if errorlevel 3 goto ABOUT
if errorlevel 2 goto AUTO
if errorlevel 1 exit
exit


:AUTO

set "BASE_DIR=%~dp0"
set "TEMP_DIR=%BASE_DIR%Temp"
set "APP_DIR=%BASE_DIR%App"
set "CHROME_EXE=%APP_DIR%\chrome.exe"
set "CHROME_UPDATE_CHECK_URL=https://tools.google.com/service/update2"
set "CHROME_DOWNLOAD_URL=https://dl.google.com/tag/s/installdataindex/update2/installers/ChromeStandaloneSetup64.exe"
set "TASK="

if exist "!CHROME_EXE!" (
    echo 开始检查更新
    set "TASK=check_update"
    goto CHECK_UPDATE
)
echo 开始构建
set "TASK=build"
goto BUILD


:CHECK_UPDATE

mkdir "%TEMP_DIR%" >nul 2>&1

echo 正在查询 Chrome 最新版本号...
curl -s -X POST "%CHROME_UPDATE_CHECK_URL%" ^
-H "Content-Type: application/xml" ^
-d "@%BASE_DIR%update_check.xml" ^
-o "%TEMP_DIR%\version.xml"

for /f "delims=" %%v in ('
    powershell -Command "[xml]$xml=Get-Content -Path '%TEMP_DIR%\version.xml' -Raw; $xml.response.app.updatecheck.manifest.version"
') do (
    set "LATEST_CHROME_VERSION=%%v"
)

for /f "delims=" %%v in ('
    powershell -Command "(Get-Item '%CHROME_EXE%').VersionInfo.ProductVersion"
') do (
    set "LOCAL_CHROME_VERSION=%%v"
)

echo ==============================================
echo 最新 Chrome 版本：!LATEST_CHROME_VERSION!
echo 本地 Chrome 版本：!LOCAL_CHROME_VERSION!
echo ==============================================

for /f "tokens=1-4 delims=." %%a in ("!LATEST_CHROME_VERSION!") do (
    for /f "tokens=1-4 delims=." %%w in ("!LOCAL_CHROME_VERSION!") do (
        if %%a gtr %%w set "TASK=update"
        if %%b gtr %%x set "TASK=update"
        if %%c gtr %%y set "TASK=update"
        if %%d gtr %%z set "TASK=update"
        set "TASK=up_to_date"
    )
)

rd /s /q "%TEMP_DIR%" >nul 2>&1

if "!TASK!"=="update" (
    echo 发现新版本，开始更新...
    goto BUILD
)
if "!TASK!"=="up_to_date" (
    echo 已是最新版本，无需更新
    pause
    exit
)
echo 版本检查异常
pause
goto MENU


:BUILD

mkdir "%TEMP_DIR%" >nul 2>&1
mkdir "%APP_DIR%" >nul 2>&1

if "!TASK!"=="update" (
    echo 正在备份 chrome++.ini...
    copy /y "%APP_DIR%\chrome++.ini" "%TEMP_DIR%" >nul 2>&1
    rd /s /q "%APP_DIR%" >nul 2>&1
    mkdir "%APP_DIR%" >nul 2>&1
)

echo 正在下载最新 Chrome 离线包...
"%BASE_DIR%wget" --show-progress --quiet -c "%CHROME_DOWNLOAD_URL%" -P "%TEMP_DIR%"

echo 正在解压文件...
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\ChromeStandaloneSetup64.exe" -o"%TEMP_DIR%" -y >nul 2>&1
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\updater.7z" -o"%TEMP_DIR%" -y >nul 2>&1
for /r "%TEMP_DIR%\bin\Offline" %%f in (*chrome_installer.exe) do (
    "%BASE_DIR%7za.exe" x "%%~f" -o"%TEMP_DIR%" -y >nul 2>&1
)
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\chrome.7z" -o"%TEMP_DIR%" -y >nul 2>&1

echo 正在部署 Chrome 文件...
xcopy "%TEMP_DIR%\Chrome-bin" "%APP_DIR%" /e /i /h /y >nul 2>&1

echo 正在配置组件...
"%BASE_DIR%setdll-x64.exe" /d:version-x64.dll "%CHROME_EXE%" >nul 2>&1
copy /y "%BASE_DIR%chrome++.ini" "%APP_DIR%" >nul 2>&1
copy /y "%BASE_DIR%version-x64.dll" "%APP_DIR%" >nul 2>&1
del "%APP_DIR%\chrome.exe~" >nul 2>&1
if "!TASK!"=="update" (
    echo 正在恢复 chrome++.ini...
    copy /y "%TEMP_DIR%\chrome++.ini" "%APP_DIR%" >nul 2>&1
)

rd /s /q "%TEMP_DIR%" >nul 2>&1

echo 配置成功
pause
exit

:ABOUT
cls
echo.
echo ==============================================
echo Google Chrome 便携版(x64) for Windows
echo.
echo 工具：
echo Chrome++ Next 1.15.1 + Set DLL 2.0.0
echo https://github.com/Bush2021/chrome_plus/releases
echo.
echo GNU Wget 1.21.4 for Windows
echo https://eternallybored.org/misc/wget/
echo.
echo 7-Zip Extra 26.00
echo https://www.7-zip.org/download.html
echo.
echo Bat To Exe Converter 3.0.8 (非官方)
echo https://github.com/tokyoneon/B2E
echo ==============================================
pause
exit