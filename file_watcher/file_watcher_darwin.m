#include <CoreServices/CoreServices.h>
#include <Foundation/Foundation.h>
#include <string.h>
#include <limits.h>

// V struct definitions
typedef struct {
    void *stream_ref;
    void *watcher_ptr;
    u64 last_event_id;
} darwin__MacOSWatcherData;

// Callback function pointer type
typedef void (*FSEventsCallback)(void *watcher_ptr, int event_type, string path);

// Global callback function pointer
static FSEventsCallback g_fsevents_callback = NULL;

// FSEvents callback
static void fsevents_callback(ConstFSEventStreamRef streamRef,
                              void *clientCallBackInfo,
                              size_t numEvents,
                              void *eventPaths,
                              const FSEventStreamEventFlags eventFlags[],
                              const FSEventStreamEventId eventIds[]) {
    printf("[fsevents_callback] Called with %zu events, clientCallBackInfo: %p\n", numEvents, clientCallBackInfo);

    if (!clientCallBackInfo) {
        printf("[fsevents_callback] ERROR: clientCallBackInfo is NULL\n");
        return;
    }

    if (!g_fsevents_callback) {
        printf("[fsevents_callback] ERROR: g_fsevents_callback is NULL\n");
        return;
    }

    // clientCallBackInfo is the watcher_data pointer we passed
    darwin__MacOSWatcherData *wd = (darwin__MacOSWatcherData *)clientCallBackInfo;
    void *watcher = wd->watcher_ptr;

    printf("[fsevents_callback] wd: %p, watcher: %p\n", wd, watcher);

    // Get the paths array (CFArray of CFStrings)
    CFArrayRef paths = (CFArrayRef)eventPaths;

    // Process events - iterate through paths
    for (size_t i = 0; i < numEvents; i++) {
        FSEventStreamEventFlags flags = eventFlags[i];

        // Get the path string for this event
        CFStringRef pathRef = CFArrayGetValueAtIndex(paths, i);
        const char *pathCStr = CFStringGetCStringPtr(pathRef, kCFStringEncodingUTF8);
        if (!pathCStr) {
            printf("[fsevents_callback] Could not get C string for path\n");
            continue;
        }

        size_t pathLen = strlen(pathCStr);
        string path = {(u8 *)pathCStr, (int)pathLen};

        // Determine event type from flags
        int event_type = -1;
        if (flags & kFSEventStreamEventFlagItemCreated) {
            event_type = 0; // FileEvent.created
        } else if (flags & kFSEventStreamEventFlagItemRemoved) {
            event_type = 2; // FileEvent.deleted
        } else if (flags & kFSEventStreamEventFlagItemModified) {
            event_type = 1; // FileEvent.modified
        } else if (flags & kFSEventStreamEventFlagItemRenamed) {
            event_type = 3; // FileEvent.renamed
        }

        if (event_type >= 0) {
            printf("[FSEvents] Event type %d at %s (flags: %u)\n", event_type, pathCStr, flags);
            g_fsevents_callback(watcher, event_type, path);
        } else {
            printf("[FSEvents] Event at %s with flags: %u (not matched to type)\n", pathCStr, flags);
        }
    }
}

// Set the callback function pointer
void darwin_set_event_callback(FSEventsCallback callback) {
    printf("[darwin_set_event_callback] Setting callback: %p\n", callback);
    g_fsevents_callback = callback;
}

// Create FSEvents stream for a path
void *darwin_create_fsevents_stream(void *watcher_data, const char *path) {
    printf("[darwin_create_fsevents_stream] Creating stream for path: %s\n", path);
    printf("[darwin_create_fsevents_stream] Passing watcher_data: %p\n", watcher_data);

    if (!path) {
        printf("[darwin_create_fsevents_stream] ERROR: path is NULL\n");
        return NULL;
    }

    // Create an array with the path
    CFStringRef pathStr = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (!pathStr) {
        printf("[darwin_create_fsevents_stream] ERROR: Failed to create CFString from path\n");
        return NULL;
    }

    CFMutableArrayRef pathsArray = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    if (!pathsArray) {
        printf("[darwin_create_fsevents_stream] ERROR: Failed to create CFArray\n");
        CFRelease(pathStr);
        return NULL;
    }

    CFArrayAppendValue(pathsArray, pathStr);
    CFRelease(pathStr);  // The array keeps a reference

    printf("[darwin_create_fsevents_stream] About to create FSEventStream\n");

    FSEventStreamRef stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        fsevents_callback,
        (void *)watcher_data,  // Pass watcher_data directly as clientCallBackInfo
        pathsArray,
        kFSEventStreamEventIdSinceNow,
        0.1,
        kFSEventStreamCreateFlagNoDefer
    );

    CFRelease(pathsArray);

    if (stream) {
        printf("[darwin_create_fsevents_stream] Stream created successfully: %p\n", stream);
    } else {
        printf("[darwin_create_fsevents_stream] ERROR: FSEventStreamCreate returned NULL\n");
    }

    return (void *)stream;
}

// Global run loop reference
static CFRunLoopRef g_runloop = NULL;

// Store pending stream creation requests
typedef struct {
    const char *path;
    void *watcher_data;
} StreamCreationRequest;

// Create stream on the runloop thread
static void create_stream_on_runloop(StreamCreationRequest *req) {
    if (!req || !req->path || !req->watcher_data) {
        printf("[create_stream_on_runloop] Invalid request\n");
        return;
    }

    printf("[create_stream_on_runloop] Creating stream for: %s\n", req->path);

    CFStringRef pathStr = CFStringCreateWithCString(kCFAllocatorDefault, req->path, kCFStringEncodingUTF8);
    CFMutableArrayRef pathsArray = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(pathsArray, pathStr);
    CFRelease(pathStr);

    FSEventStreamRef stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        fsevents_callback,
        req->watcher_data,
        pathsArray,
        kFSEventStreamEventIdSinceNow,
        0.1,
        kFSEventStreamCreateFlagNoDefer
    );

    CFRelease(pathsArray);

    if (stream) {
        printf("[create_stream_on_runloop] Stream created: %p, scheduling\n", stream);
        FSEventStreamScheduleWithRunLoop(stream, g_runloop, kCFRunLoopDefaultMode);
        FSEventStreamStart(stream);
        printf("[create_stream_on_runloop] Stream started\n");

        // Store the stream in the watcher data
        darwin__MacOSWatcherData *wd = (darwin__MacOSWatcherData *)req->watcher_data;
        wd->stream_ref = stream;
    } else {
        printf("[create_stream_on_runloop] ERROR: FSEventStreamCreate failed\n");
    }
}// Start stream
bool darwin_start_stream(void *stream_ref) {
    FSEventStreamRef stream = (FSEventStreamRef)stream_ref;
    return FSEventStreamStart(stream);
}

// Stop and release stream
void darwin_stop_stream(void *stream_ref) {
    FSEventStreamRef stream = (FSEventStreamRef)stream_ref;
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
}

// Create stream on the runloop thread (called from runloop thread context)
void darwin_create_and_schedule_stream(void *watcher_data, const char *path) {
    printf("[darwin_create_and_schedule_stream] Called with path: %s, watcher_data: %p\n", path, watcher_data);

    // Resolve path to avoid issues with "."
    char resolved_path[PATH_MAX];
    if (realpath(path, resolved_path) == NULL) {
        // If realpath fails, just use the provided path
        strcpy(resolved_path, path);
    }

    printf("[darwin_create_and_schedule_stream] Resolved path: %s\n", resolved_path);

    CFStringRef pathStr = CFStringCreateWithCString(kCFAllocatorDefault, resolved_path, kCFStringEncodingUTF8);
    if (!pathStr) {
        printf("[darwin_create_and_schedule_stream] ERROR: Failed to create CFString\n");
        return;
    }

    CFMutableArrayRef pathsArray = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    if (!pathsArray) {
        printf("[darwin_create_and_schedule_stream] ERROR: Failed to create mutable array\n");
        CFRelease(pathStr);
        return;
    }

    CFArrayAppendValue(pathsArray, pathStr);
    CFRelease(pathStr);

    printf("[darwin_create_and_schedule_stream] About to create FSEventStream with resolved path\n");
    fflush(stdout);

    FSEventStreamRef stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        fsevents_callback,
        watcher_data,
        pathsArray,
        kFSEventStreamEventIdSinceNow,
        0.1,
        kFSEventStreamCreateFlagNoDefer
    );

    CFRelease(pathsArray);

    if (!stream) {
        printf("[darwin_create_and_schedule_stream] ERROR: FSEventStreamCreate returned NULL\n");
        return;
    }

    printf("[darwin_create_and_schedule_stream] Stream created: %p\n", stream);
    printf("[darwin_create_and_schedule_stream] Scheduling on runloop: %p\n", g_runloop);

    FSEventStreamScheduleWithRunLoop(stream, g_runloop, kCFRunLoopDefaultMode);
    FSEventStreamStart(stream);

    printf("[darwin_create_and_schedule_stream] Stream started\n");

    // Store stream reference in watcher_data
    darwin__MacOSWatcherData *wd = (darwin__MacOSWatcherData *)watcher_data;
    wd->stream_ref = (void *)stream;
}

// Run the CFRunLoop
void darwin_run_loop_run() {
    printf("[darwin_run_loop_run] Getting current runloop\n");
    CFRunLoopRef runloop = CFRunLoopGetCurrent();
    g_runloop = runloop;
    printf("[darwin_run_loop_run] Starting CFRunLoop %p\n", runloop);
    CFRunLoopRun();
    printf("[darwin_run_loop_run] CFRunLoop stopped\n");
}

// Stop the CFRunLoop
void darwin_run_loop_stop() {
    if (g_runloop) {
        CFRunLoopStop(g_runloop);
    }
}
