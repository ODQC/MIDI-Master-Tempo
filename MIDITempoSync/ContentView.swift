import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        VStack(spacing: 16) {
            if let error = sync.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 16) {
                MasterPanel()
                SlavesPanel()
            }
            LogPanel()
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 560)
    }
}

// MARK: - Master

private struct MasterPanel: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Fuente de tempo", selection: $sync.masterID) {
                    Text("Esta app (reloj interno)").tag(Int32?.none)
                    if !sync.sources.isEmpty { Divider() }
                    ForEach(sync.sources) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                    if let id = sync.masterID, !sync.sources.contains(where: { $0.id == id }) {
                        Text("Dispositivo desconectado").tag(Optional(id))
                    }
                }

                Text(sync.isInternalMaster
                     ? "La app genera el reloj MIDI. Controla el tempo aquí."
                     : "El instrumento elegido manda el tempo y la app lo reenvía a los slaves. Configúralo para que envíe MIDI Clock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline) {
                    Text(sync.displayedBPM.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("BPM").foregroundStyle(.secondary)
                }

                BeatLights(beat: sync.currentBeat, flash: sync.beatFlash)

                if sync.isInternalMaster {
                    TempoControls()
                }

                HStack {
                    Button(sync.isRunning ? "■ Stop" : "▶ Play") { sync.togglePlay() }
                        .keyboardShortcut(.space, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .tint(sync.isRunning ? Color.green : Color.accentColor)
                    Button("⏯ Continuar") { sync.continuePlaying() }
                        .disabled(sync.isRunning)
                }
                Toggle("El Stop del master detiene a todos los slaves", isOn: $sync.stopStopsAll)
                    .help("Incluye a los slaves que tienen “Transporte” desactivado")
                Toggle("Los botones Play/Stop de los equipos controlan la app", isOn: $sync.remoteTransport)
                    .help("Al pulsar Play o Stop en un sinte o sampler, la app arranca o detiene a todos los slaves")
                Text("Barra espaciadora: Play / Stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Master", systemImage: "metronome")
        }
    }
}

private struct TempoControls: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Slider(value: $sync.bpm, in: SyncController.bpmRange)
            HStack {
                Button("−1") { sync.nudge(-1) }
                Button("−0.1") { sync.nudge(-0.1) }
                TextField("BPM", value: $sync.bpm, format: .number.precision(.fractionLength(1)))
                    .frame(width: 70)
                    .multilineTextAlignment(.center)
                Button("+0.1") { sync.nudge(0.1) }
                Button("+1") { sync.nudge(1) }
                Button("Tap") { sync.tap() }
                    .keyboardShortcut("t", modifiers: [])
            }
            Toggle("Enviar reloj aunque esté detenido", isOn: $sync.clockWhileStopped)
                .help("Los slaves muestran el tempo antes de darle a Play")
        }
    }
}

private struct BeatLights: View {
    let beat: Int
    let flash: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<4) { i in
                Circle()
                    .fill(isLit(i) ? (i == 0 ? Color.red : Color.orange) : Color.secondary.opacity(0.25))
                    .frame(width: 24, height: 24)
            }
            Spacer()
            Text(beat >= 0 ? "Compás \(beat / 4 + 1) · Tiempo \(beat % 4 + 1)" : "Detenido")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func isLit(_ i: Int) -> Bool { flash && beat >= 0 && beat % 4 == i }
}

// MARK: - Slaves

private struct SlavesPanel: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if sync.destinations.isEmpty {
                    Text("No hay salidas MIDI. Conecta tus instrumentos por USB.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(sync.destinations) { destination in
                    SlaveRow(port: destination)
                    Divider()
                }
                Text("“Transporte” también envía Play, Stop y Continuar. Desactívalo si solo quieres que el instrumento siga el tempo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Slaves (\(sync.activeSlaveCount) activos)", systemImage: "pianokeys")
        }
    }
}

private struct SlaveRow: View {
    @EnvironmentObject private var sync: SyncController
    let port: MIDIPortInfo

    var body: some View {
        let config = sync.config(for: port)
        let loop = sync.isLoop(port)
        HStack(alignment: .top) {
            Toggle(isOn: Binding(get: { config.enabled }, set: { sync.setEnabled($0, for: port) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.name)
                    if loop {
                        Text("Es el mismo equipo que el master: no se le reenvía su propio reloj.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(loop)
            Spacer()
            Toggle("Transporte", isOn: Binding(get: { config.transport }, set: { sync.setTransport($0, for: port) }))
                .disabled(loop || !config.enabled)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8)
    }
}

// MARK: - Log

private struct LogPanel: View {
    @EnvironmentObject private var sync: SyncController

    var body: some View {
        GroupBox {
            ScrollView {
                Text(sync.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 90)
        } label: {
            Label("Actividad", systemImage: "list.bullet")
        }
    }
}
