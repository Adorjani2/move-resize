package main


import "base:runtime"
import "core:fmt"
import "core:math"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"
@(default_calling_convention="system")
foreign user32 {
	BlockInput :: proc(fBlockIt: win.BOOL) -> win.BOOL ---
}



MAX_MOD_KEYS :: 3
CONTEXT_MENU_MSG :: win.WM_APP + 1

COMMAND_EXIT :: 1
COMMAND_TOGGLE_ENABLE :: 2


App_State :: struct {
	state : enum {None, Moving, Resizing},

	resize_type : enum {Top_Left, Top_Right, Bottom_Left, Bottom_Right},

	win_handle        : win.HWND,
	win_rect_at_start : win.RECT,
	mouse_at_start    : win.POINT,
}


g_state := struct {
	mod_keys     : [MAX_MOD_KEYS]win.INT,
	enabled      : bool,
	using _state : App_State,
}{}


// https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc
hook_on_mouse_event :: proc "system" (code: win.c_int, msg_id: win.WPARAM, ptr_msllhook: win.LPARAM) -> win.LRESULT {
	if code < 0 || !g_state.enabled {
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
	}

	context = runtime.default_context()
	event := (transmute(^win.MSLLHOOKSTRUCT)ptr_msllhook)^

	need_to_clear_state :=
		(msg_id == win.WM_LBUTTONUP && g_state.state == .Moving) ||
		(msg_id == win.WM_RBUTTONUP && g_state.state == .Resizing)

	if need_to_clear_state {
		clear_state()
		return 1
	}

	outter_switch: switch g_state.state {
		case .None: {
			if !are_mod_keys_down() {
				break outter_switch
			}

			final_state : App_State

			if msg_id == win.WM_LBUTTONDOWN || msg_id == win.WM_RBUTTONDOWN {
				final_state.win_handle = win.WindowFromPoint(event.pt)
				if final_state.win_handle == nil {
					break outter_switch
				}

				for tmp_handle := win.GetParent(final_state.win_handle); tmp_handle != nil; {
					final_state.win_handle = tmp_handle
					tmp_handle = win.GetParent(final_state.win_handle)
				}

				if win.IsZoomed(final_state.win_handle) {
					win.ShowWindow(final_state.win_handle, win.SW_RESTORE)
				}

				if win.GetWindowRect(final_state.win_handle, &final_state.win_rect_at_start) {
					final_state.state = msg_id == win.WM_LBUTTONDOWN ? .Moving : .Resizing
				} else {
					break outter_switch
				}

				if !win.GetCursorPos(&final_state.mouse_at_start) {
					break outter_switch
				}

				if msg_id == win.WM_RBUTTONDOWN {
					_ms := final_state.mouse_at_start
					if !win.ScreenToClient(final_state.win_handle, &_ms) {
						break outter_switch
					}
					ms := [2]win.LONG{_ms.x, _ms.y}
					wsh := get_rect_size(final_state.win_rect_at_start) / 2

					if ms.x > wsh.x {
						final_state.resize_type = ms.y > wsh.y ? .Bottom_Right : .Top_Right
					} else {
						final_state.resize_type = ms.y > wsh.y ? .Bottom_Left : .Top_Left
					}
				}

				g_state._state = final_state

				return 1
			}
		}

		case .Moving: {
			if msg_id != win.WM_MOUSEMOVE {
				break outter_switch
			}

			mouse_delta, delta_ok := get_mouse_delta(g_state.mouse_at_start)
			if !delta_ok {
				clear_state()
				break outter_switch
			}

			window_size := get_rect_size(g_state.win_rect_at_start)
			window_top_left := get_top_left(g_state.win_rect_at_start)

			new_pos := window_top_left + mouse_delta

			if !win.MoveWindow(g_state.win_handle, new_pos.x, new_pos.y, window_size.x, window_size.y, true) {
				clear_state()
				break outter_switch
			}
		}

		case .Resizing: {
			if msg_id != win.WM_MOUSEMOVE {
				break outter_switch
			}

			mouse_delta, delta_ok := get_mouse_delta(g_state.mouse_at_start)
			if !delta_ok {
				clear_state()
				break outter_switch
			}

			window_size := get_rect_size(g_state.win_rect_at_start)
			window_top_left := get_top_left(g_state.win_rect_at_start)

			new_pos  := window_top_left
			new_size := window_size

			switch g_state.resize_type {
				case .Top_Left: {
					new_pos += mouse_delta
					new_size += mouse_delta * -1
				}

				case .Top_Right: {
					new_pos.y += mouse_delta.y
					new_size += mouse_delta * {1, -1}
				}

				case .Bottom_Left: {
					new_pos.x += mouse_delta.x
					new_size += mouse_delta * {-1, 1}
				}

				case .Bottom_Right: {
					new_size += mouse_delta
				}
			}

			if !win.MoveWindow(g_state.win_handle, new_pos.x, new_pos.y, new_size.x, new_size.y, true) {
				clear_state()
				break outter_switch
			}
		}
	}

	return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
}



@(require_results)
get_rect_size :: proc(r: win.RECT) -> [2]win.LONG {
	return {r.right - r.left, r.bottom - r.top}
}


@(require_results)
get_mouse_delta :: proc(mouse_at_start: win.POINT) -> (delta: [2]win.LONG, ok: bool) {
	mouse_now: win.POINT
	if !win.GetCursorPos(&mouse_now) {
		return {}, false
	}

	delta = [?]win.LONG{
		mouse_now.x - mouse_at_start.x,
		mouse_now.y - mouse_at_start.y,
	}

	return delta, true
}


@(require_results)
get_top_left :: proc(r: win.RECT) -> [2]win.LONG {
	return {r.left, r.top}
}



clear_state :: proc() {
	g_state._state = {}
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



window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()

	switch msg {
	    case win.WM_DESTROY: {
	        win.PostQuitMessage(0)
	        return 0
	    }

	    case CONTEXT_MENU_MSG: {
	    	if lparam != win.WM_RBUTTONUP {
	    		break
	    	}

	    	fmt.println("menu")

	    	p : win.POINT
	    	win.GetCursorPos(&p)

	    	menu := win.CreatePopupMenu()
	    	win.AppendMenuW(
	    		menu,
	    		win.MF_STRING | win.MF_ENABLED | (g_state.enabled ? win.MF_CHECKED : win.MF_UNCHECKED),
	    		COMMAND_TOGGLE_ENABLE,
	    		cstring16("Enabled")
	    	)
	    	win.AppendMenuW(menu, win.MF_STRING | win.MF_ENABLED, COMMAND_EXIT, cstring16("Exit"))

	    	win.SetForegroundWindow(hwnd)
	    	win.TrackPopupMenu(menu, win.TPM_LEFTALIGN, p.x, p.y, 0, hwnd, nil)
	    }

	    case win.WM_COMMAND: {
	    	switch wparam {
	    		case COMMAND_EXIT: {
			        win.PostQuitMessage(0)
			        return 0
	    		}

	    		case COMMAND_TOGGLE_ENABLE: {
	    			g_state.enabled = !g_state.enabled
	    		}
	    	}
	    }
    }

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}



main :: proc() {
	// setup windows shits (for the system tray bs)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to get exe instance")

	CLASS_NAME :: cstring16("move_resize")
	window_class := win.WNDCLASSW {
		lpfnWndProc   = window_proc,
		lpszClassName = CLASS_NAME,
		hInstance     = instance,
	}
	class := win.RegisterClassW(&window_class)
	assert(class != 0, "Failed to create class")

	hwnd := win.CreateWindowW(
		CLASS_NAME,
		CLASS_NAME,
		0,
		10, 10, 10, 10,
		nil,
		nil,
		instance,
		nil
	)
	assert(hwnd != nil, "Failed to create window")

	// system tray setup
	nid := win.NOTIFYICONDATAW {
		cbSize           = size_of(win.NOTIFYICONDATAW),
		hWnd             = hwnd,
		uID              = 1,
		uFlags           = win.NIF_MESSAGE | win.NIF_ICON,
		uCallbackMessage = CONTEXT_MENU_MSG,
		hIcon            = win.LoadIconA(nil, win.IDI_APPLICATION)
	}
	win.Shell_NotifyIconW(win.NIM_ADD, &nid)
	defer win.Shell_NotifyIconW(win.NIM_DELETE, &nid)

	// setup hook shit
	g_state.enabled = true
	for &k in g_state.mod_keys {
		k = -1
	}
	g_state.mod_keys[0] = win.VK_SHIFT
	g_state.mod_keys[1] = win.VK_CONTROL

	hook_handle := win.SetWindowsHookExW(win.WH_MOUSE_LL, hook_on_mouse_event, nil, 0)
	defer win.UnhookWindowsHookEx(hook_handle)

	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) != 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}
