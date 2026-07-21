#ifndef AndroidSERuntimeBridge_h
#define AndroidSERuntimeBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the bundled UTM/QEMU threaded-interpreter runtime.
/// Returns 0 after the Android guest reaches the running state.
int32_t android_qemu_se_start(void);

/// Requests a clean shutdown of the Android guest and QEMU runtime.
void android_qemu_se_stop(void);

/// Installs an APK-family package into the running guest and launches its main activity.
/// The path is a UTF-8 absolute path inside the host app container.
int32_t android_guest_install_and_launch(const char *package_path);

#ifdef __cplusplus
}
#endif

#endif /* AndroidSERuntimeBridge_h */
