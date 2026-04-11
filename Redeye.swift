import AppKit

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var isRunning = false
    private let scriptPath = "/Users/hrosenblume/.local/bin/claude-ordo-keepalive.sh"
    private var pollTimer: Timer?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatus()
        updateIcon()
        buildMenu()
        startPolling()
        // Auto-start the keepalive on launch
        if !isRunning {
            runScript("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refreshStatus()
            }
        }
    }

    private func updateIcon() {
        if let button = statusItem.button {
            let symbolName = isRunning ? "cup.and.saucer.fill" : "cup.and.saucer"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Redeye") {
                image.isTemplate = true
                button.image = image
                button.title = ""
            } else {
                // Fallback if SF Symbol unavailable
                button.title = isRunning ? "\u{2615}" : "\u{2B58}"
                button.image = nil
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: isRunning ? "Stop Redeye" : "Start Redeye",
            action: #selector(toggleKeepalive),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let statusLine = NSMenuItem(
            title: isRunning ? "Status: Running" : "Status: Stopped",
            action: nil,
            keyEquivalent: ""
        )
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem.separator())

        let attachItem = NSMenuItem(
            title: "Attach to Session",
            action: #selector(attachToSession),
            keyEquivalent: ""
        )
        attachItem.target = self
        attachItem.isEnabled = isRunning
        menu.addItem(attachItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Redeye",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleKeepalive() {
        let command = isRunning ? "stop" : "start"
        runScript(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc func attachToSession() {
        let script = "tell application \"Terminal\" to do script \"screen -r claude-ordo\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func runScript(_ argument: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath, argument]
        try? task.run()
        task.waitUntilExit()
    }

    private func refreshStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath, "status"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isRunning = (output == "running")
        updateIcon()
        buildMenu()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.setup()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
