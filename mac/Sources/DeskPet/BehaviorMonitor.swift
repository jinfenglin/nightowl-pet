import AppKit
import CoreGraphics

/// Polls user activity once a minute and turns bad habits into damage.
///
/// Rules:
///  - Late night: any input during the curfew window costs HP every minute.
///  - Long sitting: continuous use beyond the limit costs HP until a real break is taken.
///  - Good night: if a whole curfew window passes without a violation, heal at its end.
@MainActor
final class BehaviorMonitor {
    private let store: PetStore
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var streakStart: Date?
    private var lastTick = Date()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(store: PetStore) {
        self.store = store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    /// Seconds since the last keyboard/mouse/trackpad event. Needs no special permission.
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func tick(now: Date = Date()) {
        let idle = Self.idleSeconds()
        let active = idle < defaults.double(forKey: Pref.idleThreshold)
        let gap = now.timeIntervalSince(lastTick)  // large after system sleep
        lastTick = now

        HPHistory.shared.record(store.hp, at: now)  // so a day without HP changes still gets a sample
        let curfew = Curfew.current
        settleNights(curfew, now: now)

        if curfew.contains(now) {
            streakStart = nil
            if active {
                store.damage(defaults.integer(forKey: Pref.lateNightDamage),
                             reason: L("已经 \(Self.clock.string(from: now)) 了还在用电脑！快去睡觉！",
                                        "It's \(Self.clock.string(from: now)) and you're still on the computer! Go to bed!"))
                defaults.set(true, forKey: Pref.violatedTonight)
            }
            return
        }

        guard defaults.bool(forKey: Pref.sittingEnabled) else {
            streakStart = nil
            return
        }
        let breakMinutes = defaults.integer(forKey: Pref.breakMinutes)
        let breakSeconds = Double(breakMinutes * 60)
        if idle >= breakSeconds || gap >= breakSeconds { streakStart = nil }
        guard active else { return }

        let start = streakStart ?? now
        streakStart = start
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes >= defaults.integer(forKey: Pref.sittingLimit) {
            store.damage(defaults.integer(forKey: Pref.sittingDamage),
                         reason: L("已经连续用电脑 \(minutes) 分钟了，起来活动 \(breakMinutes) 分钟吧！",
                                    "\(minutes) minutes straight at the computer. Get up and move for \(breakMinutes) minutes!"))
        }
    }

    /// Reward each curfew window that ended without a violation. Robust to the
    /// app being closed or the Mac sleeping through the night.
    private func settleNights(_ curfew: Curfew, now: Date) {
        guard let end = curfew.mostRecentEnd(before: now) else { return }
        let last = defaults.object(forKey: Pref.lastSettledCurfewEnd) as? Date
        guard last == nil || end > last! else { return }
        defaults.set(end, forKey: Pref.lastSettledCurfewEnd)
        guard last != nil else { return }  // first launch: nothing to judge yet

        if !defaults.bool(forKey: Pref.violatedTonight) {
            store.heal(defaults.integer(forKey: Pref.goodNightHeal), reason: L("昨晚按时休息，HP 恢复！☀️", "You slept on time last night. HP restored! ☀️"))
        }
        defaults.set(false, forKey: Pref.violatedTonight)
    }
}
