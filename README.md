# KDE move resize for windows

[one already exists](https://corz.org/windows/software/accessories/KDE-resizing-moving-for-Windows.php) but it's laggy (for me at least), so i decided to implement one with the winapi in Odin

## Usage
- currently only supports Ctr + Shift
- Ctrl + Shift + LMB -> move window under cursor
- Ctrl + Shift + RMB -> resize window under cursor
- system tray icon to enable/disable or exit

## Building
needs odin compiler (version 2026-04 as of now)  
simply run build.bat

## Run on startup
1. Win + R -> "shell:startup"
2. Add shortcut to the .exe in the directory that opened up

## TODO
- [] exclude specific apps
- [] customizable shortcut
- [] icon for systray and exe
