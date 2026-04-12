import AppKit

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
    static let attachRefreshDelay: TimeInterval = 2.0
    static let instructionsWindowSize = NSSize(width: 520, height: 520)
    static let instructionsTextInset = NSSize(width: 16, height: 16)
    static let pathMaxLength = 60
    static let userDefaultsKey = "projects"
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

    var name: String {
        (path as NSString).lastPathComponent
    }

    var sessionName: String {
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
    private var pollTimer: Timer?
    private var isUpdating = false
    private var instructionsWindow: NSWindow?
    private var depStatus: DependencyStatus?
    private let depInstaller = DependencyInstallerController()

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

    // MARK: - State Queries

    private func state(for project: Project) -> SessionState {
        sessionStatus[project.sessionName] ?? .stopped
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

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        depStatus = DependencyStatus.check()
        refreshAllStatus()
        refreshUI()
        startPolling()

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
        menu.addActionItem("Quit Redeye", action: #selector(quitApp), target: self, key: "q")

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
            let alive = isAlive(project)
            if alive {
                sub.addActionItem("Open Session", action: #selector(attachProject(_:)),
                                  target: self, representedObject: project.path)
            }
            sub.addActionItem(alive ? "Stop" : "Start", action: #selector(toggleProject(_:)),
                              target: self, representedObject: project.path)
        }

        sub.addItem(NSMenuItem.separator())
        sub.addActionItem("Remove", action: #selector(removeProject(_:)),
                          target: self, representedObject: project.path)
        return sub
    }

    private func buildBulkActions(in menu: NSMenu) {
        guard projects.count > 1 else { return }
        let runningCount = sessionStatus.values.filter(\.isAlive).count
        menu.addActionItem("Start All (\(runningCount)/\(projects.count) running)",
                           action: #selector(startAllProjects), target: self)
        menu.addActionItem("Stop All", action: #selector(stopAllProjects), target: self)
        menu.addItem(NSMenuItem.separator())
    }

    // MARK: - Actions

    private func findProject(from sender: NSMenuItem) -> (Int, Project)? {
        guard let path = sender.representedObject as? String,
              let index = projects.firstIndex(where: { $0.path == path }) else { return nil }
        return (index, projects[index])
    }

    @objc func toggleProject(_ sender: NSMenuItem) {
        guard !isUpdating else { return }
        isUpdating = true
        guard let (index, project) = findProject(from: sender) else { isUpdating = false; return }

        let wasAlive = isAlive(project)

        var updated = projects
        if wasAlive {
            updated[index].enabled = false
        } else {
            guard project.folderExists else { isUpdating = false; return }
            updated[index].enabled = true
        }
        projects = updated

        sessionStatus[project.sessionName] = wasAlive ? .stopped : .running
        refreshUI()

        let action = wasAlive ? "stop" : "start"
        let name = wasAlive ? nil : displayName(for: project)
        runScriptAsync(action, session: project.sessionName, dir: wasAlive ? nil : project.path,
                       displayName: name) { [weak self] in
            guard let self = self else { return }
            self.checkStatusAsync(session: project.sessionName) { state in
                self.sessionStatus[project.sessionName] = state
                self.refreshUI()
                self.isUpdating = false
            }
        }
    }

    @objc func attachProject(_ sender: NSMenuItem) {
        guard let (_, project) = findProject(from: sender) else { return }
        let escaped = project.sessionName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("tell application \"Terminal\" to do script \"\(Config.tmuxPath) attach-session -t \(escaped)\"")
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.attachRefreshDelay) { [weak self] in
            self?.refreshAllStatusAsync()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.refreshAllStatusAsync()
        }
    }

    @objc func removeProject(_ sender: NSMenuItem) {
        guard !isUpdating else { return }
        isUpdating = true
        guard let (index, project) = findProject(from: sender) else { isUpdating = false; return }

        let needsStop = isAlive(project)
        let session = project.sessionName

        var updated = projects
        updated.remove(at: index)
        projects = updated
        sessionStatus.removeValue(forKey: session)
        refreshUI()

        if needsStop {
            runScriptAsync("stop", session: session) { [weak self] in
                self?.isUpdating = false
            }
        } else {
            isUpdating = false
        }
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

        let (toStart, updated) = bulkUpdateProjects(where: { !isAlive($0) && $0.folderExists },
                                                     setEnabled: true, optimisticState: .running)
        projects = updated
        refreshUI()

        runBulkAsync(toStart, action: "start", includeDir: true) { [weak self] in
            self?.refreshAllStatusAsync { self?.isUpdating = false }
        }
    }

    @objc func stopAllProjects() {
        guard !isUpdating else { return }
        isUpdating = true

        let (toStop, updated) = bulkUpdateProjects(where: { isAlive($0) },
                                                    setEnabled: false, optimisticState: .stopped)
        projects = updated
        refreshUI()

        runBulkAsync(toStop, action: "stop", includeDir: false) { [weak self] in
            self?.refreshAllStatusAsync { self?.isUpdating = false }
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

    @objc func quitApp() {
        pollTimer?.invalidate()
        pollTimer = nil
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

        let toStart = projects.filter { $0.enabled && !isAlive($0) && $0.folderExists }
        for project in toStart {
            sessionStatus[project.sessionName] = .running
        }
        refreshUI()

        runBulkAsync(toStart, action: "start", includeDir: true) { [weak self] in
            self?.refreshAllStatusAsync()
        }
    }

    // MARK: - Bulk Helpers

    private func bulkUpdateProjects(where predicate: (Project) -> Bool,
                                     setEnabled: Bool,
                                     optimisticState: SessionState) -> ([Project], [Project]) {
        var targets: [Project] = []
        var updated = projects
        for (index, project) in projects.enumerated() {
            if predicate(project) {
                targets.append(project)
                updated[index].enabled = setEnabled
                sessionStatus[project.sessionName] = optimisticState
            }
        }
        return (targets, updated)
    }

    private func displayName(for project: Project) -> String {
        let sameName = projects.filter { $0.name == project.name }
        let index = sameName.firstIndex(where: { $0.path == project.path }) ?? 0
        return String(format: "redeye-%@-%02d", project.name.lowercased(), index)
    }

    private func runBulkAsync(_ targets: [Project], action: String, includeDir: Bool,
                              completion: @escaping () -> Void) {
        let names = includeDir ? targets.map { displayName(for: $0) } : []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, project) in targets.enumerated() {
                self?.runScript(action, session: project.sessionName,
                               dir: includeDir ? project.path : nil,
                               displayName: includeDir ? names[i] : nil)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Script Interface

    private func runScript(_ action: String, session: String, dir: String? = nil,
                            displayName: String? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [Config.scriptPath, action, session]
        if let dir = dir { args.append(dir) }
        if let displayName = displayName { args.append(displayName) }
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }

    private func runScriptAsync(_ action: String, session: String, dir: String? = nil,
                                displayName: String? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runScript(action, session: session, dir: dir, displayName: displayName)
            DispatchQueue.main.async { completion?() }
        }
    }

    private func checkStatus(session: String) -> SessionState {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [Config.scriptPath, "status", session]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch output {
        case "running":  return .running
        case "attached": return .attached
        default:         return .stopped
        }
    }

    private func checkStatusAsync(session: String, completion: @escaping (SessionState) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = self?.checkStatus(session: session) ?? .stopped
            DispatchQueue.main.async { completion(state) }
        }
    }

    private func refreshAllStatus() {
        for project in projects {
            sessionStatus[project.sessionName] = checkStatus(session: project.sessionName)
        }
        refreshUI()
    }

    private func refreshAllStatusAsync(completion: (() -> Void)? = nil) {
        let projectList = projects
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var newStatus: [String: SessionState] = [:]
            for project in projectList {
                newStatus[project.sessionName] = self?.checkStatus(session: project.sessionName) ?? .stopped
            }
            DispatchQueue.main.async {
                self?.sessionStatus = newStatus
                self?.refreshUI()
                completion?()
            }
        }
    }

    private func startEnabledProjects() {
        let toStart = projects.filter { $0.enabled && !isAlive($0) && $0.folderExists }
        runBulkAsync(toStart, action: "start", includeDir: true) { [weak self] in
            self?.refreshAllStatusAsync()
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
