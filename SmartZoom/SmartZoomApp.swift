import SwiftUI
import ServiceManagement

let showIconKey = "showMenuBarIcon"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening SmartZoom again (Finder, Spotlight, `open`) while it runs brings
    /// the menu bar icon back and opens Settings, so hiding the icon never locks you out.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: showIconKey)
        SettingsWindow.shared.show()
        return false
    }
}

@main
struct SmartZoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = ZoomEngine.shared
    @AppStorage(showIconKey) private var showIcon = true

    var body: some Scene {
        MenuBarExtra("SmartZoom", systemImage: "plus.magnifyingglass", isInserted: $showIcon) {
            Toggle("Zoom Enabled", isOn: $engine.enabled)
            if !engine.tapRunning {
                Button("Grant Accessibility Permission…") { engine.requestPermission() }
            }
            Divider()
            Button("Settings…") { SettingsWindow.shared.show() }
                .keyboardShortcut(",")
            Button("Quit SmartZoom") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// A regular titled window hosting the settings form. Managed by hand because a
/// menu-bar-only (LSUIElement) app has to activate itself to bring a window forward.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environmentObject(ZoomEngine.shared)))
            w.title = "SmartZoom Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: ZoomEngine
    @AppStorage(showIconKey) private var showIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Zoom") {
                Toggle("Option + scroll zooms", isOn: $engine.enabled)
                LabeledContent("Speed") {
                    Slider(value: $engine.sensitivity, in: 0.25...3)
                }
                Toggle("Invert scroll direction", isOn: $engine.invert)
                Text("Option + middle-click toggles Smart Zoom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle("Show icon in menu bar", isOn: $showIcon)
                if !showIcon {
                    Text("Open SmartZoom again from Applications or Spotlight to get back here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Permission") {
                LabeledContent("Accessibility") {
                    if engine.tapRunning {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { engine.requestPermission() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
