import SwiftUI
import CoreBluetooth

struct BluetoothLabView: View {
    enum LabSection: String, CaseIterable, Identifiable {
        case devices = "Dispositivi"
        case gatt = "GATT"
        case protocolTest = "Protocollo"
        case hex = "HEX"
        case log = "Log"
        var id: String { rawValue }
    }

    @EnvironmentObject var ble: BLEManager
    @State private var section: LabSection = .devices
    @State private var writeTarget: String = IdealUUID.command

    var body: some View {
        VStack(spacing: 0) {
            ConnectionHeader()
                .padding(.horizontal)
                .padding(.top, 8)
            Picker("Sezione", selection: $section) {
                ForEach(LabSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch section {
                case .devices: DeviceListSection()
                case .gatt: GATTSection(writeTarget: $writeTarget, section: $section)
                case .protocolTest: ProtocolSection()
                case .hex: HexEditorSection(writeTarget: $writeTarget)
                case .log: LogSection()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .screenBackground()
        .navigationTitle("Bluetooth Lab")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Intestazione stato

struct ConnectionHeader: View {
    @EnvironmentObject var ble: BLEManager

    var color: Color {
        switch ble.phase {
        case .ready: return Theme.ok
        case .connecting, .discovering, .reconnecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return ble.bluetoothState == .poweredOn ? Theme.textSecondary : Theme.danger
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: color, pulsing: ble.phase == .reconnecting || ble.phase == .connecting)
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.connectedName ?? ble.bluetoothState.label)
                    .font(.subheadline.weight(.semibold))
                Text(ble.phase.label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let rssi = ble.rssi {
                Label("\(rssi) dBm", systemImage: "wave.3.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let mtu = ble.maxWriteWithoutResponse {
                Text("MTU \(mtu)B").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .animation(.easeInOut, value: ble.phase)
    }
}

// MARK: - Dispositivi

struct DeviceListSection: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Scansione", systemImage: "dot.radiowaves.left.and.right") {
                    HStack(spacing: 10) {
                        Button(ble.isScanning ? "Ferma" : "Scansiona") {
                            ble.isScanning ? ble.stopScan() : ble.startScan()
                        }
                        .buttonStyle(AccentButtonStyle())
                        .enabled(ble.bluetoothState == .poweredOn)

                        Button("Ultimo dispositivo") { ble.reconnectLast() }
                            .buttonStyle(AccentButtonStyle(filled: false))
                            .enabled(settings.lastPeripheralID != nil && ble.bluetoothState == .poweredOn && !ble.phase.isActive)
                    }
                    if ble.phase.isActive {
                        Button("Disconnetti") { ble.disconnect() }
                            .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                    }
                    Toggle("Solo controller ISP-/IDL-", isOn: $settings.showOnlyIdealDevices)
                        .font(.subheadline)
                    if ble.bluetoothState == .unauthorized {
                        Text("Permesso Bluetooth negato: abilitalo in Impostazioni › Privacy › Bluetooth.")
                            .font(.caption).foregroundStyle(Theme.danger)
                    }
                }

                if ble.sortedDevices.isEmpty {
                    Text(ble.isScanning ? "Ricerca in corso…" : "Nessun dispositivo. Chiudi l'app iDeal LED: il controller accetta una sola connessione.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                ForEach(ble.sortedDevices) { d in
                    DeviceRow(device: d)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: AppSettings
    let device: DiscoveredDevice

    var isConnected: Bool { ble.connectedID == device.id && ble.phase == .ready }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isIdeal ? "lightbulb.led.wide.fill" : "dot.radiowaves.right")
                .font(.title3)
                .foregroundStyle(device.isTarget(settings.targetName) ? Theme.accent : Theme.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name).font(.subheadline.weight(.semibold))
                    if device.isTarget(settings.targetName) { Badge(text: "ATTESO", color: Theme.accent) }
                }
                Text("\(device.rssi) dBm · \(device.id.uuidString.prefix(8))…")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                if !device.advertisedServices.isEmpty {
                    Text("Adv: " + device.advertisedServices.joined(separator: ", "))
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if isConnected {
                Badge(text: "CONNESSO", color: Theme.ok)
            } else {
                Button("Connetti") { ble.connect(device.id) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .enabled(device.isConnectable != false)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }
}

// MARK: - GATT

struct GATTSection: View {
    @EnvironmentObject var ble: BLEManager
    @Binding var writeTarget: String
    @Binding var section: BluetoothLabView.LabSection

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if ble.services.isEmpty {
                    Text("Connetti un dispositivo per vedere servizi e caratteristiche.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary).padding()
                }
                ForEach(ble.services) { s in
                    Card(title: s.label, systemImage: "square.stack.3d.up") {
                        Text(s.uuid).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                        ForEach(s.characteristics) { c in
                            CharacteristicRow(info: c) {
                                writeTarget = c.uuid
                                section = .hex
                            }
                            if c.id != s.characteristics.last?.id { Divider().overlay(Theme.stroke) }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
}

struct CharacteristicRow: View {
    @EnvironmentObject var ble: BLEManager
    let info: GATTCharacteristicInfo
    var onSelectForWrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.uuid).font(Theme.monoSmall).textSelection(.enabled)
                Spacer()
            }
            Text(info.role.label)
                .font(.caption)
                .foregroundStyle(info.role.writable ? Theme.accent : (info.role == .other ? Theme.textSecondary : Theme.warning))
            HStack(spacing: 6) {
                ForEach(info.propertyNames, id: \.self) { Badge(text: $0, color: Theme.textSecondary) }
            }
            ForEach(info.descriptors) { d in
                Text("Descrittore \(d.uuid): \(d.value ?? "—")")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let v = info.lastValue {
                Text("Ultimo valore [\(v.count)]: \(Hex.string(v))")
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if info.canNotify {
                    Toggle(isOn: Binding(get: { info.isNotifying }, set: { ble.setNotify($0, for: info.uuid) })) {
                        Text("Notifiche").font(.caption)
                    }
                    .fixedSize()
                }
                if info.canRead {
                    Button("Leggi") { ble.read(info.uuid) }.font(.caption).buttonStyle(.bordered)
                }
                if !info.descriptors.isEmpty {
                    Button("Descrittori") { ble.readDescriptors(info.uuid) }.font(.caption).buttonStyle(.bordered)
                }
                Spacer()
                if info.role.writable && (info.canWrite || info.canWriteWithoutResponse) {
                    Button("Scrivi…", action: onSelectForWrite).font(.caption).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
