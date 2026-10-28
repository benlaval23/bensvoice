import Foundation

enum Mode: String { case dictate, compose }

/// How the keyboard and the app talk: Darwin notifications as signals, App Group defaults for the data.
/// Keyboards can't use the mic, so the app holds the mic session and the keyboard drives it.
enum Bridge {
    static let group = "group.com.benlaval.bensvoice"
    static let defaults = UserDefaults(suiteName: group)!

    enum Note: String { case startDictate, startCompose, stop, cancel, endSession, changed }

    // Written by the app
    static let heartbeatKey = "heartbeat"     // Unix time, refreshed every second while the mic session is on
    static let phaseKey = "phase"             // off, ready, recording, working
    static let modeKey = "mode"
    static let startedAtKey = "startedAt"
    static let messageKey = "message"         // last error or hint, shown in the keyboard
    static let resultKey = "result"
    static let resultForKey = "resultFor"     // the request id the result answers
    // Written by the keyboard
    static let requestKey = "request"         // id of the recording the keyboard is waiting on
    static let contextKey = "context"         // text before the cursor
    static let selectedKey = "selected"

    static var sessionAlive: Bool {
        Date().timeIntervalSince1970 - defaults.double(forKey: heartbeatKey) < 3
    }

    static func post(_ note: Note) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name(note) as CFString), nil, nil, true)
    }

    private static var handlers: [String: () -> Void] = [:]

    /// Handlers run on the main queue.
    static func observe(_ note: Note, _ handler: @escaping () -> Void) {
        let key = name(note)
        let isNew = handlers[key] == nil
        handlers[key] = handler
        guard isNew else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let key = name?.rawValue as String? else { return }
            DispatchQueue.main.async { Bridge.handlers[key]?() }
        }, key as CFString, nil, .deliverImmediately)
    }

    private static func name(_ note: Note) -> String { "com.benlaval.bensvoice.\(note.rawValue)" }
}
