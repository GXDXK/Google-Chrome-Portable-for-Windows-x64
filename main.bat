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

echo [mkdir] 创建 Temp 文件夹
mkdir "%TEMP_DIR%" >nul 2>&1

echo [curl] 查询 Chrome 最新版本号 (POST update_check.xml)
curl -s -X POST "%CHROME_UPDATE_CHECK_URL%" ^
-H "Content-Type: application/xml" ^
-d "@%BASE_DIR%update_check.xml" ^
-o "%TEMP_DIR%\version.xml"

echo [powershell] 从 xml 解析最新 Chrome 版本号 (version.xml)
for /f "delims=" %%v in ('
    powershell -Command "[xml]$xml=Get-Content -Path '%TEMP_DIR%\version.xml' -Raw; $xml.response.app.updatecheck.manifest.version"
') do (
    set "LATEST_CHROME_VERSION=%%v"
)

echo [powershell] 获取本地 chrome.exe 版本号
for /f "delims=" %%v in ('
    powershell -Command "(Get-Item '%CHROME_EXE%').VersionInfo.ProductVersion"
') do (
    set "LOCAL_CHROME_VERSION=%%v"
)

echo ==============================================
echo    最新 Chrome 版本：!LATEST_CHROME_VERSION!
echo    本地 Chrome 版本：!LOCAL_CHROME_VERSION!
echo ==============================================

for /f "tokens=1-4 delims=." %%a in ("!LATEST_CHROME_VERSION!") do (
    for /f "tokens=1-4 delims=." %%w in ("!LOCAL_CHROME_VERSION!") do (
        if %%a gtr %%w set "TASK=update" & goto BUILD
        if %%b gtr %%x set "TASK=update" & goto BUILD
        if %%c gtr %%y set "TASK=update" & goto BUILD
        if %%d gtr %%z set "TASK=update" & goto BUILD
        set "TASK=up_to_date"
    )
)

echo [rd] 删除 Temp 文件夹
rd /s /q "%TEMP_DIR%" >nul 2>&1

if "!TASK!"=="up_to_date" (
    echo ==============================================
    echo    已是最新版本，无需更新
    echo ==============================================
    color 09
    pause
    exit
)
echo 版本检查异常
color 0C
pause
goto MENU


:BUILD

if "!TASK!"=="update" (
    echo ==============================================
    echo    发现新版本，开始更新
    echo ==============================================
)

echo [mkdir] 创建 App, Temp 文件夹
mkdir "%TEMP_DIR%" >nul 2>&1
mkdir "%APP_DIR%" >nul 2>&1

if "!TASK!"=="update" (
    echo [copy] 备份 chrome++.ini
    copy /y "%APP_DIR%\chrome++.ini" "%TEMP_DIR%" >nul 2>&1
    echo [copy mkdir] 清空 App 文件夹
    rd /s /q "%APP_DIR%" >nul 2>&1
    mkdir "%APP_DIR%" >nul 2>&1
)

echo [wget.exe] 下载最新 Chrome 离线安装包 ChromeStandaloneSetup64.exe
"%BASE_DIR%wget" --show-progress --quiet -c "%CHROME_DOWNLOAD_URL%" -P "%TEMP_DIR%"

echo [7za.exe] 从 ChromeStandaloneSetup64.exe 解压获取 Chrome-bin 文件夹
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\ChromeStandaloneSetup64.exe" -o"%TEMP_DIR%" -y >nul 2>&1
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\updater.7z" -o"%TEMP_DIR%" -y >nul 2>&1
for /r "%TEMP_DIR%\bin\Offline" %%f in (*chrome_installer.exe) do (
    "%BASE_DIR%7za.exe" x "%%~f" -o"%TEMP_DIR%" -y >nul 2>&1
)
"%BASE_DIR%7za.exe" x "%TEMP_DIR%\chrome.7z" -o"%TEMP_DIR%" -y >nul 2>&1

echo [xcopy] 将 Chrome-bin 文件夹的内容复制到 App 文件夹
xcopy "%TEMP_DIR%\Chrome-bin" "%APP_DIR%" /e /i /h /y >nul 2>&1

echo [setdll-x64.exe] 向 chrome.exe 注入 version-x64.dll
"%BASE_DIR%setdll-x64.exe" /d:version-x64.dll "%CHROME_EXE%" >nul 2>&1
echo [copy] 复制 chrome++.ini 到 App 文件夹
copy /y "%BASE_DIR%chrome++.ini" "%APP_DIR%" >nul 2>&1
echo [copy] 复制 version-x64.dll 到 App 文件夹
copy /y "%BASE_DIR%version-x64.dll" "%APP_DIR%" >nul 2>&1
echo [del] 删除 chrome.exe 的备份文件 chrome.exe~
del "%APP_DIR%\chrome.exe~" >nul 2>&1
if "!TASK!"=="update" (
    echo [copy] 恢复备份的 chrome++.ini 到 App 文件夹
    copy /y "%TEMP_DIR%\chrome++.ini" "%APP_DIR%" >nul 2>&1
)

echo [rd] 删除 Temp 文件夹
rd /s /q "%TEMP_DIR%" >nul 2>&1

echo ==============================================
echo    配置成功
echo ==============================================
color 0A
pause
exit

:ABOUT
cls
color 0E
echo.
echo ====================================================
echo        Google Chrome Portable for Windows(x64)
echo ====================================================
echo   工具：
echo   Chrome++ Next 1.15.1 + Set DLL 2.0.0
echo   https://github.com/Bush2021/chrome_plus/releases
echo.
echo   GNU Wget 1.21.4 for Windows
echo   https://eternallybored.org/misc/wget/
echo.
echo   7-Zip Extra 26.00
echo   https://www.7-zip.org/download.html
echo.
echo   Bat To Exe Converter 3.0.8 (非官方)
echo   https://github.com/tokyoneon/B2E
echo ====================================================
pause
exit