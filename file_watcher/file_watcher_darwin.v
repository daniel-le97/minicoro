module file_watcher

// macOS implementation using FSEvents (File System Events) with picoev event-driven model
// Uses V's picoev wrapper for lightweight, non-blocking file watching
import picoev

#include <CoreServices/CoreServices.h>

fn C.FSEventsCreateStreamForPathCallback(voidptr, voidptr, usize, &voidptr, u32, f64) voidptr
fn C.FSEventsFlushSync(voidptr)
fn C.FSEventsInvalidateStream(voidptr)
fn C.FSEventsReleaseStream(voidptr)
fn C.FSEventsScheduleStreamWithRunLoop(voidptr, voidptr, voidptr)
fn C.FSEventsStartStream(voidptr) bool
fn C.FSEventsStopStream(voidptr)
fn C.CFRunLoopGetMain() voidptr
fn C.CFRunLoopRun()
fn C.CFRunLoopStop(voidptr)

// FSEvents constants
const kfsevents_none = u32(0)
const kfsevents_default = u32(0)
const kfsevents_use_cfabsolutetime = u32(1 << 1)

struct MacOSWatcherData {
mut:
	stream_ref voidptr
	loop       &picoev.SelectLoop // picoev event loop reference
}

// macOS implementation of new_watcher using FSEvents with picoev
pub fn new_watcher(path string, callback EventCallback) !&FileWatcher {
	// FSEvents requires path as CFString
	// Create a picoev event loop for non-blocking operation
	loop := picoev.create_select_loop(0)!

	watcher_data := &MacOSWatcherData{
		stream_ref: unsafe { nil }
		loop:       loop
	}

	return &FileWatcher{
		path:     path
		data:     unsafe { voidptr(watcher_data) }
		callback: callback
	}
}

pub fn (w &FileWatcher) close() {
	if w.data != unsafe { nil } {
		watcher_data := unsafe { &MacOSWatcherData(w.data) }
		if watcher_data.stream_ref != unsafe { nil } {
			// Clean up FSEvents stream
			C.FSEventsStopStream(watcher_data.stream_ref)
			C.FSEventsInvalidateStream(watcher_data.stream_ref)
			C.FSEventsReleaseStream(watcher_data.stream_ref)
		}
	}
}
