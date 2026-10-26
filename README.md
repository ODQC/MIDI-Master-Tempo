# MIDI Master Tempo

App nativa para macOS que sincroniza el tempo de tus instrumentos MIDI por USB usando MIDI Clock, al estilo de la sincronización MIDI de Ableton.

## Qué hace
- **Master:** elige quién manda el tempo: la propia app (reloj interno) o cualquiera de tus instrumentos.
- **Slaves:** marca qué instrumentos siguen el tempo. La opción "Transporte" decide si también reciben Play, Stop y Continuar.
- **Tempo:** BPM de 20 a 300, slider, botones de ajuste fino, campo numérico y Tap tempo (tecla T).
- **Transporte:** Play, Stop y Continuar; barra espaciadora = Play/Stop.
- **El Stop del master detiene a todos los slaves**, aunque tengan "Transporte" desactivado (opcional).
- **Los botones Play/Stop de los equipos controlan la app** (opcional).
- Evita bucles: nunca reenvía al master su propio reloj.
- Detecta instrumentos al conectarlos y recuerda tu configuración.

## Requisitos
- macOS 14 o superior.
- Xcode 16 o superior para compilar.

## Compilar
Abre `MIDITempoSync.xcodeproj` en Xcode y pulsa Run, o desde Terminal:

    xcodebuild -project MIDITempoSync.xcodeproj -target MIDITempoSync -configuration Release SYMROOT=build build
    open "build/Release/MIDI Master Tempo.app"

## Configuración de los instrumentos
- **Yamaha MOX6 / MOXF8:** Utility → MIDI → MIDI IN/OUT = USB. Para seguir a la app: MIDI Sync = MIDI. Para ser master: MIDI Sync = Internal y Clock Out = On.
- **Novation Circuit Rhythm:** en Settings, activa Clock Rx para seguir o Clock Tx para mandar el tempo.

## Icono
`icon/make_icon.swift` genera el icono (mini piano con luces de pulso).
