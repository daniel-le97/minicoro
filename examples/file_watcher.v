module main

import file_watcher

fn main() {
	println('File watcher example - Event-driven API with picoev')
	println('Creating and using file watcher with callbacks...\n')

	watch_directory('.')
}

fn watch_directory(path string) {
	println('Creating watcher for: ${path}')

	watcher := file_watcher.new_watcher(path, on_file_event) or {
		println('Error creating watcher: ${err}')
		return
	}
	defer { watcher.close() }

	println('Watcher created successfully')
	println('File path: ${watcher.path}')
	println('Listening for file system events (callback-based architecture)')
	for {}
}

// Callback function that will be invoked on file events
fn on_file_event(event file_watcher.WatchEvent) {
	println('\nFile event detected:')
	println('  Event: ${event.event}')
	println('  Path: ${event.path}')
	if event.old_path.len > 0 {
		println('  Old path: ${event.old_path}')
	}
}
