import Foundation

struct DailyHP: Codable, Identifiable, Equatable {
    /// Local calendar day, "yyyy-MM-dd".
    let day: String
    /// Lowest HP seen that day (including the HP carried in from the day before).
    var minHP: Int

    var id: String { day }
    var date: Date { HPHistory.dayFormatter.date(from: day) ?? .distantPast }
}

/// Daily minimum HP, persisted to hp_history.json in the app's data folder.
@MainActor
final class HPHistory: ObservableObject {
    static let shared = HPHistory()

    @Published private(set) var days: [DailyHP]
    private let persists: Bool

    static let keepDays = 400

    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var fileURL: URL { PetStore.supportDir.appendingPathComponent("hp_history.json") }

    private init() {
        persists = true
        let data = try? Data(contentsOf: Self.fileURL)
        days = data.flatMap { try? JSONDecoder().decode([DailyHP].self, from: $0) } ?? []
    }

    /// In-memory history (no file), for previews.
    init(preview days: [DailyHP]) {
        persists = false
        self.days = days
    }

    /// Fold an HP sample into today's minimum; only touches the file when something changed.
    func record(_ hp: Int, at date: Date = Date()) {
        let key = Self.dayFormatter.string(from: date)
        if let i = days.firstIndex(where: { $0.day == key }) {
            guard hp < days[i].minHP else { return }
            days[i].minHP = hp
        } else {
            days.append(DailyHP(day: key, minHP: hp))
            days.sort { $0.day < $1.day }
            if days.count > Self.keepDays { days.removeFirst(days.count - Self.keepDays) }
        }
        save()
    }

    /// Records within the last `count` days, ending today.
    func recent(_ count: Int, until now: Date = Date()) -> [DailyHP] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(count - 1), to: cal.startOfDay(for: now))!
        return days.filter { $0.date >= start && $0.date <= now }
    }

    private func save() {
        guard persists else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(days) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
