import AppKit
import SwiftUI

struct AtmosMenuLabel: View {
    @ObservedObject var model: AppModel
    @State private var didLaunch = false
    var body: some View {
        Image(systemName: model.listening ? "cursorarrow" : "mic.slash")
            .accessibilityLabel("Atmos")
            .onAppear {
                guard !didLaunch else { return }
                didLaunch = true
                model.startStandby()
                if model.needsSetup { model.openExpandedMenu(.settings) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.stopDisplayTaps()
                model.cancel(silent: true)
                model.voice.stop()
            }
    }
}

struct AtmosMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.working ? model.status : model.active ? "Atmos is active" : model.listening ? "Waiting for Hey Atmos" : "Microphone paused")
        Divider()
        Button("Open Atmos Menu") { model.openExpandedMenu() }
        Button(model.active || model.working ? "Stop Atmos" : "Activate Atmos") {
            if model.active || model.working { model.sleep() } else { model.listenNow() }
        }.disabled(!model.active && !model.working && (model.microphoneMuted || model.menuIsPresented))
        Divider()
        Button("Settings…") { model.openExpandedMenu(.settings) }.keyboardShortcut(",")
        Button(model.voiceMonitoringRequested ? "Pause microphone" : "Resume microphone") { model.toggleListening() }
        Divider()
        Button("Quit Atmos") { model.cancel(silent: true); model.voice.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
