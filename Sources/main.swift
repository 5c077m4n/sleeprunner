import AppKit
import CoreGraphics
import Foundation

let appConfigDirName = "sleeprunner"
let appConfigFileName = "config.json"

struct AppConfig: Codable {
    let sleepScript: String
    let wakeScript: String
    let idleScript: String
    let idleThresholdSeconds: TimeInterval
    let idleCheckInterval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sleepScript
        case wakeScript
        case idleScript
        case idleThresholdSeconds
        case idleCheckInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sleepScript = try container.decodeIfPresent(String.self, forKey: .sleepScript) ?? "sleep.sh"
        wakeScript = try container.decodeIfPresent(String.self, forKey: .wakeScript) ?? "wake.sh"
        idleScript = try container.decodeIfPresent(String.self, forKey: .idleScript) ?? "idle.sh"

        idleThresholdSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleThresholdSeconds) ?? 300.0
        idleCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .idleCheckInterval) ?? 60.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sleepScript, forKey: .sleepScript)
        try container.encode(wakeScript, forKey: .wakeScript)
        try container.encode(idleScript, forKey: .idleScript)
        try container.encode(idleThresholdSeconds, forKey: .idleThresholdSeconds)
        try container.encode(idleCheckInterval, forKey: .idleCheckInterval)
    }
}

func getConfigDirectory() -> URL? {
    let fileManager = FileManager.default

    if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
        let xdgURL = URL(fileURLWithPath: xdgConfigHome)
            .appendingPathComponent(appConfigDirName, isDirectory: true)
        return xdgURL
    }

    guard let homeURL = fileManager.urls(for: .userDirectory, in: .userDomainMask).first else {
        return nil
    }

    let fallbackURL = homeURL
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent(appConfigDirName, isDirectory: true)

    return fallbackURL
}

func loadConfig(configDir: URL) -> AppConfig? {
    let configURL = configDir.appendingPathComponent(appConfigFileName)

    do {
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        return config
    } catch {
        return nil
    }
}

func executeShellScript(atPath path: String, event _: String) {
    let fileManager = FileManager.default

    if !fileManager.fileExists(atPath: path) {
        return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [path]

    do {
        try process.run()
        process.waitUntilExit()
    } catch {}
}

class SleepMonitor {
    private let notificationCenter: NotificationCenter
    private let config: AppConfig
    private let configDir: URL

    private var isIdle = false
    private var idleTimer: Timer?

    init(config: AppConfig, configDir: URL) {
        self.config = config
        self.configDir = configDir
        notificationCenter = NSWorkspace.shared.notificationCenter
    }

    func startMonitoring() {
        notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        idleTimer = Timer.scheduledTimer(
            timeInterval: config.idleCheckInterval,
            target: self,
            selector: #selector(handleIdleCheck),
            userInfo: nil,
            repeats: true
        )
    }

    private func getIdleTime() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
    }

    @objc private func handleIdleCheck() {
        let idleTime = getIdleTime()

        if idleTime >= config.idleThresholdSeconds {
            if !isIdle {
                isIdle = true
                let scriptPath = configDir.appendingPathComponent(config.idleScript).path
                executeShellScript(atPath: scriptPath, event: "IDLE_START")
            }
        } else {
            if isIdle {
                isIdle = false
            }
        }
    }

    @objc private func handleSleep() {
        isIdle = false
        let scriptPath = configDir.appendingPathComponent(config.sleepScript).path
        executeShellScript(atPath: scriptPath, event: "SLEEP")
    }

    @objc private func handleWake() {
        let scriptPath = configDir.appendingPathComponent(config.wakeScript).path
        executeShellScript(atPath: scriptPath, event: "WAKE")
    }

    deinit {
        notificationCenter.removeObserver(self)
        idleTimer?.invalidate()
    }
}

guard let configDir = getConfigDirectory() else {
    exit(1)
}

guard let config = loadConfig(configDir: configDir) else {
    exit(1)
}

let monitor = SleepMonitor(config: config, configDir: configDir)
monitor.startMonitoring()

RunLoop.current.run()
