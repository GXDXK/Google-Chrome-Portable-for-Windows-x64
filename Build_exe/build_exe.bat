@echo off
rem Build ChromePlusUpdater.exe (WinExe, no console) by embedding ChromePlusUpdater.ps1.
rem Uses the built-in .NET Framework csc.exe - no extra install needed.
setlocal
cd /d "%~dp0"
set "CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo [ERROR] csc.exe not found: %CSC%
    exit /b 1
)
"%CSC%" /nologo /target:winexe /out:"..\ChromePlusUpdater.exe" /resource:"..\ChromePlusUpdater.ps1",ChromePlusUpdater.ps1 /r:System.Windows.Forms.dll Launcher.cs
if errorlevel 1 (
    echo [ERROR] compile failed
    exit /b 1
)
echo [OK] ChromePlusUpdater.exe generated at ..\ChromePlusUpdater.exe
endlocal
