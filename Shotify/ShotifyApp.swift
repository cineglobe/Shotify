//
//  ShotifyApp.swift
//  Shotify
//

//

import SwiftUI
import AppKit
import ServiceManagement

@main
struct ShotifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var screenshotMonitor = ScreenshotMonitor()
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false
    
    var body: some Scene {
        // Menu Bar Extra - the main interface
        MenuBarExtra {
            MenuBarView(screenshotMonitor: screenshotMonitor)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
        
        // Settings Window
        Settings {
            SettingsView(screenshotMonitor: screenshotMonitor)
        }
    }
    
    init() {
        // Register for launch at login on first launch if enabled by default
        if !hasLaunchedBefore {
            hasLaunchedBefore = true
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon for menu bar only app
        NSApp.setActivationPolicy(.accessory)

        SketchController.shared.updateHotKey()

        #if DEBUG
        // Open the sketch editor on an existing image: -SketchTestImage /path/to/image.png
        if let path = UserDefaults.standard.string(forKey: "SketchTestImage") {
            SketchController.shared.openEditorForTesting(imageURL: URL(fileURLWithPath: path))
        }
        #endif
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var screenshotMonitor: ScreenshotMonitor
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("sketchHotKeyEnabled") private var sketchHotKeyEnabled = true
    @AppStorage("sketchHotKeyKey") private var sketchHotKeyKey = "9"
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        // Toggle Button
        Button {
            isEnabled.toggle()
            if isEnabled {
                screenshotMonitor.startMonitoring()
            } else {
                screenshotMonitor.stopMonitoring()
            }
        } label: {
            Label(isEnabled ? "Disable Auto-Copy" : "Enable Auto-Copy", 
                  systemImage: isEnabled ? "pause.circle" : "play.circle")
        }
        
        Button {
            // Let the menu finish closing before the crosshair appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SketchController.shared.startCapture()
            }
        } label: {
            Label("Capture & Sketch", systemImage: "pencil.and.scribble")
        }
        .keyboardShortcut(
            sketchHotKeyEnabled
                ? KeyboardShortcut(KeyEquivalent(Character(sketchHotKeyKey)), modifiers: [.command, .shift])
                : nil
        )
        
        Divider()
        
        // Actions
        Button {
            openSettings()
            // Bring settings window to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.title == "Settings" || window.title.contains("General") || window.title.contains("Folders") || window.title.contains("About") {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                }
            }
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",", modifiers: .command)
        
        Button {
            screenshotMonitor.openScreenshotsFolder()
        } label: {
            Label("Open Screenshots Folder", systemImage: "folder")
        }
        
        Divider()
        
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Shotify", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
