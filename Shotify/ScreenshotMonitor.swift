//
//  ScreenshotMonitor.swift
//  Shotify
//

//

import Foundation
import AppKit
import Combine
import UserNotifications

/// Service that monitors for new screenshots and copies them to the clipboard
/// Optimized for minimal resource usage - uses only Spotlight metadata query
@MainActor
final class ScreenshotMonitor: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastCopiedScreenshot: String?
    @Published private(set) var lastCopiedTime: String = ""
    @Published private(set) var copyCount: Int = 0
    @Published private(set) var monitoringPath: String = ""
    
    // Spotlight metadata query for instant screenshot detection
    private var metadataQuery: NSMetadataQuery?
    private var processedFiles: Set<String> = []
    /// While following the system location, checks whether it changed (⌘⇧5 → Options → Save to).
    private var locationCheck: Timer?

    /// True unless the user picked a folder themselves; then Shotify follows macOS's screenshot location.
    private var followsSystemLocation: Bool {
        UserDefaults.standard.object(forKey: "screenshotFolderFollowsSystem") as? Bool ?? true
    }
    
    // Cached date formatter (creating formatters is expensive)
    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
    
    init() {
        setupDefaultPath()
        requestNotificationPermissions()
        
        // Auto-start if enabled (default to true for first run)
        let isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true
        if isEnabled {
            startMonitoring()
        }
    }
    
    // MARK: - Setup
    
    private func setupDefaultPath() {
        if !followsSystemLocation,
           let savedPath = UserDefaults.standard.string(forKey: "screenshotFolderPath"),
           !savedPath.isEmpty {
            monitoringPath = expandTildePath(savedPath)
        } else {
            detectScreenshotLocation()
        }
    }

    /// The folder macOS saves screenshots to (Desktop unless changed in ⌘⇧5 → Options).
    static func systemScreenshotLocation() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !value.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "~" { return home.path }
            if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))).path }
            return trimmed
        }
        return home.appendingPathComponent("Desktop").path
    }

    /// Follow the system location again (used by Settings → Detect Current Location).
    func followSystemLocation() {
        UserDefaults.standard.set(true, forKey: "screenshotFolderFollowsSystem")
        applyPath(Self.systemScreenshotLocation())
        startLocationCheck()
    }

    private func startLocationCheck() {
        locationCheck?.invalidate()
        locationCheck = nil
        guard followsSystemLocation, isMonitoring else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.followsSystemLocation else { return }
                CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
                let current = Self.systemScreenshotLocation()
                if current != self.monitoringPath { self.applyPath(current) }
            }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        locationCheck = timer
    }
    
    /// Expands ~ to the user's home directory
    private func expandTildePath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }
    
    private func detectScreenshotLocation() {
        monitoringPath = Self.systemScreenshotLocation()
        UserDefaults.standard.set(monitoringPath, forKey: "screenshotFolderPath")
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        // Verify the path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: monitoringPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("📸 Shotify: Directory does not exist: \(monitoringPath)")
            return
        }
        
        // Use Spotlight metadata query for efficient detection
        // This is more efficient than file system monitoring as it:
        // 1. Uses existing Spotlight infrastructure (no extra overhead)
        // 2. Only notifies on actual screenshot files (kMDItemIsScreenCapture)
        // 3. Doesn't require polling or file system watchers
        startMetadataQuery()
        
        isMonitoring = true
        startLocationCheck()
        #if DEBUG
        print("📸 Shotify: Started monitoring \(monitoringPath)")
        #endif
    }
    
    func stopMonitoring() {
        // Remove observers first to prevent callbacks during cleanup
        if let query = metadataQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
        }
        metadataQuery = nil
        locationCheck?.invalidate()
        locationCheck = nil
        
        isMonitoring = false
        #if DEBUG
        print("📸 Shotify: Stopped monitoring")
        #endif
    }
    
    /// A folder the user chose: stop following the system location.
    func updateMonitoringPath(_ path: String) {
        UserDefaults.standard.set(false, forKey: "screenshotFolderFollowsSystem")
        applyPath(path)
    }

    private func applyPath(_ path: String) {
        let wasMonitoring = isMonitoring
        
        if wasMonitoring {
            stopMonitoring()
        }
        
        monitoringPath = expandTildePath(path)
        UserDefaults.standard.set(monitoringPath, forKey: "screenshotFolderPath")
        
        // Clear processed files for new path
        processedFiles.removeAll()
        
        if wasMonitoring {
            startMonitoring()
        }
    }
    
    // MARK: - Spotlight Metadata Query (Fast Detection)
    
    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        metadataQuery = query
        
        // Search for files that are screenshots (kMDItemIsScreenCapture = 1)
        // in our monitored folder - this is very efficient as Spotlight already indexes this
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [monitoringPath]
        
        // No sorting needed - we process all results anyway
        // This saves CPU cycles on each update
        
        // Batch updates to reduce notification frequency
        query.notificationBatchingInterval = 0.1
        
        // Listen for results
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        
        query.start()
        #if DEBUG
        print("📸 Shotify: Started Spotlight metadata query for screenshots")
        #endif
    }
    
    @objc private func metadataQueryDidFinishGathering(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        
        // Disable updates during processing to avoid concurrent modification
        query.disableUpdates()
        
        // Reserve capacity to avoid reallocations
        processedFiles.reserveCapacity(query.resultCount)
        
        // Index existing screenshots efficiently
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: kMDItemPath as String) as? String {
                processedFiles.insert(path)
            }
        }
        
        query.enableUpdates()
        #if DEBUG
        print("📸 Shotify: Indexed \(processedFiles.count) existing screenshots")
        #endif
    }
    
    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        
        query.disableUpdates()
        
        // Check added items
        if let addedItems = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] {
            for item in addedItems {
                handleNewScreenshotItem(item)
            }
        }
        
        // Also check changed items (in case file was updated)
        if let changedItems = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] {
            for item in changedItems {
                handleNewScreenshotItem(item)
            }
        }
        
        query.enableUpdates()
    }
    
    private func handleNewScreenshotItem(_ item: NSMetadataItem) {
        guard let path = item.value(forAttribute: kMDItemPath as String) as? String,
              !processedFiles.contains(path),
              path.hasPrefix(monitoringPath) else { return }
        
        // Check creation date - only process recent screenshots (within last 30 seconds)
        if let creationDate = item.value(forAttribute: kMDItemFSCreationDate as String) as? Date {
            guard Date().timeIntervalSince(creationDate) < 30 else {
                processedFiles.insert(path)
                return
            }
        }
        
        processedFiles.insert(path)
        
        let fileURL = URL(fileURLWithPath: path)
        
        #if DEBUG
        print("📸 Shotify: Detected new screenshot: \(fileURL.lastPathComponent)")
        #endif
        
        // Copy to clipboard with minimal delay for file to be ready
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.copyImageToClipboard(fileURL: fileURL)
        }
    }
    
    // MARK: - Clipboard Operations
    
    private func copyImageToClipboard(fileURL: URL) async {
        let fileName = fileURL.lastPathComponent
        
        // Quick retry loop - file should be ready quickly after Spotlight indexes it
        var image: NSImage?
        for _ in 0..<5 {
            image = NSImage(contentsOf: fileURL)
            if image != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        
        guard let image else {
            #if DEBUG
            print("📸 Shotify: Failed to load image: \(fileName)")
            #endif
            return
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Write image and file URL in one operation
        guard pasteboard.writeObjects([image]) else {
            #if DEBUG
            print("📸 Shotify: Failed to copy to clipboard")
            #endif
            return
        }
        
        // Add file URL for apps that prefer file references
        pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
        
        // Update state
        lastCopiedScreenshot = fileName
        lastCopiedTime = timeFormatter.string(from: Date())
        copyCount += 1
        
        // Optional feedback (check UserDefaults only when needed)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "playSoundOnCopy") {
            NSSound(named: "Pop")?.play()
        }
        if defaults.bool(forKey: "showNotifications") {
            showNotification(for: fileName)
        }
        
        #if DEBUG
        print("📸 Shotify: Copied \(fileName) to clipboard")
        #endif
    }
    
    // MARK: - Notifications
    
    private static var hasRequestedNotificationPermission = false
    
    private func requestNotificationPermissions() {
        guard !Self.hasRequestedNotificationPermission else { return }
        Self.hasRequestedNotificationPermission = true
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            #if DEBUG
            if let error { print("📸 Shotify: Notification permission error: \(error)") }
            #endif
        }
    }
    
    private func showNotification(for fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot Copied"
        content.body = "\(fileName) copied to clipboard"
        
        let request = UNNotificationRequest(
            identifier: "shotify-\(copyCount)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Utilities
    
    func openScreenshotsFolder() {
        let url = URL(fileURLWithPath: monitoringPath)
        NSWorkspace.shared.open(url)
    }
}
