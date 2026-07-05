import Foundation
import SwiftFirmataClient

/*
 * IR module (firmware id 0x01, firmware 2.9+) — NEC/RC6 infrared over the ESP32's RMT
 * peripheral. The public API is the `FirmataClient` / `FirmataTaskRecorder` / `FirmataMessage`
 * extensions below (`irSendNEC`, `irSendRC6`, `irSendRaw`, `irStartReceive`, `hasIRModule`,
 * `FirmataMessage.irCode`). The `IRModule` namespace itself is an internal implementation
 * detail (encoders, ids). Check `hasIRModule()` before relying on it.
 *
 * Module payload protocol (7-bit bytes):
 *   0x00 <pin>              configure the transmitter on a pin (any full-digital pin)
 *   0x02 <pin> <dstReg>     start the receiver on a pin; each decoded NEC frame is written
 *                           to R[dstReg] and pushed as event 0x03
 *   0x03 <kHz> <durations>  RAW send: replay alternating mark/space µs (each a 14-bit LE
 *                           pair) at a <kHz> carrier (0 = none). The sole transmit path —
 *                           `irSendNEC`/`irSendRC6` are host-side encoders that build a
 *                           timing array and send it here.
 *   event 0x03 <code: 5 limbs>   a frame was received (host side only)
 */

/// Internal implementation of the IR module — protocol ids, encoders, and the received-event
/// decoder. Not part of the package's public surface; use the extensions below.
enum IRModule {
    /// The IR module's id in `queryModules()` / module payloads.
    static let id: UInt8 = 0x01

    /// Received-frame event subcommand inside `FirmataMessage.moduleEvent`.
    static let receivedEvent: UInt8 = 0x03

    /// Decode a received-frame event payload (`0x03 <5 limbs>`) into the 32-bit code.
    static func decodeReceivedEvent(_ payload: [UInt8]) -> UInt32? {
        guard payload.count >= 6, payload[0] == receivedEvent else { return nil }
        var v: UInt32 = 0
        for k in 0..<5 { v |= UInt32(payload[1 + k] & 0x7F) << (7 * k) }
        return v
    }

    // MARK: - Protocol encoders (build raw mark/space timing for the 0x03 raw-send op)

    /// NEC frame timing (µs): 9 ms / 4.5 ms header, 32 MSB-first bits (562 µs mark +
    /// 562/1687 µs space), trailing mark. Standard NEC, 38 kHz carrier.
    static func necTiming(_ code: UInt32) -> [UInt16] {
        var d: [UInt16] = [9000, 4500]
        for bit in stride(from: 31, through: 0, by: -1) {
            d.append(562)
            d.append(((code >> UInt32(bit)) & 1) == 1 ? 1687 : 562)
        }
        d.append(562)   // trailing mark (the raw handler pads the final space)
        return d
    }

    /// The RC6 toggle bit (mask `0x10000`) — flip it between distinct key presses so the TV
    /// treats them as separate presses rather than one held button.
    static func toggleRC6(_ data: UInt32) -> UInt32 { data ^ 0x10000 }

    /// RC6 Mode-0 frame timing (µs), matching IRremoteESP8266 `sendRC6` (36 kHz carrier,
    /// unit t = 444 µs): 6t/2t leader, a `1` start bit, then `bits` MSB-first where the 4th
    /// bit is the double-width toggle. `1` = mark-then-space, `0` = space-then-mark, adjacent
    /// equal levels merged. `data` includes the mode/toggle bits (a decode reports; power on
    /// many TVs is `0x0C`).
    static func rc6Timing(_ data: UInt32, bits: Int = 20) -> [UInt16] {
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

    /// Build a raw-send (`0x03`) payload: op, carrier kHz, then each duration as a 14-bit
    /// little-endian 7-bit pair (clamped to 16383 µs).
    static func rawPayload(carrierHz: UInt32, _ durations: [UInt16]) -> [UInt8] {
        [0x03, UInt8((carrierHz / 1000) & 0x7F)] + durationLimbs(durations)
    }

    /// Build a hold/repeat send (`0x04`) payload: op, carrier kHz, total send count, gap (ms,
    /// 14-bit), then the durations. The board re-transmits the one frame `repeats` times.
    static func holdPayload(carrierHz: UInt32, repeats: Int, gapMs: Int, _ durations: [UInt16]) -> [UInt8] {
        let rep = UInt8(min(max(1, repeats), 127))
        let gap = UInt16(min(max(0, gapMs), 16383))
        return [0x04, UInt8((carrierHz / 1000) & 0x7F), rep, UInt8(gap & 0x7F), UInt8((gap >> 7) & 0x7F)]
            + durationLimbs(durations)
    }

    private static func durationLimbs(_ durations: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        for d in durations {
            let v = min(d, 16383)
            out.append(UInt8(v & 0x7F))
            out.append(UInt8((v >> 7) & 0x7F))
        }
        return out
    }
}

public extension FirmataClient {
    /// Whether the connected firmware reports the IR module — check before using `ir*`.
    func hasIRModule(timeout: Duration = .seconds(2)) async throws -> Bool {
        try await queryModules(timeout: timeout).contains { $0.id == IRModule.id }
    }

    /// Configure the IR transmitter pin (any full-digital pin). The carrier is chosen per
    /// send (`irSendNEC`/`irSendRC6`/`irSendRaw`), so call this once, then send.
    func irConfigureTransmit(pin: UInt8) async throws {
        try await sendToModule(id: IRModule.id, payload: [0x00, pin & 0x7F])
    }

    /// Replay a raw mark/space timing array (µs) at `carrierHz` (0 = no carrier). The sole
    /// transmit path — `irSendNEC`/`irSendRC6` are built on this. `repeats` > 1 makes the
    /// board re-transmit the frame that many times, `gapMs` apart (a *hold* — needs fw 2.10+).
    func irSendRaw(carrierHz: UInt32, durations: [UInt16], repeats: Int = 1, gapMs: Int = 110) async throws {
        let payload = repeats > 1
            ? IRModule.holdPayload(carrierHz: carrierHz, repeats: repeats, gapMs: gapMs, durations)
            : IRModule.rawPayload(carrierHz: carrierHz, durations)
        try await sendToModule(id: IRModule.id, payload: payload)
    }

    /// Transmit a 32-bit NEC frame (codes as commonly written, MSB-first — e.g. `0x20DF10EF`).
    /// `carrierHz` defaults to 38 kHz. `repeats` > 1 holds the button (re-sends every `gapMs`).
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000, repeats: Int = 1, gapMs: Int = 110) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code), repeats: repeats, gapMs: gapMs)
    }

    /// Transmit an RC6 Mode-0 frame — e.g. many TVs. `data` is the value a decoder reports
    /// (power is often `0x0C`); XOR with `0x10000` between distinct presses. `repeats` > 1
    /// holds it (RC6 keeps the same toggle while held, which repeating the same value gives).
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000, repeats: Int = 1, gapMs: Int = 107) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits), repeats: repeats, gapMs: gapMs)
    }

    /// Start the IR receiver on `pin`. Every decoded NEC frame is written to `R[register]`
    /// (also readable by tasks) and arrives on ``messages`` as a
    /// ``FirmataMessage/moduleEvent(id:payload:)`` — read its ``FirmataMessage/irCode``.
    func irStartReceive(pin: UInt8, into register: UInt8) async throws {
        guard register <= 15 else { throw FirmataError.invalidData }
        try await sendToModule(id: IRModule.id, payload: [0x02, pin & 0x7F, register & 0x0F])
    }
}

public extension FirmataMessage {
    /// If this message is an IR received-frame event, the decoded 32-bit NEC code; else `nil`.
    var irCode: UInt32? {
        guard case let .moduleEvent(id, payload) = self, id == IRModule.id else { return nil }
        return IRModule.decodeReceivedEvent(payload)
    }
}

public extension FirmataTaskRecorder {
    /// Task-side IR: same ops as the live calls, recorded (`board.irSendNEC(0x20DF10EF)` —
    /// e.g. power off the TV when a task condition fires). Configure the transmitter once
    /// (live or in the task) before sending.
    func irConfigureTransmit(pin: TaskPin) {
        moduleOp(id: IRModule.id, payload: [0x00, pin.number & 0x7F])
    }

    /// Replay a raw mark/space timing array (µs) at `carrierHz` from a task. `repeats` > 1
    /// holds it — the board re-transmits the one frame that many times, `gapMs` apart.
    func irSendRaw(carrierHz: UInt32, durations: [UInt16], repeats: Int = 1, gapMs: Int = 110) {
        let payload = repeats > 1
            ? IRModule.holdPayload(carrierHz: carrierHz, repeats: repeats, gapMs: gapMs, durations)
            : IRModule.rawPayload(carrierHz: carrierHz, durations)
        moduleOp(id: IRModule.id, payload: payload)
    }

    /// Transmit a 32-bit NEC frame from the task (`repeats` > 1 = hold).
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000, repeats: Int = 1, gapMs: Int = 110) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code), repeats: repeats, gapMs: gapMs)
    }

    /// Transmit an RC6 Mode-0 frame from the task — e.g. turn a TV on/off (`repeats` > 1 = hold).
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000, repeats: Int = 1, gapMs: Int = 107) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits), repeats: repeats, gapMs: gapMs)
    }

    /// Start the receiver from the task; decoded frames land in `dst` for `ifTrue`.
    func irStartReceive(pin: TaskPin, into dst: TaskNumberRegister) {
        moduleOp(id: IRModule.id, payload: [0x02, pin.number & 0x7F, dst.index & 0x0F])
    }
}
