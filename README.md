# SwiftFirmataIR

Infrared send/receive for [SwiftFirmataClient](https://github.com/doraorak/SwiftFirmataClient),
talking to the ESP32 firmware's **IR module** over the RMT peripheral. Ships as a
separate package that depends on the core client — add it only if you need IR.

```swift
dependencies: [
    .package(url: "https://github.com/doraorak/SwiftFirmataClient", from: "16.2.0"),
    .package(url: "https://github.com/doraorak/SwiftFirmataIR", from: "3.3.0"),
]
```

`import SwiftFirmataIR` and the `ir*` methods appear on the same `FirmataClient` /
`FirmataTaskRecorder` — they're extensions built on the client's generic
`sendToModule` / `moduleOp` primitives.

```swift
import SwiftFirmataClient
import SwiftFirmataIR

// Confirm the connected firmware actually has the module.
guard try await client.hasIRModule() else { return }

// Transmit — each call sends exactly ONE frame.
try await client.irConfigureTransmit(pin: .pin(4))     // TX pin (carrier set per send)
try await client.irSendNEC(0x20DF10EF)                 // NEC, 38 kHz
try await client.irSendRC6(0x0C)                       // RC6 Mode-0, 36 kHz — e.g. a TV power button
try await client.irSendCoolix(0xB27BE0)                // Coolix (Midea-family AC), 38 kHz — power off

// Press a key several times: wrap a send in a task repeat (fires exactly N, ~gap apart).
try await client.uploadTask(id: 1) {
    $0.repeat(times: 4, gap: .milliseconds(220)) { $0.irSendRC6(0x11) }   // volume down ×4
}

// Receive: pick the protocol; decoded frames land in R9 and arrive as messages.
try await client.irReceiveNEC(pin: .pin(18), into: 9)      // or irReceiveRC6 / irReceiveCoolix
for await m in client.messages {
    if let code = m.irCode { print(String(code, radix: 16)) }
}

// Don't know the protocol? Sniff raw bursts and read the timings:
try await client.irStartRawCapture(pin: .pin(18))
for await m in client.messages {
    if let f = m.irRawFrame { print(f.total, f.durations) }   // header µs fingerprint the protocol
}

// Replay a code known only at runtime — encoded on the device from a register:
try await client.uploadTask(id: 2) {
    $0.irSendNEC(fromRegister: .reg(9))               // re-send whatever was captured into R9
}
```

## API

- `hasIRModule()` — is the module present on the connected firmware?
- `irConfigureTransmit(pin:)` — set the IR LED pin (once).
- `irSendNEC(_:carrierHz:)` / `irSendRC6(_:bits:carrierHz:)` / `irSendCoolix(_:carrierHz:)` /
  `irSendRaw(carrierHz:durations:)` — one frame per call (Coolix doubles the message, as real
  remotes do).
- `irSendNEC(fromRegister:)` / `irSendRC6(fromRegister:)` / `irSendCoolix(fromRegister:)` —
  task-only; encode a register's runtime value on-device.
- `irReceiveNEC(pin:into:)` / `irReceiveRC6(pin:into:)` / `irReceiveCoolix(pin:into:)` — decode
  into register N; frames also arrive as messages. All three decode the same raw capture, so
  switching protocol is just a different op byte. (`irStartReceive` is the deprecated NEC-only
  spelling.) RC6 values include the mode/toggle bits — compare against `code` and `code | 0x10000`.
- `irStartRawCapture(pin:)` / `irStopRawCapture()` — sniff mode: every burst (any protocol)
  arrives as raw mark/space µs on `FirmataMessage.irRawFrame` (firmware 2.17+).
- `FirmataMessage.irCode` / `FirmataMessage.irRawFrame` — decoded code / raw burst on a message.

## How it works

NEC/RC6 (and any protocol) are normally **encoded host-side** into a mark/space timing
array and sent through one raw firmware op — so adding a protocol (Sony, RC5, …) is a
pure-Swift change here, no firmware change. Identify an unknown remote with
`irStartRawCapture` (the raw event uses the same duration-pair encoding as `irSendRaw`),
then replay its exact timing via `irSendRaw(carrierHz:durations:)`.

The exception is `fromRegister:`: a value known only at runtime can't be encoded on the
host, so the firmware carries its own NEC/RC6 encoders and builds the waveform on-device.

## License

MIT — see [LICENSE](LICENSE).
