#if os(macOS)
import AppKit
import Foundation
import PaveKit

/// App lifecycle plus screen lock state. NSWorkspace notifications for app
/// events, DistributedNotificationCenter for lock state (loginwindow signals
/// these system-wide; there is no NSWorkspace equivalent). No polling.
final class ApplicationObserver {
    private let onChange: (RawChange) -> Void
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init(onChange: @escaping (RawChange) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(wsnc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            self?.onChange(.appLaunched(bundleID: bundleID))
        })
        workspaceTokens.append(wsnc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            self?.onChange(.appActivated(bundleID: bundleID))
        })
        workspaceTokens.append(wsnc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            self?.onChange(.appTerminated(bundleID: bundleID))
        })

        let dnc = DistributedNotificationCenter.default()
        distributedTokens.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.onChange(.screenLocked)
        })
        distributedTokens.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.onChange(.screenUnlocked)
        })
    }

    func stop() {
        let wsnc = NSWorkspace.shared.notificationCenter
        for t in workspaceTokens { wsnc.removeObserver(t) }
        workspaceTokens.removeAll()

        let dnc = DistributedNotificationCenter.default()
        for t in distributedTokens { dnc.removeObserver(t) }
        distributedTokens.removeAll()
    }

    private static func bundleID(from note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }
}
#endif
