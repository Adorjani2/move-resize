package main


import "base:runtime"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"
@(default_calling_convention="system")
foreign user32 {
	QueryFullProcessImageNameW :: proc(hProcess: win.HANDLE, dwFlags: win.DWORD, lpExeName: win.LPWSTR, lpdwSize: win.PDWORD) -> win.BOOL ---
}


NAME_BUFF_LEN :: 2048
INIT_RUNNING_EXES_CAP :: 512

MAX_MOD_KEYS :: 3
CONTEXT_MENU_MSG :: win.WM_APP + 1

COMMAND_EXIT :: 1
COMMAND_TOGGLE_ENABLE :: 2
COMMAND_EXCLUDE_APP :: 3


App_State :: struct {
	state : enum {None, Moving, Resizing},

	resize_type : enum {Top_Left, Top_Right, Bottom_Left, Bottom_Right},

	win_handle        : win.HWND,
	win_rect_at_start : win.RECT,
	mouse_at_start    : win.POINT,
}


g_state := struct {
	mod_keys : [MAX_MOD_KEYS]win.INT,
	enabled  : bool,

	running_exes_arena : vmem.Arena,
	running_exes_alloc : mem.Allocator,
	running_exes       : [dynamic]cstring16,
	excl_exes          : [dynamic]cstring16,

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

				buff : [NAME_BUFF_LEN]u16
				if !query_window_process_exe(final_state.win_handle, buff[:]) {
					break outter_switch
				}
				name, _, _, _ := get_exe_name_from_path(buff[:])

				for e in g_state.excl_exes {
					if name == e {
						break outter_switch
					}
				}

				if win.IsZoomed(final_state.win_handle) {
					win.ShowWindow(final_state.win_handle, win.SW_RESTORE)
				}

				if win.GetWindowRect(final_state.win_handle, &final_state.win_rect_at_start) {
					final_state.state = msg_id == win.WM_LBUTTONDOWN ? .Moving : .Resizing
				} else {
					break outter_switch
				}

				fullscreen_size := [?]win.LONG{
					win.GetSystemMetrics(win.SM_CXSCREEN),
					win.GetSystemMetrics(win.SM_CYSCREEN)
				}
				if get_rect_size(final_state.win_rect_at_start) == fullscreen_size {
					return 1
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

	    	p : win.POINT
	    	win.GetCursorPos(&p)

	    	menu := win.CreatePopupMenu()
	    	win.AppendMenuW(
	    		menu,
	    		win.MF_STRING | win.MF_ENABLED | (g_state.enabled ? win.MF_CHECKED : win.MF_UNCHECKED),
	    		COMMAND_TOGGLE_ENABLE,
	    		"Enabled"
	    	)

	    	refresh_running_exes()
	    	excl_menu := win.CreatePopupMenu()
	    	for exe, index in g_state.running_exes {
	    		found := false
	    		for exc in g_state.excl_exes {
	    			if exe == exc {
	    				found = true
	    				break
	    			}
	    		}
	    		flags : win.UINT = win.MF_STRING | (found ? win.MF_CHECKED : 0)
	    		win.AppendMenuW(excl_menu, flags, win.UINT_PTR(COMMAND_EXCLUDE_APP + index) , exe)
	    	}
	    	win.AppendMenuW(menu, win.MF_POPUP | win.MF_STRING, cast(win.UINT_PTR)excl_menu, "Exclude Apps")

	    	win.AppendMenuW(menu, win.MF_STRING | win.MF_ENABLED, COMMAND_EXIT, "Exit")

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

	    		// App exlude
				case: {
					if wparam < COMMAND_EXCLUDE_APP {
						break
					}

					exclude_index := uint(wparam) - COMMAND_EXCLUDE_APP
					exclude_name := g_state.running_exes[exclude_index]

					found_index := -1
					for e, i in g_state.excl_exes {
						if exclude_name == e {
							found_index = i
							break
						}
					}

					if found_index >= 0 {
						delete(g_state.excl_exes[found_index])
						unordered_remove(&g_state.excl_exes, found_index)
					} else {
						ns := make([]u16, len(exclude_name))
						mem.copy(&ns[0], (transmute(runtime.Raw_Cstring16)exclude_name).data, len(ns) * size_of(u16))
						append(&g_state.excl_exes, cstring16(cast([^]u16)&ns[0]))
					}
				}
	    	}
	    }
    }

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}



refresh_running_exes :: proc() {
	clear_running_exes()
	g_state.running_exes = make([dynamic]cstring16, 0, INIT_RUNNING_EXES_CAP, g_state.running_exes_alloc)

	for hwnd := win.GetTopWindow(nil); hwnd != nil; hwnd = win.GetWindow(hwnd, win.GW_HWNDNEXT) {
		if !win.IsWindowVisible(hwnd) {
			continue
		}

		style := win.GetWindowLongPtrW(hwnd, win.GWL_STYLE)
		if (style & int(win.WS_THICKFRAME)) == 0 {
			continue
		}

		buff : [NAME_BUFF_LEN]u16

		if !query_window_process_exe(hwnd, buff[:]) {
			continue
		}

		name, last_slash_index, path_len, name_len := get_exe_name_from_path(buff[:])

		found := false
		for exe in g_state.running_exes {
			if runtime.cstring16_eq(name, exe) {
				found = true
				break
			}
		}
		if found {
			continue
		}

		raw_data := make([]u16, path_len, g_state.running_exes_alloc)
		mem.copy(&raw_data[0], &buff[last_slash_index + 1], name_len * size_of(u16))
		append(&g_state.running_exes, cstring16(cast([^]u16)&raw_data[0]))
	}
}



get_exe_name_from_path :: proc(buff: []u16) -> (name: cstring16, last_slash_index, path_len, name_len: int) {
	last_slash_index = 0
	path_len = 0 // includes null
	for b, i in buff {
		if b == '\\' {
			last_slash_index = i
		}

		if b == 0 {
			path_len = i + 1
			break
		}
	}
	name_len = path_len - last_slash_index
	name = cstring16(cast([^]u16)&buff[last_slash_index + 1])
	return
}



clear_running_exes :: proc() {
	vmem.arena_free_all(&g_state.running_exes_arena)
}



query_window_process_exe :: proc(hwnd: win.HWND, buff: []u16) -> bool {
	pid : win.DWORD = 0
	win.GetWindowThreadProcessId(hwnd, &pid)
	if pid == 0 {
		return false
	}

	hpid := win.OpenProcess(win.PROCESS_QUERY_INFORMATION | win.PROCESS_VM_READ , false, pid)
	if hpid == nil {
		return false
	}
	defer win.CloseHandle(hpid)

	bl := win.DWORD(len(buff))
	if !QueryFullProcessImageNameW(hpid, 0, &buff[0], &bl) {
		return false
	}

	return true
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

	arena_err := vmem.arena_init_growing(&g_state.running_exes_arena)
	assert(arena_err == .None, "Failed to init arena")
	g_state.running_exes_alloc = vmem.arena_allocator(&g_state.running_exes_arena)
	defer vmem.arena_destroy(&g_state.running_exes_arena)

	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) != 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	clear_running_exes()
}
