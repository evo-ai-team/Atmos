import AppKit
import SwiftUI

struct MouseMenuLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var didLaunch = false
    var body: some View {
        Image(systemName: model.listening ? "cursorarrow" : "mic.slash")
            .accessibilityLabel("Mouse")
            .onAppear {
                guard !didLaunch else { return }
                didLaunch = true
                model.startStandby()
                if model.needsSetup { openWindow(id: "settings"); NSApp.activate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.cancel(silent: true)
                model.voice.stop()
            }
    }
}

struct MouseMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.working ? model.status : model.active ? "Mouse is active" : model.listening ? "Waiting for Hey Mouse" : "Microphone paused")
        Divider()
        Button(model.active || model.working ? "Stop Mouse" : "Activate Mouse") {
            if model.active || model.working { model.sleep() } else { model.listenNow() }
        }
        Divider()
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate() }.keyboardShortcut(",")
        Button(model.listening ? "Pause microphone" : "Resume microphone") { model.toggleListening() }
        Divider()
        Button("Quit Mouse") { model.cancel(silent: true); model.voice.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
