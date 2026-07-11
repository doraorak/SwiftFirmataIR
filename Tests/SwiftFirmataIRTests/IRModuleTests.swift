import Testing
import Foundation
import SwiftFirmataClient
@testable import SwiftFirmataIR   // encoders/ids are internal; the public API is the extensions

/// Minimal loopback transport (the client's own MockTransport is test-internal to
/// that package, so the IR package tests provide their own against the public protocol).
final class CaptureTransport: FirmataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[UInt8]] = []
    var lastSent: [UInt8]? { lock.withLock { sent.last } }
    private var cont: AsyncThrowingStream<UInt8, Error>.Continuation?
    func send(_ bytes: [UInt8]) async throws { lock.withLock { sent.append(bytes) } }
    func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { self.cont = $0 }
    }
    func inject(_ bytes: [UInt8]) { for b in bytes { cont?.yield(b) } }
}

@Suite("IR module")
struct IRModuleTests {

    @Test func recordedReceiveBytes() {
        // The receive trio shares op 0x02; only the protocol byte differs.
        for (proto, record) in [(UInt8(0), { (r: FirmataTaskRecorder) in r.irReceiveNEC(pin: .pin(18), into: .reg(9)) }),
                                (1, { $0.irReceiveRC6(pin: .pin(18), into: .reg(9)) }),
                                (2, { $0.irReceiveCoolix(pin: .pin(18), into: .reg(9)) })] {
            let rec = FirmataTaskRecorder()
            record(rec)
            #expect(rec.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x02, 18, 9, proto, 0xF7])
        }
    }

    private func makeClient() async -> (FirmataClient, CaptureTransport) {
        let t = CaptureTransport()
        let c = FirmataClient(transport: t)
        await c.connect()
        await Task.yield()
        return (c, t)
    }

    @Test func liveBytes() async throws {
        let (c, t) = await makeClient()
        // Configure just sets the pin; carrier is per send.
        try await c.irConfigureTransmit(pin: .pin(4))
        #expect(t.lastSent == [0xF0, 0x0D, 0x01, 0x00, 4, 0xF7])
        // NEC goes out via the raw op (0x03) at 38 kHz.
        try await c.irSendNEC(0x20DF10EF)
        let necPayload = IRModule.rawPayload(carrierHz: 38_000, IRModule.necTiming(0x20DF10EF))
        #expect(necPayload.first == 0x03 && necPayload[1] == 38)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01] + necPayload + [0xF7])
        // RC6 uses the same raw path at 36 kHz.
        try await c.irSendRC6(0x0C)
        let rc6Payload = IRModule.rawPayload(carrierHz: 36_000, IRModule.rc6Timing(0x0C))
        #expect(rc6Payload[1] == 36)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01] + rc6Payload + [0xF7])
        try await c.irReceiveNEC(pin: .pin(5), into: 9)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01, 0x02, 5, 9, 0, 0xF7])
        try await c.irReceiveCoolix(pin: .pin(5), into: 9)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01, 0x02, 5, 9, 2, 0xF7])
        // Coolix send rides the raw op like the others, at 38 kHz.
        try await c.irSendCoolix(0xB27BE0)
        let coolixPayload = IRModule.rawPayload(carrierHz: 38_000, IRModule.coolixTiming(0xB27BE0))
        #expect(t.lastSent == [0xF0, 0x0D, 0x01] + coolixPayload + [0xF7])
    }

    @Test func encoders() {
        // NEC: 9/4.5 ms header, 32 bits, trailing mark = 67 durations.
        let nec = IRModule.necTiming(0x20DF10EF)
        #expect(nec.count == 67)
        #expect(nec[0] == 9000 && nec[1] == 4500 && nec.last == 562)
        #expect(nec[2] == 562 && nec[3] == 562)          // first bit (bit31 = 0)
        // RC6 Mode-0: 6t/2t leader, start mark; different data → different waveform.
        let rc6 = IRModule.rc6Timing(0x0C)
        #expect(rc6[0] == 2664 && rc6[1] == 888 && rc6[2] == 444)
        #expect(rc6 != IRModule.rc6Timing(0x11))
        // rawPayload: op, kHz, 14-bit LE duration pairs.
        let p = IRModule.rawPayload(carrierHz: 36_000, [2664, 888])
        #expect(p == [0x03, 36, UInt8(2664 & 0x7F), UInt8((2664 >> 7) & 0x7F),
                      UInt8(888 & 0x7F), UInt8((888 >> 7) & 0x7F)])
    }

    @Test func recorderBytes() {
        let r = FirmataTaskRecorder()
        r.irSendNEC(0x20DF10EF)
        let necPayload = IRModule.rawPayload(carrierHz: 38_000, IRModule.necTiming(0x20DF10EF))
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01] + necPayload + [0xF7])
        let r2 = FirmataTaskRecorder()
        r2.irReceiveNEC(pin: .pin(5), into: .reg(9))
        #expect(r2.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x02, 5, 9, 0, 0xF7])
        let r3 = FirmataTaskRecorder()
        r3.irSendCoolix(fromRegister: .reg(9))
        #expect(r3.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x05, 2, 9, 0xF7])
    }

    @Test func coolixTiming() {
        // Doubled message: 2 × (header + 48 bits + footer) + inter-section gap = 199.
        let d = IRModule.coolixTiming(0xB23F30)
        #expect(d.count == 199)
        #expect(d[0] == 4692 && d[1] == 4416)
        #expect(d[99] == 5244 && d[100] == 4692)          // gap, then the repeat section
        // 0xB2 = 10110010: first two bits 1,0 → spaces 1656, 552.
        #expect(d[3] == 1656 && d[5] == 552)
        // Byte 2 is followed by its complement (bit 0 of 0xB2 vs bit 0 of 0x4D differ).
        #expect(IRModule.coolixTiming(0xB27BE0) != d)
    }

    @Test func decodeEvent() {
        let limbs: [UInt8] = (0..<5).map { UInt8((0x20DF10EF >> (7 * $0)) & 0x7F) }
        #expect(IRModule.decodeReceivedEvent([IRModule.receivedEvent] + limbs) == 0x20DF10EF)
        #expect(IRModule.decodeReceivedEvent([0x99] + limbs) == nil)   // wrong subcommand
    }

    @Test func recordedRawCaptureBytes() {
        let rec = FirmataTaskRecorder()
        rec.irStartRawCapture(pin: .pin(18))
        rec.irStopRawCapture()
        // moduleOp wrapper: F0 7B 7F 33 <id> <payload> F7, twice
        #expect(rec.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x06, 18, 1, 0xF7,
                              0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x06, 0, 0, 0xF7])
    }

    @Test func rawCaptureDecode() {
        // event 0x07: total=300 (0x2C,0x02), then two durations 9000 and 4500 µs
        let payload: [UInt8] = [0x07, 0x2C, 0x02,
                                UInt8(9000 & 0x7F), UInt8((9000 >> 7) & 0x7F),
                                UInt8(4500 & 0x7F), UInt8((4500 >> 7) & 0x7F)]
        let msg = FirmataMessage.moduleEvent(id: 1, payload: payload)
        let frame = try! #require(msg.irRawFrame)
        #expect(frame.total == 300)
        #expect(frame.durations == [9000, 4500])
        #expect(FirmataMessage.moduleEvent(id: 1, payload: [0x03, 0, 0, 0, 0, 0]).irRawFrame == nil)
    }

    @Test func messageIRCode() {
        // Public receive API: FirmataMessage.irCode decodes an IR moduleEvent.
        let limbs: [UInt8] = (0..<5).map { UInt8((0x20DF10EF >> (7 * $0)) & 0x7F) }
        #expect(FirmataMessage.moduleEvent(id: IRModule.id, payload: [IRModule.receivedEvent] + limbs).irCode == 0x20DF10EF)
        #expect(FirmataMessage.moduleEvent(id: 0x42, payload: [IRModule.receivedEvent] + limbs).irCode == nil)  // other module
        #expect(FirmataMessage.stringData("hi").irCode == nil)                                                  // not a module event
    }
}
