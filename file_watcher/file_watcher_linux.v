module file_watcher

// Linux-specific implementation using inotify with picoev event-driven model
// Uses V's picoev wrapper for lightweight, non-blocking file watching
import picoev

#include <sys/inotify.h>
#include <unistd.h>
#include <string.h>

fn C.inotify_init() int
fn C.inotify_add_watch(fd int, path &char, mask u32) int
fn C.inotify_rm_watch(fd int, wd int) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.close(fd int) int

const in_create = 0x00000100
const in_delete = 0x00000200
const in_modify = 0x00000002
const in_moved = 0x00000040
const in_attrib = 0x00000004
const in_close_write = 0x00000008
const buf_len = 4096

// inotify_event structure from Linux headers
struct InotifyEvent {
	wd     int
	mask   u32
	cookie u32
	len    u32
	name   [256]char
}

struct LinuxWatcherData {
	fd   int
	wd   int
	loop &picoev.SelectLoop // picoev event loop reference
}

// Linux implementation of new_watcher using inotify with picoev
pub fn new_watcher(path string, callback EventCallback) !&FileWatcher {
	fd := C.inotify_init()
	if fd < 0 {
		return error('Failed to initialize inotify: fd=${fd}')
	}

	mask := in_create | in_delete | in_modify | in_moved | in_attrib | in_close_write
	wd := C.inotify_add_watch(fd, path.str, mask)

	if wd < 0 {
		C.close(fd)
		return error('Failed to add inotify watch')
	}

	// Create a picoev event loop for non-blocking operation
	loop := picoev.create_select_loop(0)!

	platform_data := &LinuxWatcherData{
		fd:   fd
		wd:   wd
		loop: loop
	}

	return &FileWatcher{
		path:     path
		data:     unsafe { voidptr(platform_data) }
		callback: callback
	}
}

pub fn (w &FileWatcher) close() {
	if w.data != unsafe { nil } {
		platform_data := unsafe { &LinuxWatcherData(w.data) }
		if platform_data.fd >= 0 {
			if platform_data.wd >= 0 {
				C.inotify_rm_watch(platform_data.fd, platform_data.wd)
			}
			C.close(platform_data.fd)
		}
	}
}
