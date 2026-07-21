#ifndef JITProbe_h
#define JITProbe_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum JITProbeProtocol {
    JITProbeProtocolUniversal = 0,
    JITProbeProtocolUTMLegacy = 1,
} JITProbeProtocol;

/// Reads an effective boolean entitlement from the running process.
/// Returns 1 for true, 0 for false/missing, and -1 when the Security task API is unavailable.
int32_t jitprobe_entitlement_boolean(const char *key);

/// Returns non-zero when the process currently has P_TRACED.
int32_t jitprobe_is_debugger_attached(void);

/// Runs a split-RW/RX generated-code test. Expected generated result is 42.
/// Returns 0 on success or a positive errno/Mach-derived failure code.
int32_t jitprobe_run(int32_t protocol,
                     uint64_t *rw_address,
                     uint64_t *rx_address,
                     uint64_t *region_length,
                     int32_t *generated_result);

/// Thread-local enough for this single-probe diagnostic app.
const char *jitprobe_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
