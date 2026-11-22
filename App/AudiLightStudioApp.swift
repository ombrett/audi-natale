import SwiftUI
import UIKit

@main
struct AudiLightStudioApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var log: PacketLog
    @StateObject private var ble: BLEManager
    @StateObject private var ideal: IdealController

    init() {
        let settings = AppSettings()
        let log = PacketLog()
        let ble = BLEManager(log: log, settings: settings)
        let ideal = IdealController(ble: ble, settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _log = StateObject(wrappedValue: log)
        _ble = StateObject(wrappedValue: ble)
        _ideal = StateObject(wrappedValue: ideal)

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.surface)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.background)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(ble)
                .environmentObject(ideal)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    /// Cinque tab (oltre cinque iOS crea il menu "Altro"); LED Map e Animations sono raggiungibili
    /// dalla Dashboard e dalle schermate Scan ed Editor.
    enum Tab: Hashable { case dashboard, lab, scan, editor, settings }
    @State private var tab: Tab = .dashboard

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { DashboardView(tab: $tab) }
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(Tab.dashboard)
            NavigationStack { BluetoothLabView() }
                .tabItem { Label("BT Lab", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.lab)
            NavigationStack { ScanView() }
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(Tab.scan)
            NavigationStack { EditorView() }
                .tabItem { Label("Editor", systemImage: "paintbrush.pointed") }
                .tag(Tab.editor)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
