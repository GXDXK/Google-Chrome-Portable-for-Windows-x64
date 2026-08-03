' Chrome 便携版更新器启动器（无控制台窗口）
' 以隐藏窗口方式启动 PowerShell，避免弹出黑色终端 / Windows Terminal 窗口；
' 主窗口由 ChromePlusUpdater.ps1 在初始化后强制显示。
Option Explicit
Dim shell, fso, scriptDir, ps1
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\ChromePlusUpdater.ps1"
shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & ps1 & """", 0, False
