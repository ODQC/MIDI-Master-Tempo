import Foundation
import CoreMIDI

/// A MIDI source or destination as shown in the UI.
struct MIDIPortInfo: Identifiable, Hashable {
    let id: Int32                 // kMIDIPropertyUniqueID, stable across reconnects
    let name: String
    let endpoint: MIDIEndpointRef
    let device: MIDIDeviceRef     // 0 when the endpoint has no physical device (virtual ports)
}

struct MIDIError: Error {
    let status: OSStatus
}

/// Converts between mach host time (CoreMIDI timestamps) and nanoseconds.
enum HostClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(tb.denom))
    }()

    static func now() -> MIDITimeStamp { mach_absolute_time() }
    static func toNanos(_ t: MIDITimeStamp) -> Double { Double(t) * timebase.numer / timebase.denom }
    static func fromNanos(_ ns: Double) -> MIDITimeStamp { MIDITimeStamp(max(0, ns) * timebase.denom / timebase.numer) }
}

/// Thin wrapper around CoreMIDI: device lists, one input (the master) and timestamped output.
final class MIDIManager {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef] = []

    /// Called on the main thread when devices are plugged or unplugged.
    var onSetupChanged: (() -> Void)?
    /// Called on CoreMIDI's thread for each system message (status, data1, data2, host time, source unique ID).
    var onSystemMessage: ((UInt8, UInt8, UInt8, MIDITimeStamp, Int32) -> Void)?

    init() throws {
        var status = MIDIClientCreateWithBlock("MIDI Master Tempo" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onSetupChanged?() }
            }
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIInputPortCreateWithProtocol(client, "Master In" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
            self?.handle(list, from: Int32(truncatingIfNeeded: Int(bitPattern: refCon)))
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIOutputPortCreate(client, "Clock Out" as CFString, &outPort)
        guard status == noErr else { throw MIDIError(status: status) }
    }

    // MARK: Devices

    func sources() -> [MIDIPortInfo] {
        (0..<MIDIGetNumberOfSources()).map { info(MIDIGetSource($0)) }
    }

    func destinations() -> [MIDIPortInfo] {
        (0..<MIDIGetNumberOfDestinations()).map { info(MIDIGetDestination($0)) }
    }

    private func info(_ endpoint: MIDIEndpointRef) -> MIDIPortInfo {
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)

        var name = "Sin nombre"
        var cfName: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr,
           let value = cfName?.takeRetainedValue() {
            name = value as String
        }

        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        if entity != 0 { MIDIEntityGetDevice(entity, &device) }

        return MIDIPortInfo(id: uid, name: name, endpoint: endpoint, device: device)
    }

    /// Listens to every given source; each message is tagged with its source's unique ID.
    func listen(to sources: [MIDIPortInfo]) {
        for source in connectedSources { MIDIPortDisconnectSource(inPort, source) }
        connectedSources.removeAll()
        for source in sources {
            MIDIPortConnectSource(inPort, source.endpoint, UnsafeMutableRawPointer(bitPattern: Int(source.id)))
            connectedSources.append(source.endpoint)
        }
    }

    // MARK: Sending

    /// Sends a 1–3 byte system message. `time` 0 means "now"; otherwise CoreMIDI delivers it at that host time.
    func send(_ bytes: [UInt8], to destinations: [MIDIEndpointRef], at time: MIDITimeStamp = 0) {
        guard !destinations.isEmpty, let status = bytes.first else { return }
        let d1 = bytes.count > 1 ? bytes[1] : 0
        let d2 = bytes.count > 2 ? bytes[2] : 0
        // UMP message type 0x1 (system common / real time), group 0.
        var word: UInt32 = 0x1000_0000 | UInt32(status) << 16 | UInt32(d1) << 8 | UInt32(d2)

        let list = UnsafeMutablePointer<MIDIEventList>.allocate(capacity: 1)
        defer { list.deallocate() }
        let packet = MIDIEventListInit(list, ._1_0)
        _ = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, time, 1, &word)
        for destination in destinations {
            MIDISendEventList(outPort, destination, list)
        }
    }

    // MARK: Receiving

    private func handle(_ list: UnsafePointer<MIDIEventList>, from sourceID: Int32) {
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let time = packet.pointee.timeStamp == 0 ? HostClock.now() : packet.pointee.timeStamp
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < min(count, words.count) {
                    let word = words[i]
                    let type = word >> 28
                    if type == 0x1 {
                        onSystemMessage?(UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F), time, sourceID)
                    }
                    i += Self.umpWordCount(type)
                }
            }
        }
    }

    private static func umpWordCount(_ type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}
