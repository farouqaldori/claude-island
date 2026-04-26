import AppKit
import IOKit
import Mixpanel
import Sparkle
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windowManager: WindowManager?
    private var statusBarController: StatusBarController?
    private var notchViewModel: NotchViewModel?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var displayModeObserver: NSObjectProtocol?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")
        Mixpanel.mainInstance().flush()

        // Set up notification center delegate for foreground notifications
        UNUserNotificationCenter.current().delegate = self
        Task {
            // Register notification categories
            await registerNotificationCategories()
            await SystemNotificationService.shared.requestAuthorization()
        }

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        // Initialize window manager and status bar controller
        windowManager = WindowManager()

        // Set up UI based on current display mode setting
        setupUIForCurrentMode()

        // Observe display mode changes
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Check if display mode changed
            self?.handleDisplayModeChange()
        }

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    private func setupUIForCurrentMode() {
        let mode = AppSettings.displayMode

        switch mode {
        case .notch:
            _ = windowManager?.setupNotchWindow()
            statusBarController?.teardown()

        case .statusBar:
            windowManager?.hideNotchWindow()
            // Create a shared view model for status bar
            if let controller = windowManager?.windowController {
                notchViewModel = controller.viewModel
                statusBarController = StatusBarController(viewModel: controller.viewModel)
            } else {
                // Create placeholder view model for status bar only
                let placeholderVM = createPlaceholderViewModel()
                notchViewModel = placeholderVM
                statusBarController = StatusBarController(viewModel: placeholderVM)
            }
            statusBarController?.setup()
        }
    }

    private func createPlaceholderViewModel() -> NotchViewModel {
        // Create a minimal view model for status bar mode without notch geometry
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        return NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: 750,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )
    }

    private var lastDisplayMode: DisplayMode = AppSettings.displayMode

    private func handleDisplayModeChange() {
        let newMode = AppSettings.displayMode
        guard newMode != lastDisplayMode else { return }
        lastDisplayMode = newMode

        // Switch UI mode
        switch newMode {
        case .notch:
            statusBarController?.teardown()
            windowManager?.showNotchWindow()

        case .statusBar:
            windowManager?.hideNotchWindow()
            if let vm = notchViewModel {
                statusBarController = StatusBarController(viewModel: vm)
            } else if let controller = windowManager?.windowController {
                statusBarController = StatusBarController(viewModel: controller.viewModel)
            } else {
                statusBarController = StatusBarController(viewModel: createPlaceholderViewModel())
            }
            statusBarController?.setup()
        }
    }

    private func handleScreenChange() {
        // Only handle screen changes in notch mode
        if AppSettings.displayMode == .notch {
            _ = windowManager?.setupNotchWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Mixpanel.mainInstance().flush()
        updateCheckTimer?.invalidate()
        screenObserver = nil
        statusBarController?.teardown()

        if let observer = displayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Register notification categories for alert-style notifications
    private func registerNotificationCategories() async {
        // Create action for "Open" button
        let openAction = UNNotificationAction(
            identifier: "OPEN_ACTION",
            title: "打开",
            options: [.foreground]
        )

        // Create category for task completion notifications
        let taskCompleteCategory = UNNotificationCategory(
            identifier: "TASK_COMPLETE",
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Register categories
        UNUserNotificationCenter.current().setNotificationCategories([taskCompleteCategory])
        print("✅ Notification categories registered")
    }

    /// Allow notifications to be shown when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification banner, play sound, and show badge even when app is in foreground
        // Using .alert ensures it behaves like an alert notification
        completionHandler([.alert, .sound, .badge])
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Bring app to front when user taps notification
        NSApplication.shared.activate(ignoringOtherApps: true)
        completionHandler()
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = ClaudePaths.projectsDir

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
            return
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
