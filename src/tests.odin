package main

import "core:testing"
import "core:fmt"
import "core:mem"
import "base:runtime"


@test
test_window_title_match :: proc(t: ^testing.T) {
	empty := cstring16("")
	a := cstring16("a")
	aa := cstring16("aa")
	b := cstring16("b")
	aba := cstring16("aba")
	ba := cstring16("ba")

	ableton := cstring16("ableton")
	abletonls := cstring16("ableton live suite")
	suite := cstring16("suite")
	ell := cstring16("ell")
	ps := cstring16("Windows PowerShell")
	Ableton := cstring16("Ableton")
	fp := cstring16("move_resize (C:\\Dev\\move_resize) - File Pilot v0.7.0")

	testing.expect_value(t, filter(empty).count, 1)
	testing.expect_value(t, filter(a).count, 2)
	testing.expect_value(t, filter(aa).count, 3)
	testing.expect_value(t, filter(abletonls).count, 19)

	testing.expect(t, !ts(a, empty))
	testing.expect(t, !ts(empty, empty))
	testing.expect(t, ts(a, a))
	testing.expect(t, ts(a, aa))
	testing.expect(t, !ts(a, b))
	testing.expect(t, ts(ba, aba))
	testing.expect(t, ts(ableton, abletonls))
	testing.expect(t, !ts(ableton, suite))
	testing.expect(t, !ts(suite, ableton))
	testing.expect(t, ts(suite, abletonls))
	testing.expect(t, !ts(Ableton, ps))
	testing.expect(t, ts(ell, ps))
	testing.expect(t, !ts(ell, fp))
}


@(private="file")
filter :: proc(s: cstring16) -> Window_Filter {
	rd := transmute(runtime.Raw_Cstring16)s
	count : i32 = 0
	for {
		if rd.data[count] == 0 {
			break
		}
		count += 1
	}
	count += 1

	return Window_Filter{.Window_Title, s, count}
}


@(private="file")
ts :: proc(f, m: cstring16) -> bool {
	_f := filter(f)
	_m := filter(m)
	rd := transmute(runtime.Raw_Cstring16)_m.text
	buff : [STR_BUFF_LEN]u16
	mem.copy(&buff[0], &rd.data[0], auto_cast _m.count * size_of(u16))
	return match_filter_window_title(_f, buff[:_m.count])
}
