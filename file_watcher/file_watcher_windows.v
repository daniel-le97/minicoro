module file_watcher

// Windows-specific implementation using I/O Completion Ports (IOCP)
// Single background thread efficiently handles multiple watchers using overlapped I/O
// IOCP automatically batches notifications from the kernel

#include <windows.h>

// IOCP API functions
fn C.CreateIoCompletionPort(voidptr, voidptr, u64, u32) voidptr
fn C.GetQueuedCompletionStatus(voidptr, &u32, &u64, &voidptr, u32) bool
fn C.PostQueuedCompletionStatus(voidptr, u32, u64, voidptr) bool
fn C.CreateEventW(voidptr, bool, bool, &u16) voidptr
fn C.CreateFileW(&u16, u32, u32, voidptr, u32, u32, voidptr) voidptr
fn C.ReadDirectoryChangesW(voidptr, voidptr, u32, bool, u32, &u32, voidptr, voidptr) bool
fn C.CloseHandle(voidptr) bool
fn C.ResetEvent(voidptr) bool
fn C.GetLastError() u32

const file_list_directory = 0x0001
const file_notify_change_file_name = 0x00000001
const file_notify_change_dir_name = 0x00000002
const file_notify_change_last_write = 0x00000010
const file_notify_change_size = 0x00000008
const open_existing = 3
const file_flag_backup_semantics = 0x02000000
const file_flag_overlapped = 0x40000000
const invalid_handle_value = -1
const file_action_added = 1
const file_action_removed = 2
const file_action_modified = 3
const file_action_renamed_old_name = 4
const file_action_renamed_new_name = 5

// OVERLAPPED structure for async I/O
struct OVERLAPPED {
mut:
	internal      voidptr
	internal_high voidptr
	offset        u32
	offset_high   u32
	h_event       voidptr
}

struct WindowsWatcherData {
mut:
	dir_handle          voidptr
	overlapped          OVERLAPPED
	buffer              [8192]u8
	pending_rename_from string
	watcher_ptr         voidptr // Reference back to FileWatcher
}

// Global state manager for IOCP
pub struct IOCPGlobalState {
mut:
	handle   voidptr
	running  bool
	watchers []&WindowsWatcherData
}

pub const state = &IOCPGlobalState{}

pub fn (mut s IOCPGlobalState) init_iocp() !voidptr {
	if s.handle != unsafe { nil } {
		return s.handle
	}

	// Create IOCP with default thread count
	handle := C.CreateIoCompletionPort(unsafe { voidptr(-1) }, unsafe { nil }, 0, 0)
	if handle == unsafe { nil } {
		return error('Failed to create IOCP: ${C.GetLastError()}')
	}

	s.handle = handle
	s.running = true

	// Start background thread to pump IOCP events
	spawn s.pump_iocp_events()

	return handle
}

pub fn (s &IOCPGlobalState) get_handle() voidptr {
	return s.handle
}

pub fn (mut s IOCPGlobalState) add_watcher(wd &WindowsWatcherData) {
	s.watchers << wd
}

pub fn (mut s IOCPGlobalState) remove_watcher(wd &WindowsWatcherData) {
	for i, w in s.watchers {
		if w == wd {
			s.watchers.delete(i)
			break
		}
	}
}

pub fn (s &IOCPGlobalState) get_watchers() []&WindowsWatcherData {
	return s.watchers
}

pub fn (mut s IOCPGlobalState) shutdown() {
	s.running = false
}

// Background thread that pumps IOCP completion events
fn (mut s IOCPGlobalState) pump_iocp_events() {
	iocp := s.handle

	for s.running {
		mut bytes_transferred := u32(0)
		mut completion_key := u64(0)
		mut overlapped_ptr := unsafe { nil }

		// Wait for completion with 100ms timeout
		success := C.GetQueuedCompletionStatus(iocp, &bytes_transferred, &completion_key,
			&overlapped_ptr, 100)

		if !success {
			continue
		}

		if overlapped_ptr != unsafe { nil } {
			overlapped := unsafe { &OVERLAPPED(overlapped_ptr) }
			// Find watcher data from overlapped structure by searching the list
			for watcher_data in s.watchers {
				if unsafe { &watcher_data.overlapped } == overlapped {
					process_iocp_completion(watcher_data, bytes_transferred) or {
						eprintln('Error processing IOCP: ${err}')
					}
					break
				}
			}
		}
	}
}

// Windows implementation of new_watcher using IOCP with overlapped I/O
pub fn new_watcher(path string, callback EventCallback) !&FileWatcher {
	// Initialize global IOCP
	mut gs := unsafe { state }
	_ := gs.init_iocp()!

	// Convert path to UTF-16 for Windows API
	path_u16 := path.to_wide()

	// Open directory handle with overlapped flag
	handle := C.CreateFileW(path_u16, file_list_directory, 3, unsafe { nil }, open_existing,
		file_flag_backup_semantics | file_flag_overlapped, unsafe { nil })

	if handle == unsafe { voidptr(invalid_handle_value) } {
		return error('Failed to open directory: ${C.GetLastError()}')
	}

	mut watcher := &FileWatcher{
		path:     path
		callback: callback
	}

	mut watcher_data := &WindowsWatcherData{
		dir_handle:  handle
		watcher_ptr: unsafe { voidptr(watcher) }
	}

	// Create event for the OVERLAPPED structure
	event := C.CreateEventW(unsafe { nil }, true, false, unsafe { nil })
	if event == unsafe { nil } {
		C.CloseHandle(handle)
		return error('Failed to create event: ${C.GetLastError()}')
	}
	watcher_data.overlapped.h_event = event

	watcher.data = unsafe { voidptr(watcher_data) }

	// Associate the directory handle with IOCP
	iocp := gs.get_handle()
	result := C.CreateIoCompletionPort(handle, iocp, 0, 0)
	if result == unsafe { nil } {
		C.CloseHandle(handle)
		C.CloseHandle(event)
		return error('Failed to associate with IOCP: ${C.GetLastError()}')
	}

	// Add to global watcher list
	gs.add_watcher(watcher_data)

	// Issue first async read
	issue_directory_watch(watcher_data)!

	return watcher
}

// Issue an async ReadDirectoryChangesW
fn issue_directory_watch(watcher_data &WindowsWatcherData) ! {
	success := C.ReadDirectoryChangesW(watcher_data.dir_handle, unsafe { &watcher_data.buffer[0] },
		watcher_data.buffer.len, false, file_notify_change_file_name | file_notify_change_dir_name | file_notify_change_last_write | file_notify_change_size,
		unsafe { nil }, unsafe { &watcher_data.overlapped }, unsafe { nil })

	if !success {
		err := C.GetLastError()
		// ERROR_IO_PENDING (997) is expected for async I/O
		if err != 997 {
			return error('ReadDirectoryChangesW failed: ${err}')
		}
	}
}

// Process completion from IOCP
fn process_iocp_completion(watcher_data &WindowsWatcherData, bytes_transferred u32) ! {
	if bytes_transferred == 0 {
		return
	}

	watcher := unsafe { &FileWatcher(watcher_data.watcher_ptr) }

	unsafe {
		mut offset := u32(0)
		buffer_ptr := &watcher_data.buffer[0]

		// Process all FILE_NOTIFY_INFORMATION structures in the buffer
		for offset < bytes_transferred {
			current_ptr := voidptr(usize(buffer_ptr) + offset)

			// Safely read the FILE_NOTIFY_INFORMATION structure
			// typedef struct _FILE_NOTIFY_INFORMATION {
			//   DWORD NextEntryOffset;  // offset 0
			//   DWORD Action;           // offset 4
			//   DWORD FileNameLength;   // offset 8
			//   WCHAR FileName[1];      // offset 12 (UTF-16 string)
			// }
			if bytes_transferred - offset < 12 {
				break
			}

			next_offset := &u32(current_ptr)
			action := &u32(voidptr(usize(current_ptr) + 4))
			filename_len_bytes := &u32(voidptr(usize(current_ptr) + 8))

			// Extract filename from buffer with bounds checking
			mut filename := ''
			if *filename_len_bytes > 0 && *filename_len_bytes <= bytes_transferred - offset - 12 {
				filename_ptr := voidptr(usize(current_ptr) + 12)
				filename_len := int(*filename_len_bytes / 2)
				if filename_len > 0 && filename_len < 2048 {
					mut filename_chars := ''
					for i in 0 .. filename_len {
						char_val := (&u16(filename_ptr))[i]
						if char_val == 0 {
							break
						}
						if char_val < 128 {
							filename_chars += rune(char_val).str()
						}
					}
					filename = filename_chars
				}
			}

			full_path := if filename.len > 0 {
				'${watcher.path}\\${filename}'
			} else {
				watcher.path
			}

			// Handle different action types
			match *action {
				file_action_added {
					event_to_fire := WatchEvent{
						event:    FileEvent.created
						path:     full_path
						old_path: ''
					}
					callback := watcher.callback
					if callback != nil {
						callback(event_to_fire)
					}
				}
				file_action_removed {
					event_to_fire := WatchEvent{
						event:    FileEvent.deleted
						path:     full_path
						old_path: ''
					}
					callback := watcher.callback
					if callback != nil {
						callback(event_to_fire)
					}
				}
				file_action_modified {
					event_to_fire := WatchEvent{
						event:    FileEvent.modified
						path:     full_path
						old_path: ''
					}
					callback := watcher.callback
					if callback != nil {
						callback(event_to_fire)
					}
				}
				file_action_renamed_old_name {
					watcher_data.pending_rename_from = full_path
				}
				file_action_renamed_new_name {
					if watcher_data.pending_rename_from.len > 0 {
						event_to_fire := WatchEvent{
							event:    FileEvent.renamed
							path:     full_path
							old_path: watcher_data.pending_rename_from
						}
						callback := watcher.callback
						if callback != nil {
							callback(event_to_fire)
						}
						watcher_data.pending_rename_from = ''
					}
				}
				else {}
			}

			if *next_offset == 0 {
				break
			}
			offset += *next_offset
		}
	}
	// Reissue the watch for the next batch of changes
	issue_directory_watch(watcher_data)!
}

pub fn (w &FileWatcher) close() {
	if w.data != unsafe { nil } {
		watcher_data := unsafe { &WindowsWatcherData(w.data) }

		// Remove from global list
		mut gs := unsafe { state }
		gs.remove_watcher(watcher_data)

		if watcher_data.dir_handle != unsafe { nil } {
			C.CloseHandle(watcher_data.dir_handle)
		}
		if watcher_data.overlapped.h_event != unsafe { nil } {
			C.CloseHandle(watcher_data.overlapped.h_event)
		}
	}
}
