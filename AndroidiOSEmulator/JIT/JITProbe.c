#include "JITProbe.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

#ifndef MAP_ANON
#define MAP_ANON MAP_ANONYMOUS
#endif

static char g_last_error[256] = "Not run";

static void set_error(const char *stage, int code) {
    if (code == 0) {
        snprintf(g_last_error, sizeof(g_last_error), "%s", stage);
    } else {
        snprintf(g_last_error, sizeof(g_last_error), "%s failed (%d: %s)", stage, code, strerror(code));
    }
}

#if defined(__aarch64__)
/// Arguments enter in x0/x1. StikDebug's universal.js reads them at brk #0xf00d.
__attribute__((naked, noinline))
static void jit26_prepare_universal(void *address, size_t length) {
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n"
    );
}

__attribute__((naked, noinline))
static void jit26_detach_universal(void) {
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n"
    );
}

/// Arguments enter in x0/x1. StikDebug's UTM-Dolphin.js reads them at brk #0x69.
__attribute__((naked, noinline))
static void jit26_prepare_utm_legacy(void *address, size_t length) {
    __asm__ volatile(
        "brk #0x69\n"
        "ret\n"
    );
}
#endif

int32_t jitprobe_is_debugger_attached(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int32_t jitprobe_run(int32_t protocol,
                     uint64_t *rw_address,
                     uint64_t *rx_address,
                     uint64_t *region_length,
                     int32_t *generated_result) {
#if !defined(__aarch64__)
    set_error("The JIT probe requires an ARM64 real device", 0);
    return ENOTSUP;
#else
    if (rw_address) *rw_address = 0;
    if (rx_address) *rx_address = 0;
    if (region_length) *region_length = 0;
    if (generated_result) *generated_result = 0;

    if (!jitprobe_is_debugger_attached()) {
        set_error("StikDebug is not attached. Run the JIT shortcut first", 0);
        return EPERM;
    }

    const size_t page_size = (size_t)getpagesize();
    const size_t length = page_size;
    int map_flags = MAP_PRIVATE | MAP_ANON;
#ifdef MAP_JIT
    map_flags |= MAP_JIT;
#endif

    void *writable_candidate = mmap(NULL, length, PROT_READ | PROT_EXEC, map_flags, -1, 0);
    if (writable_candidate == MAP_FAILED) {
#ifdef MAP_JIT
        // Some debugger-owned paths reject MAP_JIT but allow an anonymous RX mapping.
        map_flags &= ~MAP_JIT;
        writable_candidate = mmap(NULL, length, PROT_READ | PROT_EXEC, map_flags, -1, 0);
#endif
    }
    if (writable_candidate == MAP_FAILED) {
        int code = errno;
        set_error("mmap RX code region", code);
        return code;
    }

    mach_vm_address_t executable_alias = 0;
    vm_prot_t current_protection = VM_PROT_NONE;
    vm_prot_t maximum_protection = VM_PROT_NONE;
    kern_return_t kr = mach_vm_remap(
        mach_task_self(),
        &executable_alias,
        (mach_vm_size_t)length,
        0,
        VM_FLAGS_ANYWHERE,
        mach_task_self(),
        (mach_vm_address_t)writable_candidate,
        false,
        &current_protection,
        &maximum_protection,
        VM_INHERIT_NONE
    );

    if (kr != KERN_SUCCESS || executable_alias == 0) {
        munmap(writable_candidate, length);
        snprintf(g_last_error, sizeof(g_last_error), "mach_vm_remap failed (Mach %d)", kr);
        return (int32_t)(1000 + kr);
    }

    if (protocol == JITProbeProtocolUTMLegacy) {
        jit26_prepare_utm_legacy((void *)executable_alias, length);
    } else {
        jit26_prepare_universal((void *)executable_alias, length);
    }

    if (mprotect(writable_candidate, length, PROT_READ | PROT_WRITE) != 0) {
        int code = errno;
        mach_vm_deallocate(mach_task_self(), executable_alias, (mach_vm_size_t)length);
        munmap(writable_candidate, length);
        set_error("mprotect RW alias", code);
        if (protocol == JITProbeProtocolUniversal) {
            jit26_detach_universal();
        }
        return code;
    }

    // ARM64: mov w0, #42; ret
    const uint32_t generated_code[] = {0x52800540u, 0xD65F03C0u};
    memcpy(writable_candidate, generated_code, sizeof(generated_code));
    sys_icache_invalidate((void *)executable_alias, sizeof(generated_code));

    typedef int32_t (*GeneratedFunction)(void);
    GeneratedFunction function = (GeneratedFunction)(uintptr_t)executable_alias;
    int32_t value = function();

    if (rw_address) *rw_address = (uint64_t)(uintptr_t)writable_candidate;
    if (rx_address) *rx_address = (uint64_t)executable_alias;
    if (region_length) *region_length = (uint64_t)length;
    if (generated_result) *generated_result = value;

    mach_vm_deallocate(mach_task_self(), executable_alias, (mach_vm_size_t)length);
    munmap(writable_candidate, length);

    if (protocol == JITProbeProtocolUniversal) {
        jit26_detach_universal();
    }

    if (value != 42) {
        snprintf(g_last_error, sizeof(g_last_error), "Generated code returned %d instead of 42", value);
        return EBADEXEC;
    }

    snprintf(g_last_error, sizeof(g_last_error), "Generated ARM64 code executed successfully and returned 42");
    return 0;
#endif
}

const char *jitprobe_last_error(void) {
    return g_last_error;
}
