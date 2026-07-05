# SwiftFirmataIR

Infrared send/receive for [SwiftFirmataClient](../SwiftFirmataClient), talking to
the ESP32 firmware's **IR module** (module id `0x01`, firmware 2.9+) over the RMT
peripheral. Ships as a **separate package that depends on the core client** — add it
only if you need IR.

```swift
dependencies: [
    .package(url: "https://github.com/doraorak/SwiftFirmataClient", from: "14.6.0"),
    .package(url: "https://github.com/doraorak/SwiftFirmataIR", from: "1.0.0"),
]
```

The module is a set of extensions on `FirmataClient` / `FirmataTaskRecorder` built on
the client's generic `sendToModule` / `moduleOp` primitives — `import SwiftFirmataIR`
and the `ir*` methods appear on the same actor.

```swift
import SwiftFirmataClient
import SwiftFirmataIR

// Confirm the connected firmware actually has the module.
guard try await board.queryModules().contains(where: { $0.id == IRModule.id }) else { return }

board // transmit
try await board.irConfigureTransmit(pin: 4)     // TX pin (LED on 5V for range); carrier is per send
try await board.irSendNEC(0x20DF10EF)           // NEC, 38 kHz
try await board.irSendRC6(0x0C)                 // RC6 Mode-0, 36 kHz — e.g. a TV power button

// receive: decoded NEC frames land in R9 and arrive as moduleEvents
try await board.irStartReceive(pin: 18, into: 9)
for await m in board.messages {
    if case let .moduleEvent(id, p) = m, id == IRModule.id,
       let code = IRModule.decodeReceivedEvent(p) { print(String(code, radix: 16)) }
}
```

### How it works

All protocols are **encoded host-side** into a mark/space timing array and sent through
one firmware op (raw send, `0x03 <kHz> <durations>`). `IRModule.necTiming` / `rc6Timing`
build the arrays; adding a protocol (Sony, RC5, …) is a pure-Swift encoder here, no
firmware change. Record an unknown remote with `irStartReceive` (or a library dumper),
then replay its exact timing via `irSendRaw(carrierHz:durations:)`.

> Notes: power the IR **LED at 5V** and keep the **receiver at 3.3V** (its OUT feeds a
> non-5V-tolerant GPIO). The RMT receiver captures ~1 frame per ~80 ms, so space repeated
> sends ≥ ~150 ms.
