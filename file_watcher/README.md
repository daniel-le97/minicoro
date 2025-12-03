# File Watcher Module

A cross-platform file system event watcher for the minicoro green thread runtime.

## Overview

The `file_watcher` module provides a unified API for watching file system changes across different platforms:

- **Windows**: Uses `ReadDirectoryChangesW` API
- **Linux**: Uses `inotify` syscalls
- **Other platforms**: Error on unsupported platforms

## API Reference

### Types

```v
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
```

### Functions

#### `new_watcher(path string) !&FileWatcher`

Creates a new file watcher for the specified directory path.

**Parameters:**

- `path`: Directory path to watch

**Returns:**

- `&FileWatcher`: Watcher instance on success
- Error on failure (e.g., invalid path, permission denied)

**Example:**

```v
mut watcher := file_watcher.new_watcher('.') or {
    println('Error: ${err}')
    return
}
defer { watcher.close() }
```

#### `watch() !WatchEvent`

Blocks waiting for file system changes and returns the next event.

**Returns:**

- `WatchEvent`: The file system event
- Error if watching fails

**Example:**

```v
event := watcher.watch() or {
    println('Error: ${err}')
    break
}

match event.event {
    .created { println('Created: ${event.path}') }
    .modified { println('Modified: ${event.path}') }
    .deleted { println('Deleted: ${event.path}') }
    .renamed { println('Renamed: ${event.old_path} -> ${event.path}') }
}
```

#### `close()`

Closes the file watcher and cleans up resources.

**Example:**

```v
watcher.close()
```

## Integration with Scheduler

The file watcher can be integrated with the minicoro scheduler for concurrent file watching:

```v
import file_watcher
import scheduler {@go}
import minicoro

fn watch_files(path string, co &minicoro.Coro) {
    mut watcher := file_watcher.new_watcher(path) or { return }
    defer { watcher.close() }

    for {
        event := watcher.watch() or { break }

        match event.event {
            .created { println('File created: ${event.path}') }
            .deleted { println('File deleted: ${event.path}') }
            .modified { println('File modified: ${event.path}') }
            .renamed { println('File renamed: ${event.old_path} -> ${event.path}') }
        }

        minicoro.yield(co)
    }
}

fn main() {
    scheduler.run(fn(co &minicoro.Coro) {
        watch_files('.', co)
    })
}
```

## Platform-Specific Notes

### Windows

- Watches entire directory trees by default
- Uses `ReadDirectoryChangesW` completion notifications
- Handles UTF-16 path encoding automatically

### Linux

- Uses `inotify_init` and `inotify_add_watch` syscalls
- Recursively watches subdirectories if configured
- Returns file names in UTF-8 encoding

## Current Limitations

- Basic API structure defined; platform implementations are templates
- Error handling needs refinement for edge cases
- Renamed events not fully parsed on Windows
- Batch event processing not yet implemented

## Future Enhancements

- Full Windows `ReadDirectoryChangesW` parsing
- Full Linux `inotify` implementation
- macOS FSEvents support
- Event batching for high-frequency changes
- Filter patterns for watching specific file types
- Async/await integration
