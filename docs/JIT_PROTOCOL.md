# Gate 0 JIT protocol notes

## Universal protocol

The target raises `brk #0xf00d` and places the operation in register `x16`.

| x16 | Operation |
|---:|---|
| 0 | Detach debugger handler |
| 1 | Prepare executable region (`x0` address, `x1` length) |

The debugger-side script advances the trapped thread, prepares the selected executable mapping, and resumes the process.

## Legacy UTM protocol

The target raises `brk #0x69` with the RX mapping address in `x0` and mapping length in `x1`. StikDebug's `UTM-Dolphin.js` handles one valid breakpoint and detaches.

## Probe memory layout

```text
One physical allocation
├── RW alias: generated ARM64 instructions are written here
└── RX alias: the same bytes are executed here
```

The probe never requests RWX memory. It writes through the RW alias, invalidates the instruction cache, and executes through the RX alias.
