# SwiftFirmataIR

Infrared send/receive for [SwiftFirmataClient](https://github.com/doraorak/SwiftFirmataClient),
talking to the ESP32 firmware's **IR module** over the RMT peripheral. Ships as a
separate package that depends on the core client — add it only if you need IR.

```swift
dependencies: [
    .package(url: "https://github.com/doraorak/SwiftFirmataClient", from: "15.1.0"),
    .package(url: "https://github.com/doraorak/SwiftFirmataIR", from: "3.0.0"),
]
```

`import SwiftFirmataIR` and the `ir*` methods appear on the same `FirmataClient` /
`FirmataTaskRecorder` — they're extensions built on the client's generic
`sendToModule` / `moduleOp` primitives.

```swift
import SwiftFirmataClient
import SwiftFirmataIR

// Confirm the connected firmware actually has the module.
guard try await board.hasIRModule() else { return }

// Transmit — each call sends exactly ONE frame.
try await board.irConfigureTransmit(pin: .pin(4))     // TX pin (carrier set per send)
try await board.irSendNEC(0x20DF10EF)                 // NEC, 38 kHz
try await board.irSendRC6(0x0C)                       // RC6 Mode-0, 36 kHz — e.g. a TV power button

// Press a key several times: wrap a send in a task loop (fires exactly N, ~gap apart).
try await board.uploadTask(id: 1) {
    $0.loop(4, gap: .milliseconds(220)) { $0.irSendRC6(0x11) }   // volume down ×4
}

// Receive: decoded NEC frames land in R9 and arrive as messages.
try await board.irStartReceive(pin: .pin(18), into: 9)
for await m in board.messages {
    if let code = m.irCode { print(String(code, radix: 16)) }
}

// Replay a code known only at runtime — encoded on the device from a register:
try await board.uploadTask(id: 2) {
    $0.irSendNEC(fromRegister: .reg(9))               // re-send whatever was captured into R9
}
```

## API

- `hasIRModule()` — is the module present on the connected firmware?
- `irConfigureTransmit(pin:)` — set the IR LED pin (once).
- `irSendNEC(_:carrierHz:)` / `irSendRC6(_:bits:carrierHz:)` / `irSendRaw(carrierHz:durations:)`
  — one frame per call.
- `irSendNEC(fromRegister:)` / `irSendRC6(fromRegister:)` — task-only; encode a register's
  runtime value on-device.
- `irStartReceive(pin:into:)` — decode NEC into register N; frames also arrive as messages.
- `FirmataMessage.irCode` — the decoded code on an incoming message.

## How it works

NEC/RC6 (and any protocol) are normally **encoded host-side** into a mark/space timing
array and sent through one raw firmware op — so adding a protocol (Sony, RC5, …) is a
pure-Swift change here, no firmware change. Record an unknown remote with
`irStartReceive` (or a library dumper), then replay its exact timing via
`irSendRaw(carrierHz:durations:)`.

The exception is `fromRegister:`: a value known only at runtime can't be encoded on the
host, so the firmware carries its own NEC/RC6 encoders and builds the waveform on-device.

> Hardware: power the IR **LED at 5 V** for range, and keep the **receiver at 3.3 V**
> (its OUT feeds a non-5V-tolerant GPIO). The RMT receiver captures ~1 frame per ~80 ms,
> so space repeated sends ≥ ~150 ms apart.

## License

MIT — see [LICENSE](LICENSE).
