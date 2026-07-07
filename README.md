# SwiftFirmataIR

Infrared send/receive for [SwiftFirmataClient](../SwiftFirmataClient), talking to
the ESP32 firmware's **IR module** (module id `0x01`, firmware 2.9+) over the RMT
peripheral. Ships as a **separate package that depends on the core client** — add it
only if you need IR.

```swift
dependencies: [
    .package(url: "https://github.com/doraorak/SwiftFirmataClient", from: "15.1.0"),
    .package(url: "https://github.com/doraorak/SwiftFirmataIR", from: "3.0.0"),
]
```

The module is a set of extensions on `FirmataClient` / `FirmataTaskRecorder` built on
the client's generic `sendToModule` / `moduleOp` primitives — `import SwiftFirmataIR`
and the `ir*` methods appear on the same actor.

```swift
import SwiftFirmataClient
import SwiftFirmataIR

// Confirm the connected firmware actually has the module.
guard try await board.hasIRModule() else { return }

board // transmit — each call sends ONE frame
try await board.irConfigureTransmit(pin: .pin(4))     // TX pin (LED on 5V for range); carrier is per send
try await board.irSendNEC(0x20DF10EF)           // NEC, 38 kHz
try await board.irSendRC6(0x0C)                 // RC6 Mode-0, 36 kHz — e.g. a TV power button

// press a key several times: wrap a send in a task loop (fires exactly N, ~gap apart)
try await board.uploadTask(id: 1) {
    $0.loop(4, gap: .milliseconds(220)) { $0.irSendRC6(0x11) }   // volume down ×4
}

// receive: decoded NEC frames land in R9 and arrive as moduleEvents
try await board.irStartReceive(pin: .pin(18), into: 9)
for await m in board.messages {
    if let code = m.irCode { print(String(code, radix: 16)) }   // FirmataMessage.irCode
}

// replay a code known only at runtime — encoded on the device (firmware 2.14+),
// e.g. re-transmit whatever irStartReceive captured into R9:
try await board.uploadTask(id: 2) {
    $0.irSendNEC(fromRegister: .reg(9))
}
```

The public API is the extensions above — `hasIRModule()`, `irConfigureTransmit`,
`irSendNEC`/`irSendRC6`/`irSendRaw` (plus `irSendNEC/RC6(fromRegister:)` in tasks),
`irStartReceive`, and `FirmataMessage.irCode`
(plus the matching `FirmataTaskRecorder` methods for on-device tasks). The protocol
encoders are internal implementation.

### How it works

All protocols are **encoded host-side** into a mark/space timing array and sent through
one firmware op (raw send, `0x03 <kHz> <durations>`); the NEC/RC6 encoders build the
arrays, so adding a protocol (Sony, RC5, …) is a pure-Swift change here, no firmware
change. Record an unknown remote with `irStartReceive` (or a library dumper), then replay
its exact timing via `irSendRaw(carrierHz:durations:)`.

The one exception is `fromRegister:` — a code known only at runtime (e.g. one just
received) can't be encoded on the host, so the firmware carries its own NEC/RC6 encoders
and builds the waveform on-device from the register value (op `0x05`, firmware 2.14+).

> Notes: power the IR **LED at 5V** and keep the **receiver at 3.3V** (its OUT feeds a
> non-5V-tolerant GPIO). The RMT receiver captures ~1 frame per ~80 ms, so space repeated
> sends ≥ ~150 ms.
