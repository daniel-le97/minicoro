module file_watcher

// macOS implementation using FSEvents (File System Events) API via Objective-C bridge
// Efficient kernel-driven file watching with event callbacks
// Uses file_watcher_darwin.m for CoreServices integration
import time
import os

#flag darwin -framework CoreServices
#flag darwin -framework Foundation
#include "@VMODROOT/file_watcher/file_watcher_darwin.m"

// C function declarations to Objective-C bridge
fn C.darwin_create_fsevents_stream(watcher_data voidptr, path &u8) voidptr
fn C.darwin_create_and_schedule_stream(watcher_data voidptr, path &u8)
fn C.darwin_schedule_stream(stream_ref voidptr, watcher_data_ptr voidptr)
fn C.darwin_start_stream(stream_ref voidptr) bool
fn C.darwin_stop_stream(stream_ref voidptr)
fn C.darwin_run_loop_run()
fn C.darwin_run_loop_stop()
fn C.darwin_set_event_callback(callback voidptr)

// Type for the C callback
type DarwinEventCallback = fn (watcher_ptr voidptr, event_type int, path string)

struct MacOSWatcherData {
mut:
	stream_ref  voidptr
	watcher_ptr voidptr // Reference back to FileWatcher
	path        string
	running     bool
}

// Global state manager for Darwin file watchers
pub struct DarwinWatcherState {
mut:
	running             bool
	runloop             voidptr // CFRunLoopRef
	watchers            []&MacOSWatcherData
	pending_to_schedule []&MacOSWatcherData // Streams waiting to be scheduled on runloop
	pending_paths       []string            // Paths to create streams for
}

pub const state = &DarwinWatcherState{}

pub fn (mut s DarwinWatcherState) add_watcher(wd &MacOSWatcherData) {
	s.watchers << wd
}

pub fn (mut s DarwinWatcherState) remove_watcher(wd &MacOSWatcherData) {
	for i, w in s.watchers {
		if w == wd {
			s.watchers.delete(i)
			break
		}
	}
}

pub fn (mut s DarwinWatcherState) shutdown() {
	s.running = false
}

// Single event handler called from Objective-C callback
pub fn darwin_on_fsevents_event(watcher_ptr voidptr, event_type int, path string) {
	// Guard against nil watcher (can happen during initialization)
	if watcher_ptr == unsafe { nil } {
		return
	}

	println('[V Callback] Event type ${event_type} at ${path}')

	watcher := unsafe { &FileWatcher(watcher_ptr) }

	// Map event_type int back to FileEvent enum
	event_enum := match event_type {
		0 { FileEvent.created }
		1 { FileEvent.modified }
		2 { FileEvent.deleted }
		3 { FileEvent.renamed }
		else { FileEvent.modified }
	}

	event := WatchEvent{
		event:    event_enum
		path:     path
		old_path: ''
	}

	callback := watcher.callback
	unsafe {
		if callback != nil {
			callback(event)
		}
	}
}

// Background thread that runs the CFRunLoop for FSEvents
fn (mut s DarwinWatcherState) run_loop_thread() {
	println('[run_loop_thread] Started, waiting for streams to create')

	// Wait for at least one stream to be pending
	for s.pending_to_schedule.len == 0 && s.running {
		time.sleep(10 * time.millisecond)
	}

	if !s.running {
		return
	}

	println('[run_loop_thread] Creating and scheduling ${s.pending_to_schedule.len} streams')

	// Create and schedule all pending streams on this runloop
	for wd in s.pending_to_schedule {
		println('[run_loop_thread] Creating stream for: ${wd.path}')
		abs_path := if wd.path.starts_with('/') { wd.path } else { os.getwd() + '/' + wd.path }
		C.darwin_create_and_schedule_stream(unsafe { voidptr(wd) }, abs_path.str)
	}
	s.pending_to_schedule.clear()

	println('[run_loop_thread] Starting CFRunLoop')
	C.darwin_run_loop_run()
	println('[run_loop_thread] CFRunLoop exited')
}

// macOS implementation of new_watcher using FSEvents
pub fn new_watcher(path string, callback EventCallback) !&FileWatcher {
	// Initialize global runloop (once)
	mut gs := unsafe { state }
	if !gs.running {
		gs.running = true
		C.darwin_set_event_callback(voidptr(darwin_on_fsevents_event))
		// Start the runloop thread (it will wait for pending streams)
		spawn gs.run_loop_thread()
	}

	mut watcher := &FileWatcher{
		path:     path
		callback: callback
	}

	mut watcher_data := &MacOSWatcherData{
		stream_ref:  unsafe { nil }
		watcher_ptr: unsafe { voidptr(watcher) }
		path:        path
		running:     true
	}

	// Add to watchers list
	gs.add_watcher(watcher_data)

	// Queue for creation and scheduling on runloop (will be created before runloop starts)
	gs.pending_to_schedule << watcher_data

	watcher.data = unsafe { voidptr(watcher_data) }

	return watcher
}

pub fn (w &FileWatcher) close() {
	if w.data != unsafe { nil } {
		mut watcher_data := unsafe { &MacOSWatcherData(w.data) }

		// Mark as stopped
		watcher_data.running = false

		// Stop and release FSEvents stream
		if watcher_data.stream_ref != unsafe { nil } {
			C.darwin_stop_stream(watcher_data.stream_ref)
			C.darwin_run_loop_stop()
		}

		// Remove from global list
		mut gs := unsafe { state }
		gs.remove_watcher(watcher_data)
		gs.shutdown()
	}
}
