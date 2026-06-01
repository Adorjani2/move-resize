package main


import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import str "core:strings"
import "core:unicode/utf16"
import vmem "core:mem/virtual"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"
@(default_calling_convention="system")
foreign user32 {
	QueryFullProcessImageNameW :: proc(hProcess: win.HANDLE, dwFlags: win.DWORD, lpExeName: win.LPWSTR, lpdwSize: win.PDWORD) -> win.BOOL ---
}


STR_BUFF_LEN             :: 2048
INIT_RUNNING_WINDOWS_CAP :: 512

CONFIG_FILE_NAME             :: ".move_resize"
CONFIG_FILE_SECTION_SETTINGS :: "[settings]"
CONFIG_FILE_SECTION_EXCLUDE  :: "[exclude]"

MAX_MOD_KEYS     :: 3
CONTEXT_MENU_MSG :: win.WM_APP + 1

SNAP_ZONE_SIZE_PERCENTAGE :: .1

COMMAND_EXIT          :: 1
COMMAND_TOGGLE_ENABLE :: 2
COMMAND_EXCLUDE_APP   :: 3

Action :: enum {
	None,
	Moving,
	Resizing,
	Snapping
}

Move_State :: struct {
	action : Action,

	resize_type : enum {Top_Left, Top_Right, Bottom_Left, Bottom_Right},

	snap_with_key : bool, // if true snapping was started with the key shortcut, else with middle mouse button

	win_handle        : win.HWND,
	win_rect_at_start : win.RECT,
	mouse_at_start    : win.POINT,
}


Config_Load_State :: enum {
	None,
	Settings,
	Exclude,
}


Exclusion_Type :: enum {
	Exe_Name,
	Window_Title,
}


Running_Window :: struct {
	exe_name  : cstring16,
	win_title : cstring16,
}


Window_Filter :: struct {
	type  : Exclusion_Type,
	text  : cstring16,
	count : i32, // u16 count in text (\0 included)
}


@rodata
ACTION_TO_MOUSE_DOWN := #partial[Action]win.WPARAM{
	.Moving   = win.WM_LBUTTONDOWN,
	.Resizing = win.WM_RBUTTONDOWN,
	.Snapping = win.WM_MBUTTONDOWN,
}

@rodata
ACTION_TO_MOUSE_UP := #partial[Action]win.WPARAM{
	.Moving   = win.WM_LBUTTONUP,
	.Resizing = win.WM_RBUTTONUP,
	.Snapping = win.WM_MBUTTONUP,
}

@rodata
EXLUSION_TYPE_TO_RUNE := [Exclusion_Type]rune{
	.Exe_Name = 'e',
	.Window_Title = 't',
}

SNAP_SHORTCUT_MOUSE_STARTER_BUTTON :: Action.Moving


g_state := struct {
	mod_keys : [MAX_MOD_KEYS]win.INT,
	snap_key : win.INT,
	enabled  : bool,

	arena : vmem.Arena, // mainly used for storing the strings for running_windows, but is also used in procedures for local allocations that get cleared before the proc returns
	alloc : mem.Allocator,

	running_windows : [dynamic]Running_Window,
	window_filters  : [dynamic]Window_Filter,

	using _state : Move_State,
}{}



// https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc
hook_on_mouse_event :: proc "system" (code: win.c_int, msg_id: win.WPARAM, ptr_msllhook: win.LPARAM) -> win.LRESULT {
	if code < 0 || !g_state.enabled {
		return win.CallNextHookEx(nil, code, msg_id, ptr_msllhook)
	}

	context = runtime.default_context()
	event := (transmute(^win.MSLLHOOKSTRUCT)ptr_msllhook)^

	for id, action in ACTION_TO_MOUSE_UP {
		if g_state.action == action && msg_id == id {
			clear_state()
			return 1
		}
	}

	if g_state.action == .Snapping && g_state.snap_with_key && msg_id == ACTION_TO_MOUSE_UP[SNAP_SHORTCUT_MOUSE_STARTER_BUTTON] {
		clear_state()
		return 1
	}

	outter_switch: switch g_state.action {
		case .None: {
			if !is_main_shortcut_down() {
				break outter_switch
			}

			final_state : Move_State

			start_action : bool
			for id in ACTION_TO_MOUSE_DOWN {
				if msg_id == id {
					start_action = true
					break
				}
			}

			if start_action {
				final_state.win_handle = win.WindowFromPoint(event.pt)
				if final_state.win_handle == nil {
					break outter_switch
				}

				for tmp_handle := win.GetParent(final_state.win_handle); tmp_handle != nil; {
					final_state.win_handle = tmp_handle
					tmp_handle = win.GetParent(final_state.win_handle)
				}

				// filtering
				buff : [STR_BUFF_LEN]u16
				{   // exe name
					if !query_window_process_exe_name(final_state.win_handle, buff[:]) {
						break outter_switch
					}
					exe_name, _, _, _ := get_exe_name_from_path(buff[:])

					for f in g_state.window_filters {
						if f.type == .Window_Title {
							continue
						}
						if exe_name == f.text {
							break outter_switch
						}
					}
				}

				{   // window title
					title_len := win.GetWindowTextW(final_state.win_handle, &buff[0], STR_BUFF_LEN) + 1 // + 1 for \0
					if title_len > 1 {
						for f in g_state.window_filters {
							if match_filter_window_title(f, buff[:title_len]) {
								// fmt.printfln("f: %s, m: %s", f.text, buff[:title_len])
								break outter_switch
							}
						}
					}
				}

				if !win.GetCursorPos(&final_state.mouse_at_start) {
					break outter_switch
				}

				monitor := win.MonitorFromPoint(final_state.mouse_at_start, .MONITOR_DEFAULTTONEAREST)
				monitor_info : win.MONITORINFO
				monitor_info.cbSize = size_of(win.MONITORINFO)
				if !win.GetMonitorInfoW(monitor, &monitor_info) {
					break outter_switch
				}
				fullscreen_size := get_rect_size(monitor_info.rcMonitor)

				// @Note: it seems like some apps are still considered zoomed if you make them fullscreen after maximizing
				// so we have to check if its fullscreen first, if not unzoom, and then get the window size again
				if !win.GetWindowRect(final_state.win_handle, &final_state.win_rect_at_start) {
					break outter_switch
				}
				if get_rect_size(final_state.win_rect_at_start) == fullscreen_size {
					break outter_switch
				}

				if win.IsZoomed(final_state.win_handle) {
					win.ShowWindow(final_state.win_handle, win.SW_RESTORE)
				}

				if !win.GetWindowRect(final_state.win_handle, &final_state.win_rect_at_start) {
					break outter_switch
				}

				// @Note: since touchpads dont have middle mouse button
				// just simply override if the keyboard button is down,
				// you can use both mmb and the key to start snapping
				if is_snap_shortcut_down() && msg_id == ACTION_TO_MOUSE_DOWN[SNAP_SHORTCUT_MOUSE_STARTER_BUTTON] {
					final_state.action = .Snapping
					final_state.snap_with_key = true
				} else {
					switch msg_id {
						case ACTION_TO_MOUSE_DOWN[.Moving]: final_state.action = .Moving
						case ACTION_TO_MOUSE_DOWN[.Resizing]: final_state.action = .Resizing
						case ACTION_TO_MOUSE_DOWN[.Snapping]: final_state.action = .Snapping
						case: {
							break outter_switch
						}
					}
				}

				if final_state.action == .Resizing {
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

				// fmt.printfln("state: %v", g_state.action)

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

		case .Snapping: {
			// get cursor pos
			cursor_pos_l : win.POINT
			if !win.GetCursorPos(&cursor_pos_l) {
				clear_state()
				break outter_switch
			}
			cursor_global_pos := [2]f64{f64(cursor_pos_l.x), f64(cursor_pos_l.y)}

			monitor := win.MonitorFromPoint(cursor_pos_l, .MONITOR_DEFAULTTONEAREST)
			monitor_info : win.MONITORINFO
			monitor_info.cbSize = size_of(win.MONITORINFO)
			if !win.GetMonitorInfoW(monitor, &monitor_info) {
				clear_state()
				break outter_switch
			}
			fullscreen_size_l   := get_rect_size(monitor_info.rcWork)
			screen_global_pos_l := get_top_left(monitor_info.rcWork)
			fullscreen_size     := [2]f64{f64(fullscreen_size_l.x), f64(fullscreen_size_l.y)}
			screen_global_pos   := [2]f64{f64(screen_global_pos_l.x), f64(screen_global_pos_l.y)}

			cursor_local_pos := cursor_global_pos - screen_global_pos
			c01 := cursor_local_pos / fullscreen_size

			s13 := f64(1./3.)
			s23 := f64(2./3.)

			fsh := fullscreen_size_l / 2
			new_pos := get_top_left(g_state.win_rect_at_start)
			new_size := get_rect_size(g_state.win_rect_at_start)

			if c01.x <= s13 && c01.y <= s13 { // corner top left
				new_pos = {
					monitor_info.rcWork.left,
					monitor_info.rcWork.top,
				}
				new_size = fsh
			} else if c01.x >= s23 && c01.y <= s13 { // corner top right
				new_pos = {
					monitor_info.rcWork.left + fsh.x,
					monitor_info.rcWork.top,
				}
				new_size = fsh
			} else if c01.x <= s13 && c01.y >= s23 { // corner bottom left
				new_pos = {
					monitor_info.rcWork.left,
					monitor_info.rcWork.top + fsh.y,
				}
				new_size = fsh
			} else if c01.x >= s23 && c01.y >= s23 { // corner bottom right
				new_pos = {
					monitor_info.rcWork.left + fsh.x,
					monitor_info.rcWork.top + fsh.y,
				}
				new_size = fsh
			} else if c01.x <= s13 { // left side
				new_pos = {
					monitor_info.rcWork.left,
					monitor_info.rcWork.top,
				}
				new_size = {
					fsh.x,
					fullscreen_size_l.y
				}
			} else if c01.x >= s23 { // right side
				new_pos = {
					monitor_info.rcWork.left + fsh.x,
					monitor_info.rcWork.top,
				}
				new_size = {
					fsh.x,
					fullscreen_size_l.y
				}
			} else if c01.y <= .5 { // maximize
				// @Note: one pixel off cause of the fullscreen detection gets softlocked otherwise
				// @Todo: proper zoom/maximize not just window size setting
				new_pos = {
					monitor_info.rcWork.left,
					monitor_info.rcWork.top + 1,
				}
				new_size = fullscreen_size_l
				new_size.y -= 1
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
	// fmt.println("clear")
	g_state._state = {}
}



is_main_shortcut_down :: proc() -> bool {
	for mk in g_state.mod_keys {
		if mk < 0 do continue

		if !(win.GetKeyState(mk) < 0) {
			return false
		}
	}

	return true
}



is_snap_shortcut_down :: proc() -> bool {
	return win.GetKeyState(g_state.snap_key) < 0
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

	    	arena_chkpt := vmem.arena_temp_begin(&g_state.arena)
	    	defer vmem.arena_temp_end(arena_chkpt)

	    	already_added_items := make([dynamic]cstring16, g_state.alloc)

	    	excl_menu := win.CreatePopupMenu()
	    	for exe, index in g_state.running_windows {
	    		skip_exe := false
	    		for item in already_added_items {
	    			if exe.exe_name == item {
	    				skip_exe = true
	    				break
	    			}
	    		}
	    		if skip_exe {
	    			continue
	    		}

	    		found := false
	    		for exc in g_state.window_filters {
	    			if exe.exe_name == exc.text {
	    				found = true
	    				break
	    			}
	    		}

	    		flags : win.UINT = win.MF_STRING | (found ? win.MF_CHECKED : 0)
	    		win.AppendMenuW(excl_menu, flags, win.UINT_PTR(COMMAND_EXCLUDE_APP + index) , exe.exe_name)

	    		append(&already_added_items, exe.exe_name)
	    	}

	    	win.AppendMenuW(excl_menu, win.MF_SEPARATOR, win.UINT_PTR(0), nil)

	    	for ew in g_state.window_filters {
	    		if ew.type == .Exe_Name {
	    			continue
	    		}
	    		win.AppendMenuW(excl_menu, win.MF_STRING | win.MF_GRAYED, win.UINT_PTR(0), ew.text)
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
					exclude_name := g_state.running_windows[exclude_index]

					found_index := -1
					for e, i in g_state.window_filters {
						if exclude_name.exe_name == e.text {
							found_index = i
							break
						}
					}

					if found_index >= 0 {
						delete(g_state.window_filters[found_index].text)
						unordered_remove(&g_state.window_filters, found_index)
					} else {
						ns := make([]u16, len(exclude_name.exe_name))
						size := len(ns) * size_of(u16)
						mem.copy(&ns[0], (transmute(runtime.Raw_Cstring16)exclude_name.exe_name).data, size)
						append(
							&g_state.window_filters,
							Window_Filter{
								type = .Exe_Name,
								text = cstring16(cast([^]u16)&ns[0]),
							}
						)
					}
				}
	    	}
	    }
    }

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}



refresh_running_exes :: proc() {
	clear_running_windows()
	g_state.running_windows = make([dynamic]Running_Window, 0, INIT_RUNNING_WINDOWS_CAP, g_state.alloc)

	for hwnd := win.GetTopWindow(nil); hwnd != nil; hwnd = win.GetWindow(hwnd, win.GW_HWNDNEXT) {
		if !win.IsWindowVisible(hwnd) {
			continue
		}

		style := win.GetWindowLongPtrW(hwnd, win.GWL_STYLE)
		if (style & int(win.WS_THICKFRAME)) == 0 {
			continue
		}

		buff : [STR_BUFF_LEN]u16

		if !query_window_process_exe_name(hwnd, buff[:]) {
			continue
		}

		name, last_slash_index, path_len, name_len := get_exe_name_from_path(buff[:])

		exe_data := make([]u16, path_len, g_state.alloc)
		mem.copy(&exe_data[0], &buff[last_slash_index + 1], name_len * size_of(u16))

		title_len := win.GetWindowTextW(hwnd, &buff[0], STR_BUFF_LEN)
		title_data : []u16
		if title_len > 0 {
			title_data = make([]u16, title_len + 1, g_state.alloc)
			mem.copy(&title_data[0], &buff[0], int(title_len + 1) * size_of(u16))
		}

		append(
			&g_state.running_windows,
			Running_Window{
				exe_name = cstring16(cast([^]u16)&exe_data[0]),
				win_title = title_len > 0 ? cstring16(cast([^]u16)&title_data[0]) : "",
			}
		)
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



clear_running_windows :: proc() {
	vmem.arena_free_all(&g_state.arena)
}



query_window_process_exe_name :: proc(hwnd: win.HWND, buff: []u16) -> (ok: bool) {
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



// buff should contain \0
match_filter_window_title :: proc(filter: Window_Filter, buff: []u16) -> (contains: bool) {
	if filter.type == .Exe_Name {
		return false
	}

	title_len := cast(win.INT)len(buff)

	if filter.count > title_len {
		return false
	}

	if filter.count == 1 || title_len == 1 {
		return false
	}

	raw_f := transmute(runtime.Raw_Cstring16)filter.text

	// fmt.printfln("f: %v (%v), m: %v (%v)", filter, filter.count, buff, title_len)

	end_ind := title_len - filter.count
	for start_ind in 0..=end_ind {
		if mem.compare_ptrs(&raw_f.data[0], &buff[start_ind], int(filter.count - 1)) == 0 {
			return true
		}
	}

	return false
}



write_settings_file :: proc() {
	buff : [STR_BUFF_LEN]u16
	path := win.GetModuleFileNameW(nil, &buff[0], STR_BUFF_LEN)
	_, last_slash_index, _, _ := get_exe_name_from_path(buff[:])
	bbuff : [STR_BUFF_LEN * 2]u8
	utf16.decode_to_utf8(bbuff[:], buff[:last_slash_index + 1])
	dir_path := string(bbuff[:last_slash_index + 1])

	arena_chkpt := vmem.arena_temp_begin(&g_state.arena)
	defer vmem.arena_temp_end(arena_chkpt)

	file_path := str.join({dir_path, CONFIG_FILE_NAME}, "\\", g_state.alloc)

	file, oerr := os.open(file_path, {.Create, .Write, .Trunc})
	assert(oerr == nil, "Failed to open or create settings file")
	defer os.close(file)

	// actual writing
	b := str.builder_make_none(g_state.alloc)
	str.write_string(&b, "[settings]\n")

	str.write_string(&b, "[exclude]\n")
	for excl in g_state.window_filters {
		tmp := fmt.aprintf(
			fmt = "%v %v\n",
			args = {
				EXLUSION_TYPE_TO_RUNE[excl.type],
				excl.text,
			},
			allocator = g_state.alloc
		)
		str.write_string(&b, tmp)
	}
	str.pop_byte(&b)

	final := str.to_string(b)

	_, werr := os.write_string(file, final)
	assert(werr == nil, "Failed to write settings file")
}



load_settings_file :: proc() {
	buff : [STR_BUFF_LEN]u16
	path := win.GetModuleFileNameW(nil, &buff[0], STR_BUFF_LEN)
	_, last_slash_index, _, _ := get_exe_name_from_path(buff[:])
	bbuff : [STR_BUFF_LEN * 2]u8
	utf16.decode_to_utf8(bbuff[:], buff[:last_slash_index + 1])
	dir_path := string(bbuff[:last_slash_index + 1])

	arena_chkpt := vmem.arena_temp_begin(&g_state.arena)
	defer vmem.arena_temp_end(arena_chkpt)

	file_path := str.join({dir_path, CONFIG_FILE_NAME}, "\\", g_state.alloc)

	if !os.exists(file_path) {
		return
	}

	bytes, oerr := os.read_entire_file(file_path, g_state.alloc)
	assert(oerr == nil, "Failed to open or create settings file")
	
	load_state := Config_Load_State.None
	lines := str.split(string(bytes), "\n", g_state.alloc)
	for l in lines {
		switch l {
			case CONFIG_FILE_SECTION_EXCLUDE: {
				load_state = .Exclude
				continue
			}
		}

		switch load_state {
			case .None:
			case .Settings:
			case .Exclude: {
				if l == "" {
					continue
				}

				exclude := str.trim(l, " \n")
				type_rune := exclude[0]
				exclude = exclude[2:]

				type : Exclusion_Type
				switch type_rune {
					case u8(EXLUSION_TYPE_TO_RUNE[.Exe_Name]):     type = .Exe_Name
					case u8(EXLUSION_TYPE_TO_RUNE[.Window_Title]): type = .Window_Title
					case:
						fmt.eprintfln("Unknown leading exclude symbol: %v", rune(type_rune))
						continue
				}

				write_count := utf16.encode_string(buff[:], exclude) + 1
				ns := make([]u16, write_count)
				mem.copy(&ns[0], &buff[0], write_count * 2)
				ns[write_count-1] = 0
				append(
					&g_state.window_filters,
					Window_Filter{
						type  = type,
						text  = cstring16(cast([^]u16)&ns[0]),
						count = auto_cast write_count
					}
				)
			}
		}
	}
}



main :: proc() {
	// arena setup
	arena_err := vmem.arena_init_growing(&g_state.arena)
	assert(arena_err == .None, "Failed to init arena")
	g_state.alloc = vmem.arena_allocator(&g_state.arena)
	defer vmem.arena_destroy(&g_state.arena)

	load_settings_file()

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
	g_state.snap_key = win.VK_MENU // ALT keycode

	hook_handle := win.SetWindowsHookExW(win.WH_MOUSE_LL, hook_on_mouse_event, nil, 0)
	defer win.UnhookWindowsHookEx(hook_handle)

	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) != 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	write_settings_file()
	clear_running_windows()
}
