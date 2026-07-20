# Real-device Gate 0 setup

## Requirements

- iPhone or iPad on iOS/iPadOS 26 or 27.
- Developer Mode enabled.
- LocalDevVPN installed and its VPN configuration approved.
- StikDebug installed.
- A valid `.mobiledevicepairing` record imported into StikDebug.
- Android iOSEmulator signed with a development provisioning profile containing `get-task-allow`.

An unsigned IPA cannot grant entitlements by itself. The signer and provisioning profile determine the effective entitlements on the installed app.

## StikDebug setup

1. Open StikDebug and import the current pairing record.
2. Assign `universal.js` to **Android iOSEmulator**.
3. In Shortcuts, add StikDebug's **Enable JIT** action.
4. Select Android iOSEmulator as the target.
5. Name the shortcut exactly:

```text
Start Android iOSEmulator JIT
```

For legacy comparison, assign `UTM-Dolphin.js` in StikDebug and select **UTM legacy** inside the probe app.

## Test sequence

1. Open Android iOSEmulator.
2. Confirm `get-task-allow` reports **Enabled**.
3. Tap **Enable LocalDevVPN**.
4. Return to the app and tap **Probe Local Route**.
5. Tap **Run StikDebug Shortcut**.
6. When Android iOSEmulator reopens under the debugger, tap **Execute JIT Probe**.
7. Success means generated ARM64 code returned `42` through the RX alias.
8. Export the diagnostic JSON after success or failure.

## Failure meanings

- **get-task-allow missing:** the IPA was signed with an incompatible profile or signer configuration.
- **10.7.0.1:49152 unreachable:** LocalDevVPN is disconnected, another VPN conflicts, or the pairing route is unavailable.
- **E96 / socket not connected:** StikDebug reached debugserver but could not complete attachment; preserve the entire log.
- **Breakpoint trap/crash:** the selected StikDebug script does not match the protocol selected in Android iOSEmulator.
- **mprotect/remap failure:** the iOS release, signing state, or memory mapping differs from the supported UTM-style path.
