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

App_State :: struct {
	state : enum {None, Moving, Resizing},

	resize_type : enum {Top_Left, Top_Right, Bottom_Left, Bottom_Right},

	win_handle        : win.HWND,
	win_rect_at_start : win.RECT,
	mouse_at_start    : win.POINT,
}


g_state := struct {
	mod_keys     : [MAX_MOD_KEYS]win.INT,
	using _state : App_State,
}{}


// https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc
hook_on_mouse_event :: proc "system" (code: win.c_int, msg_id: win.WPARAM, ptr_msllhook: win.LPARAM) -> win.LRESULT {
	if code < 0 {
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
	}

	context = runtime.default_context()
	event := (transmute(^win.MSLLHOOKSTRUCT)ptr_msllhook)^

	need_to_clear_state :=
		(msg_id == win.WM_LBUTTONUP && g_state.state == .Moving) ||
		(msg_id == win.WM_RBUTTONUP && g_state.state == .Resizing)

	if need_to_clear_state {
		clear_state()
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
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

					fmt.printfln("s: %v, c: %v, t: %v", final_state.mouse_at_start, ms, final_state.resize_type)
				}

				g_state._state = final_state
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



main :: proc() {
	hook_handle := win.SetWindowsHookExW(win.WH_MOUSE_LL, hook_on_mouse_event, nil, 0)

	for &k in g_state.mod_keys {
		k = -1
	}
	g_state.mod_keys[0] = win.VK_SHIFT
	g_state.mod_keys[1] = win.VK_CONTROL

	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) != 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	win.UnhookWindowsHookEx(hook_handle)
}
