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
3. Open Shortcuts and edit the shortcut named exactly:

```text
Start Android iOSEmulator JIT
```

4. The shortcut must not be empty. Tap **Add Action**.
5. Search for **Enable JIT**.
6. Choose **Enable JIT** from **StikDebug**.
7. Tap the blue **App** parameter inside the action.
8. Select **Android iOSEmulator** with bundle identifier:

```text
com.nightvibes.androidiosemulator
```

9. The completed shortcut must contain this action:

```text
StikDebug → Enable JIT → App: Android iOSEmulator
```

10. Run the shortcut once manually and approve any Shortcuts, StikDebug, LocalDevVPN, pairing, or Developer Mode prompts.

If Shortcuts says the shortcut “contains no actions,” the StikDebug **Enable JIT** action was never added. A shortcut name by itself cannot enable JIT.

For legacy comparison, assign `UTM-Dolphin.js` in StikDebug and select **UTM legacy** inside the probe app.

## Test sequence

1. Open Android iOSEmulator.
2. Confirm `get-task-allow` reports **Enabled**.
3. Tap **Enable LocalDevVPN**.
4. Return to the app and tap **Probe Local Route**.
5. Tap **Open Configured Shortcut** and verify it contains the StikDebug action above.
6. Return to Android iOSEmulator and tap **Run Configured Shortcut**.
7. When Android iOSEmulator reopens under the debugger, confirm **Debugger attached** reports **Yes**.
8. Tap **Execute JIT Probe**.
9. Success means generated ARM64 code returned `42` through the RX alias.
10. Export the diagnostic JSON after success or failure.

## Failure meanings

- **Shortcut contains no actions:** add StikDebug's **Enable JIT** action and select Android iOSEmulator.
- **App is blank inside Enable JIT:** tap the App parameter and select `com.nightvibes.androidiosemulator`.
- **Android iOSEmulator is not listed:** open StikDebug, start its tunnel, refresh the installed-app list, and confirm the emulator is installed and development-signed.
- **get-task-allow missing:** the IPA was signed with an incompatible profile or signer configuration.
- **10.7.0.1:49152 unreachable:** LocalDevVPN is disconnected, another VPN conflicts, or the pairing route is unavailable.
- **E96 / socket not connected:** StikDebug reached debugserver but could not complete attachment; preserve the entire log.
- **Breakpoint trap/crash:** the selected StikDebug script does not match the protocol selected in Android iOSEmulator.
- **mprotect/remap failure:** the iOS release, signing state, or memory mapping differs from the supported UTM-style path.
