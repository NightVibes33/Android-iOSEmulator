# Combined host/runtime packaging

The full build is assembled at CI time from pinned upstream projects rather than committing third-party binary application bundles to this repository.

Output:

```text
Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa
```

Package layout:

```text
Payload/
└── Android iOSEmulator.app/
    ├── LiveContainer host executable and complete frontend
    └── PreloadedApps/
        └── UTM SE.app/
            └── QEMU TCTI runtime and UTM frontend
```

At first launch, the patched LiveContainer startup copies the nested UTM SE application into its normal `Documents/Applications` library. LiveContainer then manages and launches the guest through its existing UI and container model.

The nested guest is deliberately stripped of its original code signature and provisioning profile. The final IPA is unsigned and must be signed by the user. LiveContainer's normal guest-signing path is responsible for preparing the copied UTM SE guest on device.
