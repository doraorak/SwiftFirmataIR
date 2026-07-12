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
 *   0x02 <pin> <dstReg> [<protocol>]  start the receiver on a pin; each decoded frame is
 *                           written to R[dstReg] and pushed as event 0x03. protocol 0 = NEC
 *                           (default), 1 = RC6 mode 0, 2 = Coolix — all decode the same raw
 *                           capture the sniffer (0x06) sees
 *   0x08 <pin> <slot>       receive raw timings as the text "[d0,d1,…]" into device string slot
 *   0x03 <kHz> <durations>  RAW send: replay alternating mark/space µs (each a 14-bit LE
 *                           pair) at a <kHz> carrier (0 = none). The sole transmit path —
 *                           `irSendNEC`/`irSendRC6` are host-side encoders that build a
 *                           timing array and send it here.
 *   0x06 <pin> <enable>     raw capture on/off: push every received burst as event 0x07
 *   event 0x03 <code: 5 limbs>   a frame was received (host side only)
 *   event 0x07 <total:2> <durations…>   raw burst: total durations captured, then the
 *                           mark/space µs as 14-bit LE pairs (same encoding as raw send)
 */

/// Internal implementation of the IR module — protocol ids, encoders, and the received-event
/// decoder. Not part of the package's public surface; use the extensions below.
enum IRModule {
    /// The IR module's id in `queryModules()` / module payloads.
    static let id: UInt8 = 0x01

    /// Received-frame event subcommand inside `FirmataMessage.moduleEvent`.
    static let receivedEvent: UInt8 = 0x03

    /// Raw-capture burst event subcommand (enabled by op 0x06).
    static let rawFrameEvent: UInt8 = 0x07

    /// Decode a raw-burst event payload (`0x07 <total:2> <pairs…>`): `total` durations were
    /// captured on the wire; `durations` holds the reported mark/space µs.
    static func decodeRawFrameEvent(_ payload: [UInt8]) -> (total: Int, durations: [UInt16])? {
        guard payload.count >= 3, payload[0] == rawFrameEvent else { return nil }
        let total = Int(payload[1] & 0x7F) | (Int(payload[2] & 0x7F) << 7)
        var durations: [UInt16] = []
        var i = 3
        while i + 1 < payload.count {
            durations.append(UInt16(payload[i] & 0x7F) | (UInt16(payload[i + 1] & 0x7F) << 7))
            i += 2
        }
        return (total, durations)
    }

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

    /// Coolix (Midea AC family) frame timing (µs), 38 kHz: 4692/4416 header, 552 marks,
    /// space 1656 = 1 / 552 = 0. The 24-bit code goes out as byte+complement pairs
    /// (48 wire bits) and the whole message is doubled — real Coolix remotes always are.
    static func coolixTiming(_ code: UInt32) -> [UInt16] {
        var d: [UInt16] = []
        for section in 0..<2 {
            d.append(4692); d.append(4416)
            for byteIndex in stride(from: 2, through: 0, by: -1) {
                let byte = (code >> UInt32(byteIndex * 8)) & 0xFF
                for value in [byte, ~byte & 0xFF] {
                    for bit in stride(from: 7, through: 0, by: -1) {
                        d.append(552)
                        d.append(((value >> UInt32(bit)) & 1) == 1 ? 1656 : 552)
                    }
                }
            }
            d.append(552)                                   // footer mark
            if section == 0 { d.append(5244) }              // gap before the repeat
        }
        return d
    }

    /// Build a raw-send (`0x03`) payload: op, carrier kHz, then each duration as a 14-bit
    /// little-endian 7-bit pair (clamped to 16383 µs).
    static func rawPayload(carrierHz: UInt32, _ durations: [UInt16]) -> [UInt8] {
        [0x03, UInt8((carrierHz / 1000) & 0x7F)] + durationLimbs(durations)
    }

    private static func durationLimbs(_ durations: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        for duration in durations {
            let clamped = min(duration, 16383)
            out.append(UInt8(clamped & 0x7F))
            out.append(UInt8((clamped >> 7) & 0x7F))
        }
        return out
    }
}

public extension FirmataClient {
    /// Whether the connected firmware reports the IR module — check before using `ir*`.
    func hasIRModule(timeout: Duration = .seconds(2)) async throws -> Bool {
        try await queryModules(timeout: timeout).contains { $0.id == IRModule.id }
    }

    /// Configure the IR transmitter pin — `.pin(4)` (any full-digital pin). The carrier is
    /// chosen per send (`irSendNEC`/`irSendRC6`/`irSendRaw`), so call this once, then send.
    func irConfigureTransmit(pin: FirmataPin) async throws {
        try await sendToModule(id: IRModule.id, payload: [0x00, pin.number & 0x7F])
    }

    /// Replay a raw mark/space timing array (µs) at `carrierHz` (0 = no carrier) — one frame.
    /// The sole transmit path; `irSendNEC`/`irSendRC6` build on it. To send a key several times,
    /// wrap the send in a task ``FirmataTaskRecorder/repeat(times:gap:_:)`` block.
    func irSendRaw(carrierHz: UInt32, durations: [UInt16]) async throws {
        try await sendToModule(id: IRModule.id, payload: IRModule.rawPayload(carrierHz: carrierHz, durations))
    }

    /// Transmit one 32-bit NEC frame (MSB-first — e.g. `0x20DF10EF`), 38 kHz carrier by default.
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code))
    }

    /// Transmit one RC6 Mode-0 frame — e.g. many TVs (`data` is the value a decoder reports;
    /// volume-down is often `0x11`, power `0x0C`), 36 kHz carrier by default.
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits))
    }

    /// Transmit one 24-bit Coolix frame (Midea-family ACs — e.g. `0xB27BE0` = power off),
    /// 38 kHz. The message is doubled on the wire, as real Coolix remotes send it.
    func irSendCoolix(_ code: UInt32, carrierHz: UInt32 = 38_000) async throws {
        try await irSendRaw(carrierHz: carrierHz, durations: IRModule.coolixTiming(code))
    }

    /// Start receiving NEC on `pin`; every decoded 32-bit frame is written to `R[register]`
    /// (also readable by tasks) and arrives on ``messages`` — read ``FirmataMessage/irCode``.
    /// All receivers decode the same raw capture ``irStartRawCapture(pin:)`` reports.
    func irReceiveNEC(pin: FirmataPin, into register: UInt8) async throws {
        try await irReceive(pin: pin, into: register, protocol: 0)
    }

    /// Start receiving RC6 mode 0 on `pin` (many TVs). Decoded values include the mode and
    /// toggle bits — a key arrives as e.g. `0x0000C` or `0x1000C` on alternating presses.
    func irReceiveRC6(pin: FirmataPin, into register: UInt8) async throws {
        try await irReceive(pin: pin, into: register, protocol: 1)
    }

    /// Start receiving Coolix on `pin` (Midea-family ACs); the folded 24-bit code lands in
    /// `R[register]` after the byte-complement check.
    func irReceiveCoolix(pin: FirmataPin, into register: UInt8) async throws {
        try await irReceive(pin: pin, into: register, protocol: 2)
    }


    private func irReceive(pin: FirmataPin, into register: UInt8, protocol proto: UInt8) async throws {
        guard register <= 15 else { throw FirmataError.invalidData }
        try await sendToModule(id: IRModule.id,
                               payload: [0x02, pin.number & 0x7F, register & 0x0F, proto])
    }

    @available(*, deprecated, renamed: "irReceiveNEC(pin:into:)")
    func irStartReceive(pin: FirmataPin, into register: UInt8) async throws {
        try await irReceiveNEC(pin: pin, into: register)
    }

    /// Sniff mode (firmware 2.17 / IR module 1.1+): report EVERY received IR burst — any
    /// protocol — as raw mark/space timings on ``messages``; read ``FirmataMessage/irRawFrame``.
    /// Identifies remotes the NEC decoder can't parse (AC units, RC5/RC6, Sony…); replay
    /// what you learned with ``irSendRaw(carrierHz:durations:)``. NEC decode keeps running.
    func irStartRawCapture(pin: FirmataPin) async throws {
        try await sendToModule(id: IRModule.id, payload: [0x06, pin.number & 0x7F, 1])
    }

    /// Stop reporting raw bursts (the receiver itself stays armed).
    func irStopRawCapture() async throws {
        try await sendToModule(id: IRModule.id, payload: [0x06, 0, 0])
    }
}

public extension FirmataMessage {
    /// If this message is an IR received-frame event, the decoded 32-bit NEC code; else `nil`.
    var irCode: UInt32? {
        guard case let .moduleEvent(id, payload) = self, id == IRModule.id else { return nil }
        return IRModule.decodeReceivedEvent(payload)
    }

    /// If this message is a raw-capture burst (``FirmataClient/irStartRawCapture(pin:)``),
    /// the capture: `total` durations seen, `durations` the reported mark/space µs.
    var irRawFrame: (total: Int, durations: [UInt16])? {
        guard case let .moduleEvent(id, payload) = self, id == IRModule.id else { return nil }
        return IRModule.decodeRawFrameEvent(payload)
    }
}

public extension FirmataTaskRecorder {
    /// Task-side IR: same ops as the live calls, recorded (`board.irSendNEC(0x20DF10EF)` —
    /// e.g. power off the TV when a task condition fires). Configure the transmitter once
    /// (live or in the task) before sending.
    func irConfigureTransmit(pin: TaskPin) {
        moduleOp(id: IRModule.id, payload: [0x00, pin.number & 0x7F])
    }

    /// Replay one raw mark/space timing array (µs) at `carrierHz` from a task. To send a key
    /// several times, wrap this in ``FirmataTaskRecorder/repeat(times:gap:_:)``.
    func irSendRaw(carrierHz: UInt32, durations: [UInt16]) {
        moduleOp(id: IRModule.id, payload: IRModule.rawPayload(carrierHz: carrierHz, durations))
    }

    /// Transmit one 32-bit NEC frame from the task.
    func irSendNEC(_ code: UInt32, carrierHz: UInt32 = 38_000) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.necTiming(code))
    }

    /// Transmit one RC6 Mode-0 frame from the task.
    func irSendRC6(_ data: UInt32, bits: Int = 20, carrierHz: UInt32 = 36_000) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.rc6Timing(data, bits: bits))
    }

    /// Transmit a NEC frame whose 32-bit code is read from a device **register** at run time —
    /// the board encodes it (op 0x05, firmware 2.14+). Use this to replay a code the host doesn't
    /// know, e.g. one just received into a register via ``irStartReceive(pin:into:)``.
    func irSendNEC(fromRegister register: TaskNumberRegister) {
        moduleOp(id: IRModule.id, payload: [0x05, 0, register.index & 0x0F])
    }

    /// Transmit an RC6 Mode-0 frame whose code is read from a device **register** at run time —
    /// the board encodes it (op 0x05, firmware 2.14+).
    func irSendRC6(fromRegister register: TaskNumberRegister) {
        moduleOp(id: IRModule.id, payload: [0x05, 1, register.index & 0x0F])
    }

    /// Transmit one 24-bit Coolix frame (Midea-family ACs) from the task, 38 kHz.
    func irSendCoolix(_ code: UInt32, carrierHz: UInt32 = 38_000) {
        irSendRaw(carrierHz: carrierHz, durations: IRModule.coolixTiming(code))
    }

    /// Transmit a Coolix frame whose 24-bit code is read from a device **register** at run
    /// time — the board encodes it (op 0x05 protocol 2, firmware 2.17+). Replay a code just
    /// received via ``irReceiveCoolix(pin:into:)``.
    func irSendCoolix(fromRegister register: TaskNumberRegister) {
        moduleOp(id: IRModule.id, payload: [0x05, 2, register.index & 0x1F])
    }

    /// Start receiving NEC from the task; every decoded frame lands in `dst`, where the
    /// same task (or another) compares it with `ifTrue(.reg(n), .equal, .number(code))`
    /// — a remote control as an offline input device. Record inside `once { }` so a
    /// repeating task doesn't re-arm the receiver every pass.
    func irReceiveNEC(pin: TaskPin, into dst: TaskNumberRegister) {
        irReceive(pin: pin, into: dst, protocol: 0)
    }

    /// Start receiving RC6 mode 0 from the task (many TVs); values include mode + toggle
    /// bits, so compare against both `code` and `code | 0x10000`.
    func irReceiveRC6(pin: TaskPin, into dst: TaskNumberRegister) {
        irReceive(pin: pin, into: dst, protocol: 1)
    }

    /// Start receiving Coolix from the task (Midea-family ACs); the folded 24-bit code
    /// lands in `dst`.
    func irReceiveCoolix(pin: TaskPin, into dst: TaskNumberRegister) {
        irReceive(pin: pin, into: dst, protocol: 2)
    }

    /// Start receiving ANY remote from the task as TEXT (firmware 2.18+): each burst's raw
    /// mark/space timings are written into the string `dst` as `"[d0,d1,d2,…]"` — print it on
    /// an OLED (``displayPrint(_:line:col:)``) or inspect it to read off / learn a protocol.
    /// Create the string first (e.g. `board.string.createString("")`). Capped to the header
    /// plus lead bits of long AC frames (~90 durations), which is what fingerprints a protocol.
    func irReceiveRawText(pin: TaskPin, into dst: TaskString) {
        moduleOp(id: IRModule.id, payload: [0x08, pin.number & 0x7F, (dst.slot.index % 10) + 2])
    }

    private func irReceive(pin: TaskPin, into dst: TaskNumberRegister, protocol proto: UInt8) {
        moduleOp(id: IRModule.id, payload: [0x02, pin.number & 0x7F, dst.index & 0x1F, proto])
    }

    @available(*, deprecated, renamed: "irReceiveNEC(pin:into:)")
    func irStartReceive(pin: TaskPin, into dst: TaskNumberRegister) {
        irReceiveNEC(pin: pin, into: dst)
    }

    /// Start sniff mode from the task (firmware 2.17 / IR 1.1+): every received IR burst —
    /// any protocol — streams to whichever host is connected as raw timings
    /// (``FirmataMessage/irRawFrame``). Record inside `once { }` on repeating tasks.
    func irStartRawCapture(pin: TaskPin) {
        moduleOp(id: IRModule.id, payload: [0x06, pin.number & 0x7F, 1])
    }

    /// Stop sniff-mode reports (the receiver itself stays armed).
    func irStopRawCapture() {
        moduleOp(id: IRModule.id, payload: [0x06, 0, 0])
    }
}
