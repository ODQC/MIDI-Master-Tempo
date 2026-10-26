import Foundation
import CoreMIDI
import Combine

struct SlaveConfig: Codable, Equatable {
    var enabled = false
    var transport = true   // also send Start / Stop / Continue
}

private enum Msg {
    static let clock: UInt8 = 0xF8
    static let start: UInt8 = 0xFA
    static let cont: UInt8 = 0xFB
    static let stop: UInt8 = 0xFC
    static let songPosition: UInt8 = 0xF2
}

/// Master/slave routing and the MIDI Clock engine.
///
/// UI state lives in @Published properties (main thread). Everything the clock thread and the
/// CoreMIDI receive thread touch lives in `rt`, guarded by `lock`.
final class SyncController: ObservableObject {
    static let ppqn = 24
    static let bpmRange: ClosedRange<Double> = 20...300

    // MARK: UI state

    @Published private(set) var sources: [MIDIPortInfo] = []
    @Published private(set) var destinations: [MIDIPortInfo] = []
    @Published private(set) var isRunning = false
    @Published private(set) var externalBPM: Double?
    @Published private(set) var currentBeat = -1
    @Published private(set) var beatFlash = false
    @Published private(set) var log: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var slaves: [String: SlaveConfig] = [:]

    /// nil = this app is the master.
    @Published var masterID: Int32? {
        didSet {
            guard masterID != oldValue, !isLoading else { return }
            if isRunning { stop() }
            addLog("Master: \(masterName)")
            refreshDevices()
            save()
        }
    }

    @Published var bpm: Double = 120 {
        didSet {
            let clamped = (min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, bpm)) * 10).rounded() / 10
            if clamped != bpm { bpm = clamped }
            lock.lock(); rt.bpm = bpm; lock.unlock()
            save()
        }
    }

    /// When on, Stop reaches every slave, even those with "Transporte" off.
    @Published var stopStopsAll = true {
        didSet {
            applyRouting()
            save()
        }
    }

    /// When on, pressing Play / Stop on any connected instrument drives the app's transport.
    @Published var remoteTransport = true {
        didSet {
            lock.lock(); rt.remoteTransport = remoteTransport; lock.unlock()
            save()
        }
    }

    @Published var clockWhileStopped = true {
        didSet {
            lock.lock(); rt.clockWhileStopped = clockWhileStopped; lock.unlock()
            save()
        }
    }

    var isInternalMaster: Bool { masterID == nil }

    var masterName: String {
        guard let id = masterID else { return "Esta app" }
        return sources.first { $0.id == id }?.name ?? "Dispositivo desconectado"
    }

    var displayedBPM: Double? { isInternalMaster ? bpm : externalBPM }

    var activeSlaveCount: Int { destinations.filter { isActive($0) }.count }

    // MARK: Real-time state

    private struct RTState {
        var internalMaster = true
        var bpm = 120.0
        var running = false
        var clockWhileStopped = true
        var remoteTransport = true
        var masterID: Int32?
        var clockTargets: [MIDIEndpointRef] = []
        var transportTargets: [MIDIEndpointRef] = []
        var stopTargets: [MIDIEndpointRef] = []
        var tick = 0                  // clocks since Start, for the beat display
        var nextTickNs: Double = 0    // internal clock: host time of the next unsent clock
        var externalTicks: [MIDITimeStamp] = []
    }

    private let lock = NSLock()
    private var rt = RTState()
    private var midi: MIDIManager?
    private var isLoading = false
    private var tapTimes: [Date] = []
    private var lastTransportSent = Date.distantPast
    private var bpmTimer: Timer?
    private var activity: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    // MARK: Setup

    init() {
        load()
        do {
            let manager = try MIDIManager()
            manager.onSetupChanged = { [weak self] in self?.refreshDevices() }
            manager.onSystemMessage = { [weak self] status, d1, d2, time, sourceID in
                self?.handleIncoming(status, d1, d2, time, from: sourceID)
            }
            midi = manager
        } catch {
            errorMessage = "No se pudo iniciar CoreMIDI (código \((error as? MIDIError)?.status ?? -1))."
        }

        // Keep timing tight even when the window is in the background (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Generando reloj MIDI")

        rt.bpm = bpm
        rt.clockWhileStopped = clockWhileStopped
        rt.remoteTransport = remoteTransport
        refreshDevices()

        let thread = Thread { [weak self] in self?.clockLoop() }
        thread.name = "MIDI Clock"
        thread.qualityOfService = .userInteractive
        thread.start()

        bpmTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateExternalBPM()
        }
        addLog("Listo.")
    }

    func refreshDevices() {
        guard let midi else { return }
        sources = midi.sources()
        destinations = midi.destinations()
        for destination in destinations where slaves[key(destination)] == nil {
            slaves[key(destination)] = SlaveConfig()
        }
        // Listen to everything: the master for clock, the rest for their Play / Stop buttons.
        midi.listen(to: sources)
        applyRouting()
    }

    /// Recomputes which destinations get clock / transport and hands them to the real-time side.
    private func applyRouting() {
        let clock = destinations.filter { isActive($0) }
        let transport = clock.filter { slaves[key($0)]?.transport ?? true }
        lock.lock()
        rt.internalMaster = isInternalMaster
        rt.masterID = masterID
        rt.clockTargets = clock.map(\.endpoint)
        rt.transportTargets = transport.map(\.endpoint)
        rt.stopTargets = (stopStopsAll ? clock : transport).map(\.endpoint)
        if !rt.internalMaster { rt.nextTickNs = 0 }
        rt.externalTicks.removeAll()
        lock.unlock()
    }

    // MARK: Slaves

    private func key(_ port: MIDIPortInfo) -> String { String(port.id) }

    func config(for port: MIDIPortInfo) -> SlaveConfig { slaves[key(port)] ?? SlaveConfig() }

    func setEnabled(_ enabled: Bool, for port: MIDIPortInfo) {
        slaves[key(port), default: SlaveConfig()].enabled = enabled
        addLog("\(port.name): \(enabled ? "slave activado" : "slave desactivado")")
        applyRouting()
        save()
    }

    func setTransport(_ transport: Bool, for port: MIDIPortInfo) {
        slaves[key(port), default: SlaveConfig()].transport = transport
        applyRouting()
        save()
    }

    /// True when a destination belongs to the same device as the master, so sending clock back would loop.
    func isLoop(_ destination: MIDIPortInfo) -> Bool {
        guard let id = masterID, let master = sources.first(where: { $0.id == id }) else { return false }
        if master.device != 0 && master.device == destination.device { return true }
        return Self.normalized(master.name) == Self.normalized(destination.name)
    }

    func isActive(_ destination: MIDIPortInfo) -> Bool {
        config(for: destination).enabled && !isLoop(destination)
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"\b(in|out|input|output)\b"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Transport

    func togglePlay() { isRunning ? stop() : play() }

    func play() { startTransport(fromTop: true) }

    func continuePlaying() { startTransport(fromTop: false) }

    private func startTransport(fromTop: Bool) {
        guard let midi else { return }
        lock.lock()
        let targets = rt.transportTargets
        if rt.internalMaster {
            // Start goes out just before the next clock so slaves count that clock as the first one.
            let nowNs = HostClock.toNanos(HostClock.now())
            if rt.nextTickNs < nowNs + 1_000_000 { rt.nextTickNs = nowNs + 3_000_000 }
            let startTime = HostClock.fromNanos(rt.nextTickNs - 500_000)
            if fromTop {
                midi.send([Msg.songPosition, 0, 0], to: targets, at: startTime)
                midi.send([Msg.start], to: targets, at: startTime)
                rt.tick = 0
            } else {
                midi.send([Msg.cont], to: targets, at: startTime)
            }
        } else {
            // The master instrument owns the clock; we can only pass transport on to the slaves.
            if fromTop {
                midi.send([Msg.songPosition, 0, 0], to: targets)
                midi.send([Msg.start], to: targets)
                rt.tick = 0
            } else {
                midi.send([Msg.cont], to: targets)
            }
        }
        rt.running = true
        lock.unlock()
        isRunning = true
        lastTransportSent = Date()
        addLog(fromTop ? "Play" : "Continuar")
    }

    func stop() {
        lock.lock()
        midi?.send([Msg.stop], to: rt.stopTargets)
        rt.running = false
        lock.unlock()
        isRunning = false
        lastTransportSent = Date()
        currentBeat = -1
        addLog("Stop")
    }

    // MARK: Tempo

    func nudge(_ delta: Double) { bpm += delta }

    func tap() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
        guard tapTimes.count >= 2, let first = tapTimes.first else { return }
        let interval = now.timeIntervalSince(first) / Double(tapTimes.count - 1)
        bpm = 60 / interval
    }

    // MARK: Internal clock

    private func clockLoop() {
        let lookaheadNs = 30_000_000.0   // schedule clocks 30 ms ahead; CoreMIDI sends them on time
        while true {
            var pending: [MIDITimeStamp] = []
            var beats: [(MIDITimeStamp, Int)] = []

            lock.lock()
            let shouldTick = rt.internalMaster && (rt.running || rt.clockWhileStopped)
            if shouldTick {
                let nowNs = HostClock.toNanos(HostClock.now())
                if rt.nextTickNs == 0 || rt.nextTickNs < nowNs - 20_000_000 {
                    rt.nextTickNs = nowNs + 2_000_000
                }
                while rt.nextTickNs < nowNs + lookaheadNs {
                    let time = HostClock.fromNanos(rt.nextTickNs)
                    pending.append(time)
                    if rt.running {
                        if rt.tick % Self.ppqn == 0 { beats.append((time, rt.tick / Self.ppqn)) }
                        rt.tick += 1
                    }
                    rt.nextTickNs += 60_000_000_000 / (rt.bpm * Double(Self.ppqn))
                }
                for time in pending { midi?.send([Msg.clock], to: rt.clockTargets, at: time) }
            } else if rt.internalMaster {
                rt.nextTickNs = 0
            }
            lock.unlock()

            for (time, beat) in beats { showBeat(beat, at: time) }
            usleep(2_000)
        }
    }

    // MARK: External master

    /// Runs on CoreMIDI's thread. Clock and transport from the master are forwarded; Play / Stop / Continue
    /// from any other instrument act like the app's own buttons.
    private func handleIncoming(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, _ time: MIDITimeStamp, from sourceID: Int32) {
        lock.lock()
        let fromMaster = !rt.internalMaster && sourceID == rt.masterID
        let remote = rt.remoteTransport
        lock.unlock()

        if fromMaster {
            handleMasterMessage(status, d1, d2, time)
        } else if remote, [Msg.start, Msg.cont, Msg.stop].contains(status) {
            DispatchQueue.main.async { self.handleRemoteTransport(status, from: sourceID) }
        }
    }

    private func handleRemoteTransport(_ status: UInt8, from sourceID: Int32) {
        // A slave that echoes what we just sent must not restart or stop the song.
        guard Date().timeIntervalSince(lastTransportSent) > 0.3 else { return }
        let name = sources.first { $0.id == sourceID }?.name ?? "Un equipo"
        switch status {
        case Msg.start where !isRunning:
            addLog("\(name) pulsó Play")
            play()
        case Msg.cont where !isRunning:
            addLog("\(name) pulsó Continuar")
            continuePlaying()
        case Msg.stop where isRunning:
            addLog("\(name) pulsó Stop")
            stop()
        default:
            break
        }
    }

    private func handleMasterMessage(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, _ time: MIDITimeStamp) {
        guard [Msg.clock, Msg.start, Msg.cont, Msg.stop, Msg.songPosition].contains(status) else { return }
        var beat: Int?
        var runningChanged: Bool?

        lock.lock()
        guard !rt.internalMaster else { lock.unlock(); return }
        switch status {
        case Msg.clock:
            midi?.send([Msg.clock], to: rt.clockTargets)
            rt.externalTicks.append(time)
            if rt.externalTicks.count > Self.ppqn * 2 { rt.externalTicks.removeFirst() }
            if rt.running {
                if rt.tick % Self.ppqn == 0 { beat = rt.tick / Self.ppqn }
                rt.tick += 1
            }
        case Msg.start:
            midi?.send([Msg.start], to: rt.transportTargets)
            rt.running = true
            rt.tick = 0
            runningChanged = true
        case Msg.cont:
            midi?.send([Msg.cont], to: rt.transportTargets)
            rt.running = true
            runningChanged = true
        case Msg.stop:
            midi?.send([Msg.stop], to: rt.stopTargets)
            rt.running = false
            runningChanged = false
        default: // song position pointer, in sixteenth notes
            midi?.send([Msg.songPosition, d1, d2], to: rt.transportTargets)
            rt.tick = (Int(d2) << 7 | Int(d1)) * 6
        }
        lock.unlock()

        if let beat { showBeat(beat, at: time) }
        if let running = runningChanged {
            DispatchQueue.main.async {
                self.isRunning = running
                if !running { self.currentBeat = -1 }
                self.addLog(running ? "El master arrancó" : "El master se detuvo")
            }
        }
    }

    private func updateExternalBPM() {
        guard !isInternalMaster else { if externalBPM != nil { externalBPM = nil }; return }
        lock.lock()
        let ticks = rt.externalTicks
        lock.unlock()
        guard ticks.count >= 6, let first = ticks.first, let last = ticks.last,
              HostClock.toNanos(HostClock.now()) - HostClock.toNanos(last) < 500_000_000 else {
            externalBPM = nil
            return
        }
        let avgNs = (HostClock.toNanos(last) - HostClock.toNanos(first)) / Double(ticks.count - 1)
        externalBPM = (60_000_000_000 / (avgNs * Double(Self.ppqn)) * 10).rounded() / 10
    }

    // MARK: UI helpers

    private func showBeat(_ beat: Int, at time: MIDITimeStamp) {
        let delay = (HostClock.toNanos(time) - HostClock.toNanos(HostClock.now())) / 1_000_000_000
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            guard self.isRunning else { return }
            self.currentBeat = beat
            self.beatFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { self.beatFlash = false }
        }
    }

    private func addLog(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("[\(time)] \(message)", at: 0)
        if log.count > 100 { log.removeLast() }
    }

    // MARK: Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if defaults.object(forKey: "bpm") != nil { bpm = defaults.double(forKey: "bpm") }
        if defaults.object(forKey: "masterID") != nil { masterID = Int32(defaults.integer(forKey: "masterID")) }
        if defaults.object(forKey: "stopStopsAll") != nil { stopStopsAll = defaults.bool(forKey: "stopStopsAll") }
        if defaults.object(forKey: "remoteTransport") != nil { remoteTransport = defaults.bool(forKey: "remoteTransport") }
        if defaults.object(forKey: "clockWhileStopped") != nil { clockWhileStopped = defaults.bool(forKey: "clockWhileStopped") }
        if let data = defaults.data(forKey: "slaves"),
           let saved = try? JSONDecoder().decode([String: SlaveConfig].self, from: data) {
            slaves = saved
        }
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(bpm, forKey: "bpm")
        if let masterID { defaults.set(Int(masterID), forKey: "masterID") } else { defaults.removeObject(forKey: "masterID") }
        defaults.set(clockWhileStopped, forKey: "clockWhileStopped")
        defaults.set(remoteTransport, forKey: "remoteTransport")
        defaults.set(stopStopsAll, forKey: "stopStopsAll")
        if let data = try? JSONEncoder().encode(slaves) { defaults.set(data, forKey: "slaves") }
    }
}
