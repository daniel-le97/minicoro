module file_watcher

// Windows-specific implementation using ReadDirectoryChangesW with threading model
// Detects file changes and fires callbacks in real-time
import picoev

#include <windows.h>

fn C.CreateFileW(&u16, u32, u32, voidptr, u32, u32, voidptr) voidptr
fn C.ReadDirectoryChangesW(voidptr, voidptr, u32, bool, u32, &u32, voidptr, voidptr) bool
fn C.CloseHandle(voidptr) bool
fn C.GetLastError() u32

const file_list_directory = 0x0001
const file_notify_change_file_name = 0x00000001
const file_notify_change_dir_name = 0x00000002
const file_notify_change_last_write = 0x00000010
const file_notify_change_size = 0x00000008
const open_existing = 3
const file_flag_backup_semantics = 0x02000000
const invalid_handle_value = -1
const file_action_added = 1
const file_action_removed = 2
const file_action_modified = 3
const file_action_renamed_old_name = 4
const file_action_renamed_new_name = 5

struct WindowsWatcherData {
mut:
	dir_handle          voidptr
	loop                &picoev.SelectLoop // picoev event loop reference
	running             bool               // Whether the watcher thread is running
	pending_rename_from string             // Track the "from" name for rename events
}

// Windows implementation of new_watcher using ReadDirectoryChangesW with threading
pub fn new_watcher(path string, callback EventCallback) !&FileWatcher {
	// Convert path to UTF-16 for Windows API
	path_u16 := path.to_wide()

	// Open directory handle
	handle := C.CreateFileW(path_u16, file_list_directory, 3, // FILE_SHARE_READ | FILE_SHARE_WRITE
	 unsafe { nil }, open_existing, file_flag_backup_semantics, unsafe { nil })

	if handle == unsafe { voidptr(invalid_handle_value) } {
		return error('Failed to open directory: ${C.GetLastError()}')
	}

	// Create a picoev event loop
	loop := picoev.create_select_loop(0)!

	mut watcher := &FileWatcher{
		path:     path
		callback: callback
	}

	watcher_data := &WindowsWatcherData{
		dir_handle: handle
		loop:       loop
		running:    true
	}

	watcher.data = unsafe { voidptr(watcher_data) }

	// Start watching thread
	spawn watch_thread(watcher)

	return watcher
}

// Background thread that monitors directory changes
fn watch_thread(watcher &FileWatcher) {
	if watcher.data == unsafe { nil } {
		return
	}

	watcher_data := unsafe { &WindowsWatcherData(watcher.data) }
	mut buffer := [8192]u8{}
	mut bytes_returned := u32(0)

	for watcher_data.running {
		// Block waiting for changes
		success := C.ReadDirectoryChangesW(watcher_data.dir_handle, unsafe { &buffer[0] },
			buffer.len, false, file_notify_change_file_name | file_notify_change_dir_name | file_notify_change_last_write | file_notify_change_size,
			&bytes_returned, unsafe { nil }, unsafe { nil })

		if !success {
			break
		}

		if bytes_returned > 0 {
			parse_and_fire_event(watcher, unsafe { &buffer[0] }, bytes_returned)
		}
	}
}

// Parse FILE_NOTIFY_INFORMATION and fire callback
fn parse_and_fire_event(watcher &FileWatcher, buffer_ptr voidptr, bytes_returned u32) {
	watcher_data := unsafe { &WindowsWatcherData(watcher.data) }

	unsafe {
		mut offset := u32(0)

		// Process all FILE_NOTIFY_INFORMATION structures in the buffer
		for offset < bytes_returned {
			current_ptr := voidptr(usize(buffer_ptr) + offset)

			// Safely read the FILE_NOTIFY_INFORMATION structure
			// typedef struct _FILE_NOTIFY_INFORMATION {
			//   DWORD NextEntryOffset;  // offset 0
			//   DWORD Action;           // offset 4
			//   DWORD FileNameLength;   // offset 8
			//   WCHAR FileName[1];      // offset 12 (UTF-16 string)
			// }
			if bytes_returned - offset < 12 {
				// Not enough bytes for minimum structure
				break
			}

			next_offset := &u32(current_ptr)
			action := &u32(voidptr(usize(current_ptr) + 4))
			filename_len_bytes := &u32(voidptr(usize(current_ptr) + 8))

			// Extract filename from buffer with bounds checking
			mut filename := ''
			if *filename_len_bytes > 0 && *filename_len_bytes <= bytes_returned - offset - 12 {
				filename_ptr := voidptr(usize(current_ptr) + 12)
				filename_len := int(*filename_len_bytes / 2) // Convert bytes to chars (UTF-16 is 2 bytes per char)
				if filename_len > 0 && filename_len < 2048 {
					mut filename_chars := ''
					for i in 0 .. filename_len {
						char_val := (&u16(filename_ptr))[i]
						if char_val == 0 {
							break
						}
						// Convert UTF-16 char to ASCII (simple conversion for ASCII range)
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
					// Store the old name for the next rename event
					watcher_data.pending_rename_from = full_path
				}
				file_action_renamed_new_name {
					// Now we have both old and new names, fire the rename event
					if watcher_data.pending_rename_from.len > 0 {
						event_to_fire := WatchEvent{
							event:    FileEvent.renamed
							path:     full_path                        // new name
							old_path: watcher_data.pending_rename_from // old name
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

			// Move to next entry
			if *next_offset == 0 {
				break
			}
			offset += *next_offset
		}
	}
}

pub fn (w &FileWatcher) close() {
	if w.data != unsafe { nil } {
		mut watcher_data := unsafe { &WindowsWatcherData(w.data) }
		watcher_data.running = false
		if watcher_data.dir_handle != unsafe { nil } {
			C.CloseHandle(watcher_data.dir_handle)
		}
	}
}
