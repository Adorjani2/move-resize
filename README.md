# KDE move resize for windows

[one already exists](https://corz.org/windows/software/accessories/KDE-resizing-moving-for-Windows.php) but it's laggy (for me at least), and it did not work in ableton when i wanted to move plugin windows; so i decided to implement one with the winapi in Odin

## Usage
- currently only supports Ctr + Shift
- Ctrl + Shift + LMB -> move window under cursor
- Ctrl + Shift + RMB -> resize window under cursor
- Ctrl + Shift + MMB / Ctrl + Shift + Alt + LMB -> snap window to corner / edge or maximize
- system tray icon
  - enable/disable
  - add/remove .exe filters
  - show title filters defined in the config
  - exit

## Config file
creates or reads a file named ".move_resize" at the exes location, saves the filters there
### [settings]
TODO
### [exclude]
each line after this section is a window filter  
lines must start with an 'e' or 't' character then a space
- 'e': exact matches the window exes name
- 't': checks if a window title contains the given string

example .move_resize:
```
e Windows Terminal.exe
t Ableton
```
this will filter out any windows that were created by "Windows Terminal.exe" or that contain "Ableton" in their window title  


## Building
needs odin compiler (version 2026-05 as of now)  
simply run build.bat

## TODO
- customizable shortcut
- icon for systray and exe
- fix being able to do mouse down events while already moving/resizing if you press the other mouse buttons
