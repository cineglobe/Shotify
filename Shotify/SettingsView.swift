//
//  SettingsView.swift
//  Shotify
//
//

import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var screenshotMonitor: ScreenshotMonitor
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("playSoundOnCopy") private var playSoundOnCopy = false
    @AppStorage("screenshotFolderPath") private var screenshotFolderPath = ""
    
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                isEnabled: $isEnabled,
                showNotifications: $showNotifications,
                launchAtLogin: $launchAtLogin,
                playSoundOnCopy: $playSoundOnCopy,
                screenshotMonitor: screenshotMonitor
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .tag(0)
            
            FolderSettingsView(
                screenshotFolderPath: $screenshotFolderPath,
                screenshotMonitor: screenshotMonitor
            )
            .tabItem {
                Label("Folders", systemImage: "folder")
            }
            .tag(1)
            
            AboutView()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            .tag(2)
        }
        .frame(width: 450, height: 460)
        .padding()
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    @Binding var isEnabled: Bool
    @Binding var showNotifications: Bool
    @Binding var launchAtLogin: Bool
    @Binding var playSoundOnCopy: Bool
    @ObservedObject var screenshotMonitor: ScreenshotMonitor
    @AppStorage("sketchHotKeyEnabled") private var sketchHotKeyEnabled = true
    @AppStorage("sketchHotKeyKey") private var sketchHotKeyKey = "9"
    
    @State private var showThumbnail = true
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable auto-copy to clipboard", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        if newValue {
                            screenshotMonitor.startMonitoring()
                        } else {
                            screenshotMonitor.stopMonitoring()
                        }
                    }
                
                Toggle("Show notifications", isOn: $showNotifications)
                
                Toggle("Play sound on copy", isOn: $playSoundOnCopy)
                
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
            } header: {
                Text("Behavior")
            }
            
            Section {
                Toggle("Enable Capture & Sketch shortcut", isOn: $sketchHotKeyEnabled)
                    .onChange(of: sketchHotKeyEnabled) { _, _ in
                        SketchController.shared.updateHotKey()
                    }
                
                Picker("Shortcut", selection: $sketchHotKeyKey) {
                    ForEach(SketchController.availableKeys, id: \.key) { option in
                        Text("⌘⇧\(option.key)").tag(option.key)
                    }
                }
                .disabled(!sketchHotKeyEnabled)
                .onChange(of: sketchHotKeyKey) { _, _ in
                    SketchController.shared.updateHotKey()
                }
                
                Text("Select an area like ⌘⇧4, then the screenshot pops up so you can draw arrows, boxes and text on it. Press Return to copy it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Capture & Sketch")
            }
            
            Section {
                Toggle("Show screenshot thumbnail", isOn: $showThumbnail)
                    .onChange(of: showThumbnail) { _, newValue in
                        setShowThumbnail(enabled: newValue)
                    }
                
                Text("Disabling the thumbnail makes screenshots copy faster as there's no 5-second delay.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("macOS Screenshot Settings")
            }
            
            Section {
                HStack {
                    Text("Status:")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(screenshotMonitor.isMonitoring ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(screenshotMonitor.isMonitoring ? "Monitoring" : "Stopped")
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Text("Screenshots copied this session:")
                    Spacer()
                    Text("\(screenshotMonitor.copyCount)")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Statistics")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadThumbnailSetting()
            // Sync launch at login state with system
            syncLaunchAtLoginState()
        }
    }
    
    private func syncLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        let isRegistered = (status == .enabled)
        if launchAtLogin != isRegistered {
            launchAtLogin = isRegistered
        }
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
    
    private func setShowThumbnail(enabled: Bool) {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", enabled ? "true" : "false"]
        try? task.run()
        task.waitUntilExit()
    }
    
    private func loadThumbnailSetting() {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.screencapture", "show-thumbnail"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // defaults returns "0" for false, "1" for true, or error if not set (defaults to true)
                showThumbnail = output != "0"
            }
        } catch {
            showThumbnail = true // Default is enabled
        }
    }
}

// MARK: - Folder Settings
struct FolderSettingsView: View {
    @Binding var screenshotFolderPath: String
    @ObservedObject var screenshotMonitor: ScreenshotMonitor
    
    @State private var isSelectingFolder = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Screenshot Folder")
                        .font(.headline)
                    
                    Text("Select the folder where macOS saves your screenshots. Shotify will monitor this folder for new screenshots.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(alignment: .center) {
                        Text("Screenshot folder path")
                            .frame(width: 140, alignment: .leading)
                        
                        TextField("", text: $screenshotFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                            .frame(maxWidth: .infinity)
                        
                        Button("Browse...") {
                            selectFolder()
                        }
                    }
                    
                    HStack {
                        Button("Use Default Location") {
                            useDefaultLocation()
                        }
                        
                        Button("Detect Current Location") {
                            detectCurrentLocation()
                        }
                    }
                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Monitoring Path:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(screenshotMonitor.monitoringPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if screenshotFolderPath.isEmpty {
                detectCurrentLocation()
            }
        }
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your screenshot folder"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                screenshotFolderPath = url.path
                screenshotMonitor.updateMonitoringPath(url.path)
            }
        }
    }
    
    private func useDefaultLocation() {
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        screenshotFolderPath = desktopPath
        screenshotMonitor.updateMonitoringPath(desktopPath)
    }
    
    private func detectCurrentLocation() {
        screenshotMonitor.followSystemLocation()
        screenshotFolderPath = screenshotMonitor.monitoringPath
    }
    
    private func expandTildePath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }
}

// MARK: - About View
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            Text("Shotify")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Automatically copies screenshots to your clipboard when saved.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Label("Set macOS to save screenshots to a folder", systemImage: "1.circle.fill")
                Label("Shotify monitors that folder for new screenshots", systemImage: "2.circle.fill")
                Label("New screenshots are automatically copied", systemImage: "3.circle.fill")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Spacer()
            
            Text("© 2025 Fin Woods.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .opacity(0.6)
        }
        .padding()
    }
}

#Preview {
    SettingsView(screenshotMonitor: ScreenshotMonitor())
}
