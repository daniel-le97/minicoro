module file_watcher

import sync

// File watching events
pub enum FileEvent {
	created
	modified
	deleted
	renamed
}

pub struct WatchEvent {
pub:
	event    FileEvent
	path     string
	old_path string // For renamed events
}

// Callback function for file system events (non-blocking, event-driven with picoev)
pub type EventCallback = fn (event WatchEvent)

// FileWatcher is the main watcher struct (non-blocking, event-driven with picoev)
// Uses picoev's event loop for lightweight event-driven architecture
// Platform-specific implementations are in file_watcher_windows.v, file_watcher_linux.v, etc.
pub struct FileWatcher {
pub mut:
	path     string
	data     voidptr // Platform-specific implementation data
	callback EventCallback = unsafe { nil }
	mu       sync.Mutex
}

// Type definitions and shared structures for file watching
