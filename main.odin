package main


import "base:runtime"
import "core:fmt"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"
@(default_calling_convention="system")
foreign user32 {
	BlockInput :: proc(fBlockIt: win.BOOL) -> win.BOOL ---
}



MAX_MODIFIER_KEYS :: 3

App_State :: struct {
	mod_keys: [MAX_MODIFIER_KEYS]win.INT,

	state: enum {None, Moving, Resizing},

	win_handle:        win.HWND,
	win_rect_at_start: win.RECT,
	mouse_at_start:    win.POINT,
}


g_state : App_State


// https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc
hook_on_mouse_event :: proc "system" (code: win.c_int, msg_id: win.WPARAM, ptr_msllhook: win.LPARAM) -> win.LRESULT {
	if code < 0 {
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
	}

	context = runtime.default_context()
	event := transmute(^win.MSLLHOOKSTRUCT)(ptr_msllhook)

	need_to_clear_state :=
		(msg_id == win.WM_LBUTTONUP && g_state.state == .Moving) ||
		(msg_id == win.WM_RBUTTONUP && g_state.state == .Resizing)

	if need_to_clear_state {
		fmt.println("ACTION STOP")
		clear_state()
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
	}

	outter_switch: switch g_state.state {
		case .None: {
			if !are_mod_keys_down() {
				break outter_switch
			}

			if msg_id == win.WM_LBUTTONDOWN || msg_id == win.WM_RBUTTONDOWN {
				g_state.win_handle = win.WindowFromPoint(event.pt)
				if g_state.win_handle == nil {
					fmt.eprintln("NO MOVING 1")
					clear_state()
					break outter_switch
				}

				for tmp_handle := win.GetParent(g_state.win_handle); tmp_handle != nil; {
					g_state.win_handle = tmp_handle
					tmp_handle = win.GetParent(g_state.win_handle)
				}

				if win.IsZoomed(g_state.win_handle) {
					win.ShowWindow(g_state.win_handle, win.SW_RESTORE)
				}

				if win.GetWindowRect(g_state.win_handle, &g_state.win_rect_at_start) {
					g_state.state = msg_id == win.WM_LBUTTONDOWN ? .Moving : .Resizing
				} else {
					fmt.eprintln("NO MOVING 2")
					clear_state()
					break outter_switch
				}

				if !win.GetCursorPos(&g_state.mouse_at_start) {
					fmt.eprintln("NO MOVING 3")
					clear_state()
					break outter_switch
				}

				fmt.println("MOVE START")
			}
		}

		case .Moving: {
			if msg_id != win.WM_MOUSEMOVE {
				break outter_switch
			}

			mouse_now : win.POINT
			if !win.GetCursorPos(&mouse_now) {
				clear_state()
				break outter_switch
			}

			window_size := get_window_size(g_state.win_rect_at_start)

			mouse_delta := [?]win.LONG{
				mouse_now.x - g_state.mouse_at_start.x,
				mouse_now.y - g_state.mouse_at_start.y,
			}
			window_top_left := [?]win.LONG{
				g_state.win_rect_at_start.left,
				g_state.win_rect_at_start.top,
			}
			new_pos := window_top_left + mouse_delta

			if !win.MoveWindow(g_state.win_handle, new_pos.x, new_pos.y, window_size.x, window_size.y, win.TRUE) {
				clear_state()
				break outter_switch
			}

			fmt.println("moving")
		}

		case .Resizing: {
			
		}
	}

	return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
}



get_window_size :: proc(r: win.RECT) -> [2]win.LONG {
	return {r.right - r.left, r.bottom - r.top}
}



clear_mod_keys :: proc() {
	for &k in g_state.mod_keys {
		k = -1
	}
}



are_mod_keys_down :: proc() -> bool {
	for mk in g_state.mod_keys {
		if mk < 0 do continue

		if !(win.GetKeyState(mk) < 0) {
			return false
		}
	}

	return true
}



clear_state :: proc() {
	g_state.state = .None
	g_state.win_handle = nil
	g_state.win_rect_at_start = {}
	g_state.mouse_at_start = {}
}



main :: proc() {
	hook_handle := win.SetWindowsHookExW(win.WH_MOUSE_LL, hook_on_mouse_event, nil, 0)

	clear_mod_keys()
	g_state.mod_keys[0] = win.VK_SHIFT
	g_state.mod_keys[1] = win.VK_CONTROL

	clear_state()

	msg : win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) != 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	win.UnhookWindowsHookEx(hook_handle)
}
