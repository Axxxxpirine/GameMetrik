import AppKit

@MainActor final class SecurityMonitor {
    static let idleLimit: TimeInterval = 300
    static let warningLead: TimeInterval = 30
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var eventMonitor: Any?
    private var timer: Timer?
    private(set) var lastActivity = Date()
    private let lock: @MainActor () -> Void
    // Receives the automatic lock deadline shortly before it, then nil after any activity.
    private let warn: @MainActor (Date?) -> Void
    private var warning = false
    /// `idleLocks: false` is for the background synchronization requested by an assistant: it has no window
    /// and no user input, so only sleep and session locking stop it.
    init(lock: @escaping @MainActor () -> Void, warn: @escaping @MainActor (Date?) -> Void = { _ in }, idleLocks: Bool = true) {
        self.lock = lock
        self.warn = warn
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        // macOS also emits this when the screen locks without a session switch or display sleep.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        guard idleLocks else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            self?.activity(); return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }
    func activity(at date: Date = Date()) {
        lastActivity = date
        if warning { warning = false; warn(nil) }
    }
    /// Warns during the last 30 seconds, then locks. A long sync never counts as activity.
    func evaluate(now: Date = Date()) {
        let idle = now.timeIntervalSince(lastActivity)
        if idle >= Self.idleLimit {
            if warning { warning = false; warn(nil) }
            lock()
        } else if idle >= Self.idleLimit - Self.warningLead, !warning {
            warning = true; warn(lastActivity.addingTimeInterval(Self.idleLimit))
        }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        observers.append((center, observer))
    }
}
