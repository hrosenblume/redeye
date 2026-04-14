import AppKit
import UserNotifications

// MARK: - Configuration

private enum Config {
    static let resourcesDir = Bundle.main.bundlePath + "/Contents/Resources"
    static let scriptPath = resourcesDir + "/claude-ordo-keepalive.sh"
    static let instructionsPath = resourcesDir + "/instructions.txt"
    static let tmuxPath: String = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; command -v tmux"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "/opt/homebrew/bin/tmux" : path
    }()
    static let depPollInterval: TimeInterval = 2.0
    static let depPollTimeout: TimeInterval = 600.0
    static let depCheckDismissedKey = "depCheckDismissed"
    static let searchPaths = "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local"
    static let pollInterval: TimeInterval = 30
    static let permissionPollInterval: TimeInterval = 5
    static let permissionPromptPatterns = [
        "[Y/n]", "[y/N]", "Allow", "Deny", "approve", "permission",
        "Would you like to proceed", "auto-accept edits", "manually approve",
    ]
    // Auto-respond patterns: when detected, Redeye sends the response without asking
    static let autoResponses: [(pattern: String, keys: [String])] = [
        ("Context limit reached", ["/compact", "Enter"]),
        ("ExitPlanMode", ["y", "Enter"]),
    ]
    static let attachRefreshDelay: TimeInterval = 2.0
    static let instructionsWindowSize = NSSize(width: 520, height: 520)
    static let instructionsTextInset = NSSize(width: 16, height: 16)
    static let pathMaxLength = 60
    static let userDefaultsKey = "projects"
    static let githubReleasesURL = "https://api.github.com/repos/hrosenblume/redeye/releases/latest"
    static let updateCheckInterval: TimeInterval = 86400
    static let lastUpdateCheckKey = "lastUpdateCheck"
}

private enum Icon {
    static let active = "cup.and.saucer.fill"
    static let inactive = "cup.and.saucer"
    static let activeFallback = "\u{2615}"
    static let inactiveFallback = "\u{2B58}"
}

private enum StatusIndicator {
    case alive, attached, missing, stopped

    var dot: String {
        switch self {
        case .missing:  return "\u{26A0} "
        case .alive, .attached: return "\u{25CF} "
        case .stopped:  return "\u{25CB} "
        }
    }

    var dotColor: NSColor {
        switch self {
        case .missing:  return .systemOrange
        case .alive, .attached: return .systemGreen
        case .stopped:  return .secondaryLabelColor
        }
    }

    var suffix: String? {
        switch self {
        case .attached: return " \u{2014} session open"
        case .missing:  return " \u{2014} folder missing"
        default: return nil
        }
    }
}

// MARK: - Project Model

struct Project: Codable, Equatable {
    var path: String
    var enabled: Bool
    var permissionMode: String?

    var name: String {
        (path as NSString).lastPathComponent
    }

    var sessionPrefix: String {
        let safe = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var h: UInt32 = 2166136261
        for byte in path.utf8 {
            h ^= UInt32(byte)
            h &*= 16777619
        }
        return "redeye-\(safe)-\(String(h % 0xFFFFFF, radix: 16))"
    }

    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = path
        if path.hasPrefix(home) {
            display = "~" + path.dropFirst(home.count)
        }
        if display.count > Config.pathMaxLength {
            return "..." + display.suffix(Config.pathMaxLength - 3)
        }
        return display
    }

    var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Session State

enum SessionState {
    case stopped
    case running
    case attached

    var isAlive: Bool { self == .running || self == .attached }
}

// MARK: - Dependency Checking

private struct DependencyStatus {
    var hasHomebrew: Bool
    var hasTmux: Bool
    var hasClaude: Bool

    var allPresent: Bool { hasTmux && hasClaude }

    var missingItems: [String] {
        var items: [String] = []
        if !hasHomebrew { items.append("Homebrew (macOS package manager)") }
        if !hasTmux { items.append("tmux (terminal multiplexer)") }
        if !hasClaude { items.append("Claude Code CLI") }
        return items
    }

    static func check() -> DependencyStatus {
        DependencyStatus(
            hasHomebrew: shellHas("brew"),
            hasTmux: shellHas("tmux"),
            hasClaude: shellHas("claude")
        )
    }

    private static func shellHas(_ command: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc",
            "export PATH=\"$PATH:\(Config.searchPaths)\"; command -v \(command)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !output.isEmpty && task.terminationStatus == 0
    }
}

// MARK: - Dependency Installer

private class DependencyInstallerController {
    private var pollTimer: Timer?
    private var pollStartTime: Date?
    private var onComplete: ((Bool) -> Void)?
    private var isInstalling = false

    func checkAndPromptIfNeeded(completion: @escaping (Bool) -> Void) {
        if isInstalling {
            completion(true)
            return
        }
        let status = DependencyStatus.check()
        if status.allPresent {
            completion(true)
            return
        }
        if UserDefaults.standard.bool(forKey: Config.depCheckDismissedKey) {
            completion(true)
            return
        }
        showInstallPrompt(status: status, completion: completion)
    }

    private func showInstallPrompt(status: DependencyStatus, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Redeye needs a few things installed"
        alert.informativeText = "The following are missing:\n\n"
            + status.missingItems.map { "  \u{2022} \($0)" }.joined(separator: "\n")
            + "\n\nRedeye will open Terminal to install them. You may be asked for your password."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Don\u{2019}t Ask Again")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            runInstallInTerminal(status: status, completion: completion)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: Config.depCheckDismissedKey)
            completion(true)
        default:
            completion(true)
        }
    }

    private func runInstallInTerminal(status: DependencyStatus, completion: @escaping (Bool) -> Void) {
        pollTimer?.invalidate()
        pollTimer = nil
        isInstalling = true

        let script = buildInstallScript(status: status)
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let appleScript = "tell application \"Terminal\" to do script \"\(escaped)\""
        task.arguments = appleScript.components(separatedBy: "\n").flatMap { ["-e", $0] }
        try? task.run()

        onComplete = completion
        pollStartTime = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.depPollInterval, repeats: true) { [weak self] timer in
            self?.pollForDependencies(timer: timer)
        }
    }

    private func pollForDependencies(timer: Timer) {
        let status = DependencyStatus.check()
        let elapsed = Date().timeIntervalSince(pollStartTime ?? Date())

        if status.allPresent {
            timer.invalidate()
            pollTimer = nil
            isInstalling = false
            showAlert(title: "All set!",
                      message: "All dependencies are installed.\n\nNote: You may need to run \"claude\" in Terminal once to set up authentication.")
            onComplete?(true)
            onComplete = nil
        } else if elapsed > Config.depPollTimeout {
            timer.invalidate()
            pollTimer = nil
            isInstalling = false
            showAlert(title: "Still installing?",
                      message: "Redeye will detect the tools automatically once they\u{2019}re ready. You can close this and keep using the app.",
                      style: .warning)
            onComplete?(true)
            onComplete = nil
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func buildInstallScript(status: DependencyStatus) -> String {
        var sections: [[String]] = []

        sections.append([
            "echo '=== Redeye Dependency Installer ==='",
            "export PATH=\\\"$PATH:\(Config.searchPaths)\\\""
        ])

        if !status.hasHomebrew {
            sections.append([
                "echo '>>> Installing Homebrew...'",
                "/bin/bash -c \\\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\"",
                "eval \\\"$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)\\\""
            ])
        }

        if !status.hasTmux {
            sections.append([
                "echo '>>> Installing tmux...'",
                "brew install tmux"
            ])
        }

        if !status.hasClaude {
            sections.append([
                "echo '>>> Installing Claude Code...'",
                "curl -fsSL https://cli.claude.ai/install.sh | sh"
            ])
        }

        sections.append([
            "echo ''",
            "echo '=== Installation complete! ==='",
            "echo 'Note: Run claude in Terminal to set up authentication.'",
            "echo 'You can close this window.'"
        ])

        return sections.map { $0.joined(separator: " && ") }.joined(separator: " ; ")
    }
}

// MARK: - Update Checker

private class UpdateChecker {
    private var latestVersion: String?
    private var assetURL: String?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return compareVersions(latest, isNewerThan: currentVersion)
    }

    func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: Config.lastUpdateCheckKey)
        if Date().timeIntervalSince1970 - lastCheck < Config.updateCheckInterval { return }
        check()
    }

    func check(silent: Bool = true) {
        guard let url = URL(string: Config.githubReleasesURL) else {
            if !silent { showErrorAlert() }
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if !silent { DispatchQueue.main.async { self.showErrorAlert() } }
                return
            }

            // Find the .zip asset's direct download URL
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zipURL = assets
                .first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })
                .flatMap { $0["browser_download_url"] as? String }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Config.lastUpdateCheckKey)

            DispatchQueue.main.async {
                self.latestVersion = version
                self.assetURL = zipURL
                if self.updateAvailable {
                    self.showUpdateAlert(version: version)
                } else if !silent {
                    self.showUpToDateAlert()
                }
            }
        }.resume()
    }

    func showUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available \u{2014} v\(version)"
        alert.informativeText = "A new version of Redeye is available. You\u{2019}re currently on v\(currentVersion).\n\nRedeye will download and install the update, then relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall()
        }
    }

    private func downloadAndInstall() {
        guard let urlString = assetURL, let url = URL(string: urlString) else {
            showErrorAlert()
            return
        }

        showProgressWindow(text: "Downloading update\u{2026}")

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }

            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self.hideProgressWindow()
                    self.showErrorAlert()
                }
                return
            }

            // Move zip to a stable temp location (URLSession's temp file gets deleted when callback returns)
            let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("redeye-update")
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let zipPath = stagingDir.appendingPathComponent("Redeye.app.zip")
            do {
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
            } catch {
                DispatchQueue.main.async {
                    self.hideProgressWindow()
                    self.showErrorAlert()
                }
                return
            }

            DispatchQueue.main.async {
                self.updateProgressText("Installing\u{2026}")
            }
            self.runInstaller(zipPath: zipPath.path)
        }.resume()
    }

    // MARK: - Progress Window

    private func showProgressWindow(text: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Redeye Update"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        let container = NSView(frame: window.contentView!.bounds)

        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 60, width: 300, height: 22)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        container.addSubview(label)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 300, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        container.addSubview(bar)

        window.contentView = container
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        progressWindow = window
        progressLabel = label
        progressBar = bar
    }

    private func updateProgressText(_ text: String) {
        progressLabel?.stringValue = text
    }

    private func hideProgressWindow() {
        progressBar?.stopAnimation(nil)
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressLabel = nil
        progressBar = nil
    }

    private func runInstaller(zipPath: String) {
        // Spawn a detached bash script that:
        //  1) Waits for Redeye to quit
        //  2) Removes the old app
        //  3) Unzips the new one into /Applications
        //  4) Strips quarantine and relaunches
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        # Wait up to 10s for Redeye (pid \(pid)) to exit
        for i in $(seq 1 50); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.2
        done
        rm -rf /Applications/Redeye.app
        /usr/bin/ditto -xk "\(zipPath)" /Applications/
        xattr -cr /Applications/Redeye.app 2>/dev/null
        open /Applications/Redeye.app
        rm -rf "$(dirname "\(zipPath)")"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            DispatchQueue.main.async { self.showErrorAlert() }
            return
        }

        // Quit so the installer can replace us
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You\u{2019}re Up to Date"
        alert.informativeText = "Redeye v\(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not reach GitHub to check for updates. Please check your connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }
}

// MARK: - NSMenu Helpers

private extension NSMenu {
    func addActionItem(_ title: String, action: Selector, target: AnyObject,
                       key: String = "", representedObject: Any? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.representedObject = representedObject
        addItem(item)
    }

    func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var sessionStatus: [String: SessionState] = [:]
    private var pendingPermissions: [String: String] = [:]
    private var recentAutoResponses: [String: String] = [:]
    private var pollTimer: Timer?
    private var permissionPollTimer: Timer?
    private var isUpdating = false
    private var instructionsWindow: NSWindow?
    private var depStatus: DependencyStatus?
    private let depInstaller = DependencyInstallerController()
    private let updateChecker = UpdateChecker()

    // MARK: - Project Persistence

    var projects: [Project] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Config.userDefaultsKey),
                  let list = try? JSONDecoder().decode([Project].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Config.userDefaultsKey)
            }
        }
    }

    // MARK: - Multi-Session Helpers

    private func sessions(for project: Project) -> [String] {
        sessionStatus.keys
            .filter { $0.hasPrefix(project.sessionPrefix + "-") }
            .sorted()
    }

    private func aliveSessions(for project: Project) -> [String] {
        sessions(for: project).filter { sessionStatus[$0]?.isAlive == true }
    }

    private func nextSessionName(for project: Project) -> String {
        // Only count live slots — .stopped entries linger in sessionStatus and
        // would otherwise cause max()+1 to skip the freed index. Fill the
        // lowest available slot so gaps don't accumulate forever.
        let taken = Set(aliveSessions(for: project).compactMap { name -> Int? in
            guard let suffix = name.split(separator: "-").last, let n = Int(suffix) else { return nil }
            return n
        })
        var next = 1
        while taken.contains(next) { next += 1 }
        return String(format: "%@-%02d", project.sessionPrefix, next)
    }

    private func sessionIndex(from name: String) -> String {
        String(name.split(separator: "-").last ?? "01")
    }

    // MARK: - State Queries

    private func state(for project: Project) -> SessionState {
        let states = sessions(for: project).compactMap { sessionStatus[$0] }
        if states.contains(.attached) { return .attached }
        if states.contains(.running) { return .running }
        return .stopped
    }

    private func isAlive(_ project: Project) -> Bool {
        state(for: project).isAlive
    }

    private var anyRunning: Bool {
        sessionStatus.values.contains(where: \.isAlive)
    }

    private func indicator(for project: Project) -> StatusIndicator {
        if !project.folderExists { return .missing }
        switch state(for: project) {
        case .attached: return .attached
        case .running:  return .alive
        case .stopped:  return .stopped
        }
    }

    private func indicatorForSession(_ session: String) -> StatusIndicator {
        switch sessionStatus[session] ?? .stopped {
        case .attached: return .attached
        case .running:  return .alive
        case .stopped:  return .stopped
        }
    }

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        depStatus = DependencyStatus.check()
        migrateLegacySessions()
        refreshAllStatus()
        tuneAllSessions()
        refreshUI()
        startPolling()
        startPermissionPolling()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )

        if depStatus?.allPresent == false {
            depInstaller.checkAndPromptIfNeeded { [weak self] _ in
                guard let self else { return }
                self.depStatus = DependencyStatus.check()
                self.refreshUI()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.continueSetup()
                }
            }
        } else {
            continueSetup()
        }
    }

    private func continueSetup() {
        if projects.isEmpty {
            showFolderPicker()
        } else {
            startEnabledProjects()
        }
        updateChecker.checkIfNeeded()
    }

    // MARK: - UI

    private func refreshUI() {
        updateIcon()
        buildMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName = anyRunning ? Icon.active : Icon.inactive
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Redeye") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = anyRunning ? Icon.activeFallback : Icon.inactiveFallback
            button.image = nil
        }
    }

    private func attributedProjectTitle(for project: Project) -> NSAttributedString {
        let status = indicator(for: project)
        let alive = isAlive(project)

        let result = NSMutableAttributedString()

        result.append(NSAttributedString(
            string: status.dot,
            attributes: [.foregroundColor: status.dotColor,
                         .font: NSFont.menuFont(ofSize: 0)]
        ))

        result.append(NSAttributedString(
            string: project.name,
            attributes: [.font: alive
                ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                : NSFont.menuFont(ofSize: 0)]
        ))

        if let suffix = status.suffix {
            result.append(NSAttributedString(
                string: suffix,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
            ))
        }

        return result
    }

    private func buildMenu() {
        let menu = NSMenu()

        if projects.isEmpty {
            menu.addDisabledItem("No projects configured")
        } else {
            buildProjectItems(in: menu)
            menu.addItem(NSMenuItem.separator())
            buildBulkActions(in: menu)
        }

        menu.addActionItem("Add Folder\u{2026}", action: #selector(addFolder), target: self, key: "n")
        menu.addActionItem("Getting Started", action: #selector(showInstructions), target: self)

        if let status = depStatus, !status.allPresent {
            menu.addItem(NSMenuItem.separator())
            menu.addDisabledItem("\u{26A0} Missing Dependencies")
            if UserDefaults.standard.bool(forKey: Config.depCheckDismissedKey) {
                menu.addActionItem("Check Dependencies\u{2026}", action: #selector(resetAndInstallDependencies), target: self)
            } else {
                menu.addActionItem("Install Dependencies\u{2026}", action: #selector(installDependencies), target: self)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addActionItem("Check for Updates\u{2026}", action: #selector(checkForUpdates), target: self)
        menu.addActionItem("Quit Redeye", action: #selector(quitApp), target: self, key: "q")
        menu.addItem(NSMenuItem.separator())
        menu.addDisabledItem("v\(updateChecker.currentVersion)")

        statusItem.menu = menu
    }

    private func buildProjectItems(in menu: NSMenu) {
        for project in projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.attributedTitle = attributedProjectTitle(for: project)
            item.submenu = buildProjectSubmenu(for: project)
            menu.addItem(item)
        }
    }

    private func buildProjectSubmenu(for project: Project) -> NSMenu {
        let sub = NSMenu()
        sub.addDisabledItem(project.shortPath)
        sub.addItem(NSMenuItem.separator())

        if project.folderExists {
            let projectSessions = sessions(for: project)

            // Per-session items
            for session in projectSessions {
                let idx = sessionIndex(from: session)
                let sessionState = sessionStatus[session] ?? .stopped
                let indicator = indicatorForSession(session)
                let info: [String: String] = ["session": session, "path": project.path]

                let sessionSub = NSMenu()
                if sessionState.isAlive {
                    sessionSub.addActionItem("Open Session", action: #selector(attachSession(_:)),
                                             target: self, representedObject: info)
                    sessionSub.addActionItem("Stop", action: #selector(stopSession(_:)),
                                             target: self, representedObject: info)
                    sessionSub.addActionItem("Respawn", action: #selector(respawnSession(_:)),
                                             target: self, representedObject: info)
                } else {
                    sessionSub.addActionItem("Start", action: #selector(startSession(_:)),
                                             target: self, representedObject: info)
                    if projectSessions.count > 1 {
                        sessionSub.addActionItem("Remove", action: #selector(removeSession(_:)),
                                                 target: self, representedObject: info)
                    }
                }

                // Permission prompt indicator
                if let prompt = pendingPermissions[session] {
                    sessionSub.addItem(NSMenuItem.separator())
                    sessionSub.addDisabledItem("\u{26A0} \(prompt)")
                    sessionSub.addActionItem("Allow", action: #selector(allowPermission(_:)),
                                             target: self, representedObject: info)
                    sessionSub.addActionItem("Deny", action: #selector(denyPermission(_:)),
                                             target: self, representedObject: info)
                }

                let title = "Session \(idx)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.attributedTitle = attributedSessionTitle(idx: idx, indicator: indicator,
                                                              hasPending: pendingPermissions[session] != nil)
                item.submenu = sessionSub
                sub.addItem(item)
            }

            // No sessions yet — show Start
            if projectSessions.isEmpty {
                sub.addActionItem("Start", action: #selector(toggleProject(_:)),
                                  target: self, representedObject: project.path)
            } else {
                // Bulk start/stop for project
                let alive = isAlive(project)
                sub.addItem(NSMenuItem.separator())
                if alive {
                    sub.addActionItem("Stop All Sessions", action: #selector(toggleProject(_:)),
                                      target: self, representedObject: project.path)
                }
            }

            sub.addItem(NSMenuItem.separator())
            sub.addActionItem("Add Session", action: #selector(addSession(_:)),
                              target: self, representedObject: project.path)

            // Permission mode submenu
            let permSub = NSMenu()
            let currentMode = project.permissionMode
            let modes: [(String, String?)] = [
                ("Default (ask in terminal)", nil),
                ("Skip Permissions", "dangerously-skip-permissions"),
            ]
            for (label, mode) in modes {
                let item = NSMenuItem(title: label, action: #selector(setPermissionMode(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ["path": project.path, "mode": mode ?? ""] as [String: String]
                item.state = currentMode == mode ? .on : .off
                permSub.addItem(item)
            }
            let permItem = NSMenuItem(title: "Permission Mode", action: nil, keyEquivalent: "")
            permItem.submenu = permSub
            sub.addItem(permItem)
        }

        sub.addItem(NSMenuItem.separator())
        sub.addActionItem("Remove Project", action: #selector(removeProject(_:)),
                          target: self, representedObject: project.path)
        return sub
    }

    private func attributedSessionTitle(idx: String, indicator: StatusIndicator,
                                         hasPending: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: indicator.dot,
            attributes: [.foregroundColor: indicator.dotColor,
                         .font: NSFont.menuFont(ofSize: 0)]
        ))
        let label = "Session \(idx)"
        result.append(NSAttributedString(
            string: label,
            attributes: [.font: indicator == .stopped
                ? NSFont.menuFont(ofSize: 0)
                : NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        ))
        if hasPending {
            result.append(NSAttributedString(
                string: " \u{2014} permission requested",
                attributes: [.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
            ))
        } else if let suffix = indicator.suffix {
            result.append(NSAttributedString(
                string: suffix,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
            ))
        }
        return result
    }

    private func buildBulkActions(in menu: NSMenu) {
        guard projects.count > 1 else { return }
        let runningProjects = projects.filter { isAlive($0) }.count
        let allRunning = runningProjects == projects.count
        let noneRunning = runningProjects == 0
        let suffix = noneRunning ? "(silent)" : "(\(runningProjects)/\(projects.count) running)"
        if allRunning {
            menu.addDisabledItem("Start all \(suffix)")
        } else {
            menu.addActionItem("Start all \(suffix)",
                               action: #selector(startAllProjects), target: self)
        }
        if noneRunning {
            menu.addDisabledItem("Stop All")
        } else {
            menu.addActionItem("Stop All", action: #selector(stopAllProjects), target: self)
        }
        menu.addItem(NSMenuItem.separator())
    }

    // MARK: - Actions

    private func findProject(from sender: NSMenuItem) -> (Int, Project)? {
        guard let path = sender.representedObject as? String,
              let index = projects.firstIndex(where: { $0.path == path }) else { return nil }
        return (index, projects[index])
    }

    private func findProjectByPath(_ path: String) -> (Int, Project)? {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return nil }
        return (index, projects[index])
    }

    private func sessionInfo(from sender: NSMenuItem) -> (session: String, path: String)? {
        guard let info = sender.representedObject as? [String: String],
              let session = info["session"], let path = info["path"] else { return nil }
        return (session, path)
    }

    @objc func toggleProject(_ sender: NSMenuItem) {
        guard !isUpdating else { return }
        isUpdating = true
        guard let (index, project) = findProject(from: sender) else { isUpdating = false; return }

        let wasAlive = isAlive(project)

        var updated = projects
        updated[index].enabled = !wasAlive
        projects = updated

        if wasAlive {
            // Stop all sessions for this project
            let allSessions = sessions(for: project)
            for session in allSessions {
                sessionStatus[session] = .stopped
            }
            refreshUI()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                for session in allSessions {
                    self?.runScript("stop", session: session)
                }
                DispatchQueue.main.async {
                    self?.refreshAllStatusAsync { self?.isUpdating = false }
                }
            }
        } else {
            guard project.folderExists else { isUpdating = false; return }
            let session = nextSessionName(for: project)
            sessionStatus[session] = .running
            refreshUI()
            let dName = displayName(session: session, project: project)
            runScriptAsync("start", session: session, dir: project.path,
                           displayName: dName, permissionMode: project.permissionMode) { [weak self] in
                self?.refreshAllStatusAsync { self?.isUpdating = false }
            }
        }
    }

    @objc func addSession(_ sender: NSMenuItem) {
        guard !isUpdating else { return }
        guard let (_, project) = findProject(from: sender) else { return }
        guard project.folderExists else { return }
        isUpdating = true

        let session = nextSessionName(for: project)
        sessionStatus[session] = .running
        refreshUI()

        let dName = displayName(session: session, project: project)
        runScriptAsync("start", session: session, dir: project.path,
                       displayName: dName, permissionMode: project.permissionMode) { [weak self] in
            guard let self else { return }
            self.openTerminal(for: session)
            self.refreshAllStatusAsync { self.isUpdating = false }
        }
    }

    @objc func attachSession(_ sender: NSMenuItem) {
        guard let (session, _) = sessionInfo(from: sender) else { return }
        openTerminal(for: session)
    }

    private func openTerminal(for session: String) {
        let escaped = session
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("""
        tell application "Terminal"
            activate
            do script "\(Config.tmuxPath) attach-session -t \(escaped)"
        end tell
        """)
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.attachRefreshDelay) { [weak self] in
            self?.refreshAllStatusAsync()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.refreshAllStatusAsync()
        }
    }

    @objc func stopSession(_ sender: NSMenuItem) {
        guard !isUpdating, let (session, _) = sessionInfo(from: sender) else { return }
        isUpdating = true
        sessionStatus[session] = .stopped
        pendingPermissions.removeValue(forKey: session)
        refreshUI()
        runScriptAsync("stop", session: session) { [weak self] in
            self?.refreshAllStatusAsync { self?.isUpdating = false }
        }
    }

    @objc func startSession(_ sender: NSMenuItem) {
        guard !isUpdating, let (session, path) = sessionInfo(from: sender) else { return }
        guard let (_, project) = findProjectByPath(path) else { return }
        isUpdating = true
        sessionStatus[session] = .running
        refreshUI()
        let dName = displayName(session: session, project: project)
        runScriptAsync("start", session: session, dir: path,
                       displayName: dName, permissionMode: project.permissionMode) { [weak self] in
            guard let self else { return }
            self.openTerminal(for: session)
            self.refreshAllStatusAsync { self.isUpdating = false }
        }
    }

    @objc func respawnSession(_ sender: NSMenuItem) {
        guard !isUpdating, let (session, path) = sessionInfo(from: sender) else { return }
        guard let (_, project) = findProjectByPath(path) else { return }
        isUpdating = true
        sessionStatus[session] = .running
        pendingPermissions.removeValue(forKey: session)
        refreshUI()
        let dName = displayName(session: session, project: project)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runScript("stop", session: session)
            self?.runScript("start", session: session, dir: path,
                           displayName: dName, permissionMode: project.permissionMode)
            DispatchQueue.main.async {
                self?.refreshAllStatusAsync { self?.isUpdating = false }
            }
        }
    }

    @objc func removeSession(_ sender: NSMenuItem) {
        guard !isUpdating, let (session, _) = sessionInfo(from: sender) else { return }
        isUpdating = true
        let wasAlive = sessionStatus[session]?.isAlive == true
        sessionStatus.removeValue(forKey: session)
        pendingPermissions.removeValue(forKey: session)
        refreshUI()
        if wasAlive {
            runScriptAsync("stop", session: session) { [weak self] in
                self?.isUpdating = false
            }
        } else {
            isUpdating = false
        }
    }

    @objc func removeProject(_ sender: NSMenuItem) {
        guard !isUpdating else { return }
        isUpdating = true
        guard let (index, project) = findProject(from: sender) else { isUpdating = false; return }

        let allSessions = sessions(for: project)
        let aliveSessions = allSessions.filter { sessionStatus[$0]?.isAlive == true }

        var updated = projects
        updated.remove(at: index)
        projects = updated
        for session in allSessions {
            sessionStatus.removeValue(forKey: session)
            pendingPermissions.removeValue(forKey: session)
        }
        refreshUI()

        if !aliveSessions.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                for session in aliveSessions { self?.runScript("stop", session: session) }
                DispatchQueue.main.async { self?.isUpdating = false }
            }
        } else {
            isUpdating = false
        }
    }

    // MARK: - Permission Actions

    @objc func allowPermission(_ sender: NSMenuItem) {
        guard let (session, _) = sessionInfo(from: sender) else { return }
        pendingPermissions.removeValue(forKey: session)
        refreshUI()
        // Enter confirms the highlighted/default option in Claude Code prompts
        runScriptAsync("send", session: session, dir: "Enter")
    }

    @objc func denyPermission(_ sender: NSMenuItem) {
        guard let (session, _) = sessionInfo(from: sender) else { return }
        pendingPermissions.removeValue(forKey: session)
        refreshUI()
        // Escape cancels/denies in Claude Code prompts
        runScriptAsync("send", session: session, dir: "Escape")
    }

    @objc func setPermissionMode(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let path = info["path"],
              let (index, _) = findProjectByPath(path) else { return }
        let mode = info["mode"]
        var updated = projects
        updated[index].permissionMode = (mode?.isEmpty == true) ? nil : mode
        projects = updated
        refreshUI()
    }

    @objc func appDidTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.Terminal" else { return }
        refreshAllStatusAsync()
    }

    @objc func addFolder() {
        showFolderPicker()
    }

    @objc func installDependencies() {
        depInstaller.checkAndPromptIfNeeded { [weak self] _ in
            self?.depStatus = DependencyStatus.check()
            self?.refreshUI()
        }
    }

    @objc func resetAndInstallDependencies() {
        UserDefaults.standard.removeObject(forKey: Config.depCheckDismissedKey)
        installDependencies()
    }

    @objc func startAllProjects() {
        guard !isUpdating else { return }
        isUpdating = true

        var updated = projects
        var toStart: [(session: String, project: Project)] = []
        for (index, project) in projects.enumerated() {
            if !isAlive(project) && project.folderExists {
                updated[index].enabled = true
                let session = nextSessionName(for: project)
                sessionStatus[session] = .running
                toStart.append((session, project))
            }
        }
        projects = updated
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (session, project) in toStart {
                let dName = self?.displayName(session: session, project: project)
                self?.runScript("start", session: session, dir: project.path,
                               displayName: dName, permissionMode: project.permissionMode)
            }
            DispatchQueue.main.async {
                self?.refreshAllStatusAsync { self?.isUpdating = false }
            }
        }
    }

    @objc func stopAllProjects() {
        guard !isUpdating else { return }
        isUpdating = true

        var updated = projects
        let allAlive = sessionStatus.filter { $0.value.isAlive }.map(\.key)
        for (index, _) in projects.enumerated() {
            updated[index].enabled = false
        }
        for session in allAlive {
            sessionStatus[session] = .stopped
        }
        pendingPermissions.removeAll()
        projects = updated
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for session in allAlive { self?.runScript("stop", session: session) }
            DispatchQueue.main.async {
                self?.refreshAllStatusAsync { self?.isUpdating = false }
            }
        }
    }

    @objc func showInstructions() {
        if let existing = instructionsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let text = loadInstructionsText()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Config.instructionsWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Getting Started"
        window.center()
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = Config.instructionsTextInset
        textView.font = .systemFont(ofSize: 13)
        textView.string = text

        scroll.documentView = textView
        window.contentView = scroll
        instructionsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates() {
        updateChecker.check(silent: false)
    }

    @objc func quitApp() {
        pollTimer?.invalidate()
        pollTimer = nil
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Folder Picker

    func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add a project folder for Redeye"
        panel.message = "Select a folder where Claude Code should run."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK else { return }

        var updated = projects
        for url in panel.urls {
            let resolved = url.resolvingSymlinksInPath().path
            if !updated.contains(where: { $0.path == resolved }) {
                updated.append(Project(path: resolved, enabled: true))
            }
        }
        projects = updated

        var toStart: [(session: String, project: Project)] = []
        for project in projects where project.enabled && !isAlive(project) && project.folderExists {
            let session = nextSessionName(for: project)
            sessionStatus[session] = .running
            toStart.append((session, project))
        }
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (session, project) in toStart {
                let dName = self?.displayName(session: session, project: project)
                self?.runScript("start", session: session, dir: project.path,
                               displayName: dName, permissionMode: project.permissionMode)
            }
            DispatchQueue.main.async { self?.refreshAllStatusAsync() }
        }
    }

    // MARK: - Helpers

    private func displayName(session: String, project: Project) -> String {
        let safe = project.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let idx = sessionIndex(from: session)
        return "redeye-\(safe)-\(idx)"
    }

    // MARK: - Script Interface

    private func runScript(_ action: String, session: String, dir: String? = nil,
                            displayName: String? = nil, permissionMode: String? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [Config.scriptPath, action, session]
        if let dir = dir { args.append(dir) }
        if let displayName = displayName { args.append(displayName) }
        if let mode = permissionMode { args.append(mode) }
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }

    private func runScriptAsync(_ action: String, session: String, dir: String? = nil,
                                displayName: String? = nil, permissionMode: String? = nil,
                                completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runScript(action, session: session, dir: dir, displayName: displayName,
                           permissionMode: permissionMode)
            DispatchQueue.main.async { completion?() }
        }
    }

    private func runScriptOutput(_ action: String, session: String, dir: String? = nil) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [Config.scriptPath, action, session]
        if let dir = dir { args.append(dir) }
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Session Discovery

    private func discoverSessions() -> [String: SessionState] {
        let output = runScriptOutput("list", session: "redeye-")
        guard !output.isEmpty else { return [:] }
        var result: [String: SessionState] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let attached = Int(parts[1]) ?? 0
            result[name] = attached > 0 ? .attached : .running
        }
        return result
    }

    private func refreshAllStatus() {
        sessionStatus = discoverSessions()
        refreshUI()
    }

    private func refreshAllStatusAsync(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discovered = self?.discoverSessions() ?? [:]
            DispatchQueue.main.async {
                self?.sessionStatus = discovered
                self?.refreshUI()
                completion?()
            }
        }
    }

    // MARK: - Migration

    private func migrateLegacySessions() {
        for project in projects {
            let legacy = project.sessionPrefix
            let output = runScriptOutput("status", session: legacy)
            if output == "running" || output == "attached" {
                let newName = legacy + "-01"
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-c", "\(Config.tmuxPath) rename-session -t \"\(legacy)\" \"\(newName)\" 2>/dev/null"]
                try? task.run()
                task.waitUntilExit()
            }
        }
    }

    // Apply mouse-scroll + larger history settings to every active session.
    // Idempotent — safe to call on already-tuned sessions.
    private func tuneAllSessions() {
        for session in sessionStatus.keys {
            runScript("tune", session: session)
        }
    }

    // MARK: - Permission Prompt Detection

    private func checkPermissionPrompts() {
        let aliveSessions = sessionStatus.filter { $0.value.isAlive }.map(\.key)
        guard !aliveSessions.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var changed = false
            for session in aliveSessions {
                let output = self.runScriptOutput("capture", session: session)

                // Auto-responses: send predefined keys and skip prompt UI
                if let auto = Config.autoResponses.first(where: { output.contains($0.pattern) }) {
                    if self.recentAutoResponses[session] != auto.pattern {
                        DispatchQueue.main.async {
                            self.recentAutoResponses[session] = auto.pattern
                        }
                        for key in auto.keys {
                            self.runScript("send", session: session, dir: key)
                        }
                    }
                    continue
                } else {
                    DispatchQueue.main.async {
                        self.recentAutoResponses.removeValue(forKey: session)
                    }
                }

                let hasPrompt = Config.permissionPromptPatterns.contains { output.contains($0) }
                DispatchQueue.main.async {
                    let wasPending = self.pendingPermissions[session] != nil
                    if hasPrompt && !wasPending {
                        let lines = output.split(separator: "\n")
                        let promptLine = lines.last(where: { line in
                            Config.permissionPromptPatterns.contains { line.contains($0) }
                        }).map(String.init) ?? "Permission requested"
                        self.pendingPermissions[session] = promptLine
                        self.sendPermissionNotification(session: session, prompt: promptLine)
                        changed = true
                    } else if !hasPrompt && wasPending {
                        self.pendingPermissions.removeValue(forKey: session)
                        changed = true
                    }
                }
            }
            DispatchQueue.main.async {
                if changed { self.refreshUI() }
            }
        }
    }

    private func sendPermissionNotification(session: String, prompt: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Redeye \u{2014} Permission Requested"
        content.body = "\(session): \(prompt)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "redeye-perm-\(session)",
                                            content: content, trigger: nil)
        center.add(request)
    }

    private func startEnabledProjects() {
        var toStart: [(session: String, project: Project)] = []
        for project in projects where project.enabled && !isAlive(project) && project.folderExists {
            let session = nextSessionName(for: project)
            sessionStatus[session] = .running
            toStart.append((session, project))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (session, project) in toStart {
                let dName = self?.displayName(session: session, project: project)
                self?.runScript("start", session: session, dir: project.path,
                               displayName: dName, permissionMode: project.permissionMode)
            }
            DispatchQueue.main.async { self?.refreshAllStatusAsync() }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshAllStatusAsync()
            let newDepStatus = DependencyStatus.check()
            if self?.depStatus?.allPresent != newDepStatus.allPresent {
                self?.depStatus = newDepStatus
                self?.refreshUI()
            }
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: Config.permissionPollInterval,
                                                    repeats: true) { [weak self] _ in
            self?.checkPermissionPrompts()
        }
    }

    // MARK: - Utilities

    private func runAppleScript(_ source: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = source.components(separatedBy: "\n").flatMap { ["-e", $0] }
        try? task.run()
    }

    private func loadInstructionsText() -> String {
        if let text = try? String(contentsOfFile: Config.instructionsPath, encoding: .utf8) {
            return text
        }
        return "Getting Started file not found."
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.setup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
