#include <assert.h>
#if defined(__linux__) || defined(__APPLE__)
#include <pthread.h>
#endif
#ifdef _WIN64
#include <windows.h>
#endif

// **i have no idea what this does, i copied this from vlibs coroutine module**

// NOTE `sp_corrector` only works for platforms with the stack growing down
// MacOs, iOS, Win32, Linux, and Android always have stack growing down.
// A proper solution is planned (hopefully) for boehm v8.4.0.
static void sp_corrector(void **sp_ptr, void *tid)
{
    size_t stack_size = 0;
    char *stack_addr = NULL;

#if defined(__APPLE__) && !TARGET_OS_IPHONE
    // macOS
    stack_size = pthread_get_stacksize_np((pthread_t)tid);
    stack_addr = (char *)pthread_get_stackaddr_np((pthread_t)tid);
#elif defined(__APPLE__) && TARGET_OS_IPHONE
    // iOS
    stack_size = pthread_get_stacksize_np((pthread_t)tid);
    stack_addr = (char *)pthread_get_stackaddr_np((pthread_t)tid);
#elif defined(_WIN64)
    // Windows
    ULONG_PTR stack_low, stack_high;
    GetCurrentThreadStackLimits(&stack_low, &stack_high);
    stack_size = stack_high - stack_low;
    stack_addr = (char *)stack_low;
#elif defined(__linux__)
    // Linux and Android
    pthread_attr_t gattr;
    if (pthread_getattr_np((pthread_t)tid, &gattr) == 0) {
        if (pthread_attr_getstack(&gattr, (void **)&stack_addr, &stack_size) != 0) {
            stack_addr = NULL;
        }
        pthread_attr_destroy(&gattr);
    }
#else
    #error "Unsupported platform"
#endif

    if (stack_addr == NULL) {
        assert("Failed to retrieve stack attributes");
        return;
    }

    char *sp = (char *)*sp_ptr;
    if (sp <= stack_addr || sp >= stack_addr + stack_size) {
        *sp_ptr = (void *)stack_addr;
    }
}
