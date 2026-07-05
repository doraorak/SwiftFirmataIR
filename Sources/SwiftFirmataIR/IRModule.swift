import Foundation
import SwiftFirmataClient

/*
 * IR module (module id 0x01, firmware 2.9+) — NEC infrared send/receive over the
 * ESP32's RMT peripheral. Typed wrapper over the generic module calls; check
 * `queryModules()` for `id == IRModule.id` before relying on it.
 *
 * Module payload protocol (7-bit bytes):
 *   0x00 <pin>              configure the transmitter on a pin (any full-digital pin)
 *   0x02 <pin> <dstReg>     start the receiver on a pin; each decoded frame is
 *                           written to R[dstReg] and pushed as event 0x03 (NEC only)
 *   0x03 <kHz> <durations>  RAW send: replay alternating mark/space µs (each a 14-bit
 *                           LE pair) at a <kHz> carrier (0 = none). This is the sole
 *                           transmit path — `irSendNEC`/`irSendRC6` are host-side
 *                           encoders that both build a timing array and send it here.
 *   event 0x03 <code: 5 limbs>   a frame was received (host side only)
 *
 * Swift-firmware-only debug ops (kept for IR bring-up on unknown modules):
 *   0x7C <invert>           invert the TX envelope (0 = mark HIGH, 1 = mark LOW)
 *   0x7D <pol> <duty%> <kHz> retune the live TX carrier (kHz 0 = carrier off)
 *   0x7E                    dump last capture + status (reply 0x7E ...)
 */

public enum IRModule {
    /// The IR module's id in `queryModules()` / module payloads.
    public static let id: UInt8 = 0x01

    /// Received-frame event subcommand inside ``FirmataMessage/moduleEvent(id:payload:)``.
    public static let receivedEvent: UInt8 = 0x03

    /// Decode a received-frame event payload (`0x03 <5 limbs>`) into the 32-bit code.
    public static func decodeReceivedEvent(_ payload: [UInt8]) -> UInt32? {
        guard payload.count >= 6, payload[0] == receivedEvent else { return nil }
        var v: UInt32 = 0
        for k in 0..<5 { v |= UInt32(payload[1 + k] & 0x7F) << (7 * k) }
        return v
    }

    // MARK: - Protocol encoders (build raw mark/space timing for the 0x03 raw-send op)

    /// NEC frame timing (µs): 9 ms / 4.5 ms header, 32 MSB-first bits (562 µs mark +
    /// 562/1687 µs space), trailing mark. Standard NEC, 38 kHz carrier.
    public static func necTiming(_ code: UInt32) -> [UInt16] {
        var d: [UInt16] = [9000, 4500]
        for bit in stride(from: 31, through: 0, by: -1) {
            d.append(562)
            d.append(((code >> UInt32(bit)) & 1) == 1 ? 1687 : 562)
        }
        d.append(562)   // trailing mark (the raw handler pads the final space)
        return d
    }

    /// The RC6 toggle bit (mask `0x10000`) — flip it between distinct key presses so
    /// the TV treats them as separate presses rather than one held button.
    public static func toggleRC6(_ data: UInt32) -> UInt32 { data ^ 0x10000 }

    /// RC6 Mode-0 frame timing (µs), matching IRremoteESP8266 `sendRC6` (36 kHz carrier,
    /// unit t = 444 µs): 6t/2t leader, a `1` start bit, then `bits` MSB-first where the
    /// 4th bit is the double-width toggle. `1` = mark-then-space, `0` = space-then-mark,
    /// with adjacent equal levels merged. `data` includes the mode/toggle bits (e.g. the
    /// value `queryModules`/a library decode reports — power on many TVs is `0x0C`).
    public static func rc6Timing(_ data: UInt32, bits: Int = 20) -> [UInt16] {
        let t: UInt16 = 444
        var ev: [(mark: Bool, dur: UInt16)] = []
        ev.append((true, 6 * t)); ev.append((false, 2 * t))   // leader
        ev.append((true, t));     ev.append((false, t))       // start bit (always 1)
        var i = 1
        var mask: UInt32 = bits > 0 ? (UInt32(1) << (bits - 1)) : 0
        while mask != 0 {
            let bt: UInt16 = (i == 4) ? 2 * t : t              // 4th bit = double-width toggle
            if data & mask != 0 { ev.append((true, bt)); ev.append((false, bt)) }   // 1
            else                { ev.append((false, bt)); ev.append((true, bt)) }   // 0
            i += 1; mask >>= 1
        }
        // Merge consecutive same-level events into an alternating mark/space list.
        var out: [UInt16] = []
        for e in ev {
            let expectMark = (out.count % 2 == 0)             // out[even]=mark, out[odd]=space
            if e.mark == expectMark { out.append(e.dur) }
            else { out[out.count - 1] += e.dur }
        }
        return out
    }

    /// Build a raw-send (`0x03`) payload: op, carrier kHz, then each duration as a
    /// 14-bit little-endian 7-bit pair (clamped to 16383 µs).
    public static func rawPayload(carrierHz: UInt32, _ durations: [UInt16]) -> [UInt8] {
        var out: [UInt8] = [0x03, UInt8((carrierHz / 1000) & 0x7F)]
        for d in durations {
            let v = min(d, 16383)
            out.append(UInt8(v & 0x7F))
            out.append(UInt8((v >> 7) & 0x7F))
        }
        return out
    }
}

public extension FirmataClient {
    /// Configure the IR transmitter pin (any full-digital pin). The carrier is chosen
    /// per send (`irSendNEC`/`irSendRC6`/`irSendRaw`), so call this once, then send.
    func irConfigureTransmit(pin: UInt8) async throws {
        try await sendToModule(id: IRModule.id, payload: [0x00, pin & 0x7F])
    }

    /// Replay a raw mark/space timing array (µs) at `carrierHz` (0 = no carrier). The
    /// sole transmit path — `irSendNEC`/`irSendRC6` are built on this.
    func irSendRaw(carrierHz: UInt32, durations: [UInt16]) async throws {
        try await sendToModule(id: IRModule.id, payload: IRModule.rawPayload(carrierHz: carrierHz, durations))
    }

    /// Transmit a 32-bit NEC frame (codes as commonly written, MSB-first — e.g. `0x20DF10EF`).
    /// `carrierHz` defaults to 38 kHz; override for receivers tuned elsewhere (30–36 kHz).
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code))
    }

    /// Transmit an RC6 Mode-0 frame — e.g. many TVs. `data` is the value a decoder
    /// reports (power is often `0x0C`); flip ``IRModule/toggleRC6(_:)`` between presses.
    /// `carrierHz` defaults to RC6's 36 kHz.
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits))
    }

    /// Start the IR receiver on `pin`. Every decoded NEC frame is written to
    /// `R[register]` (also readable by tasks) and arrives on ``messages`` as a
    /// ``FirmataMessage/moduleEvent(id:payload:)`` — decode with
    /// ``IRModule/decodeReceivedEvent(_:)``.
    func irStartReceive(pin: UInt8, into register: UInt8) async throws {
        guard register <= 15 else { throw FirmataError.invalidData }
        try await sendToModule(id: IRModule.id, payload: [0x02, pin & 0x7F, register & 0x0F])
    }
}

public extension FirmataTaskRecorder {
    /// Task-side IR: same ops as the live calls, recorded (`board.irSendNEC(0x20DF10EF)`
    /// — e.g. power off the TV when a task condition fires). Configure the
    /// transmitter once (live or in the task) before sending.
    func irConfigureTransmit(pin: TaskPin) {
        moduleOp(id: IRModule.id, payload: [0x00, pin.number & 0x7F])
    }

    /// Replay a raw mark/space timing array (µs) at `carrierHz` from a task.
    func irSendRaw(carrierHz: UInt32, durations: [UInt16]) {
        moduleOp(id: IRModule.id, payload: IRModule.rawPayload(carrierHz: carrierHz, durations))
    }

    /// Transmit a 32-bit NEC frame from the task (host-encoded, raw path).
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code))
    }

    /// Transmit an RC6 Mode-0 frame from the task — e.g. turn a TV on/off.
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits))
    }

    /// Start the receiver from the task; decoded frames land in `dst` for `ifTrue`.
    func irStartReceive(pin: TaskPin, into dst: TaskNumberRegister) {
        moduleOp(id: IRModule.id, payload: [0x02, pin.number & 0x7F, dst.index & 0x0F])
    }
}
