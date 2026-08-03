@echo off
rem Chrome Portable Updater launcher
rem Delegates to the VBS launcher, which starts PowerShell fully hidden (no console window).
start "" wscript "%~dp0ChromePlusUpdater.vbs"
