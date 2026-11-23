import SwiftUI
import UIKit

@main
struct AudiLightStudioApp: App {
    // Strumenti della prima versione (Bluetooth Lab, singola centralina)
    @StateObject private var settings: AppSettings
    @StateObject private var log: PacketLog
    @StateObject private var ble: BLEManager
    @StateObject private var ideal: IdealController
    @StateObject private var presets = PresetStore()
    @StateObject private var maps = LEDMapStore()
    @StateObject private var sequence = SequencePlayer()
    // App completa: più centraline, mappa 3D, effetti
    @StateObject private var hub: ControllerHub
    @StateObject private var carMaps = CarMapStore()
    @StateObject private var library: EffectLibrary
    @StateObject private var player: EffectPlayer
    @StateObject private var model = CarModelStore()
    @StateObject private var ui = AppUIState()

    init() {
        let settings = AppSettings()
        let log = PacketLog()
        let ble = BLEManager(log: log, settings: settings)
        let ideal = IdealController(ble: ble, settings: settings)
        let hub = ControllerHub(log: log)
        let library = EffectLibrary()
        let player = EffectPlayer(hub: hub, library: library)
        _settings = StateObject(wrappedValue: settings)
        _log = StateObject(wrappedValue: log)
        _ble = StateObject(wrappedValue: ble)
        _ideal = StateObject(wrappedValue: ideal)
        _hub = StateObject(wrappedValue: hub)
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: player)

        // Su iOS 26 l'aspetto personalizzato nasconde i titoli: si usa quello di sistema (già scuro).
        if #unavailable(iOS 26) { Self.styleNavigationBar() }
    }

    private static func styleNavigationBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.background)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            MainShell()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(ble)
                .environmentObject(ideal)
                .environmentObject(presets)
                .environmentObject(maps)
                .environmentObject(sequence)
                .environmentObject(hub)
                .environmentObject(carMaps)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(model)
                .environmentObject(ui)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
