import AppKit

struct HitEvent: Equatable {
    let id = UUID()
    let amount: Int
    var style: AttackStyle = .lightning
    var index = 0
}

/// Character art per state. Missing poses fall back to effects on the normal image.
enum PetPose: String, CaseIterable, Identifiable {
    case normal, low, hurt, dead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return L("满血", "Full HP")
        case .low: return L("残血", "Low HP")
        case .hurt: return L("受击", "Hit")
        case .dead: return L("阵亡", "Knocked out")
        }
    }

    /// Poses derived from the normal image.
    static let variants: [PetPose] = [.low, .hurt, .dead]
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let delta: Int
    let reason: String
}

@MainActor
final class PetStore: ObservableObject {
    static let shared = PetStore()

    let maxHP = 100
    @Published private(set) var hp: Int {
        didSet {
            UserDefaults.standard.set(hp, forKey: "hp")
            HPHistory.shared.record(hp)
        }
    }
    /// The art currently selected in the asset library, loaded.
    @Published private(set) var images: [PetPose: NSImage] = [:]
    @Published private(set) var effects: [EffectAsset: NSImage] = [:]
    let library = AssetLibrary.shared
    @Published private(set) var lastHit: HitEvent?
    @Published private(set) var lastHeal: HitEvent?
    @Published private(set) var speech: String?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var activeAttack: AttackStyle?
    /// A lingering threat shown after punishment (storm cloud, can thrower, ...).
    @Published private(set) var menace: AttackStyle?
    @Published var isBusy = false

    private var speechTask: Task<Void, Never>?
    private var attackQueue: Task<Void, Never>?
    private var menaceTask: Task<Void, Never>?

    /// The monitor punishes once a minute, so the threat outlives a couple of ticks
    /// and only leaves once the user has actually stopped.
    static let menaceDuration: Double = 180

    private init() {
        let d = UserDefaults.standard
        hp = d.object(forKey: "hp") as? Int ?? 100
        reloadImages()
        HPHistory.shared.record(hp)
        if let data = d.data(forKey: "log"),
           let saved = try? JSONDecoder().decode([LogEntry].self, from: data) {
            log = saved
        }
    }

    var isDead: Bool { hp <= 0 }
    var isLow: Bool { hp < 30 }
    var petImage: NSImage? { images[.normal] }

    nonisolated static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Plays an attack combo; HP drops hit by hit. Attacks queue up instead of overlapping.
    /// `preview` plays the animation without costing HP.
    func damage(_ amount: Int, reason: String, preview: Bool = false) {
        guard amount > 0, !isDead else { return }
        let style = AttackStyle.current.resolved()
        threaten(style, for: preview ? 12 : Self.menaceDuration)
        let previous = attackQueue
        attackQueue = Task { [weak self] in
            await previous?.value
            await self?.runAttack(amount, reason: reason, style: style, preview: preview)
        }
    }

    private func runAttack(_ amount: Int, reason: String, style: AttackStyle, preview: Bool) async {
        guard !isDead else { return }
        say(reason, seconds: 6)
        activeAttack = style
        try? await Task.sleep(for: .seconds(style.windup))

        let hits = min(style.hits, amount)
        var dealt = 0
        for i in 0..<hits {
            let part = amount / hits + (i < amount % hits ? 1 : 0)
            let real = preview ? part : min(part, hp)
            guard real > 0 else { break }
            lastHit = HitEvent(amount: real, style: style, index: i)
            try? await Task.sleep(for: .seconds(style.impactDelay))
            if !preview { hp -= real }
            dealt += real
            try? await Task.sleep(for: .seconds(style.interval - style.impactDelay))
        }
        try? await Task.sleep(for: .seconds(0.3))
        activeAttack = nil

        guard !preview else { return }
        record(-dealt, reason)
        if isDead { say(L("我被你熬倒了… 😵 按时睡一觉我才能复活", "You wore me out… 😵 Get a proper night's sleep to revive me"), seconds: 8) }
    }

    func heal(_ amount: Int, reason: String) {
        guard amount > 0, hp < maxHP else { return }
        let real = min(amount, maxHP - hp)
        hp += real
        threaten(nil, for: 0)
        lastHeal = HitEvent(amount: real)
        record(real, reason)
        say(reason, seconds: 6)
    }

    private func threaten(_ style: AttackStyle?, for seconds: Double) {
        menaceTask?.cancel()
        menace = style
        guard style != nil else { return }
        menaceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.menace = nil
        }
    }

    // MARK: - Art (backed by the asset library)

    /// Save a new image into the pose's library folder and use it.
    func setImage(_ image: NSImage, for pose: PetPose = .normal) {
        add(image, to: .pose(pose))
    }

    /// Stop using any image for the pose (files stay in the library).
    func removeImage(for pose: PetPose) {
        select(nil, for: .pose(pose))
    }

    func setEffect(_ image: NSImage, for asset: EffectAsset) {
        add(image, to: .effect(asset))
    }

    func removeEffect(_ asset: EffectAsset) {
        select(nil, for: .effect(asset))
    }

    func select(_ url: URL?, for slot: AssetSlot) {
        library.select(url, for: slot)
        reloadImages()
    }

    private func add(_ image: NSImage, to slot: AssetSlot) {
        if let url = library.add(image, for: slot) { library.select(url, for: slot) }
        reloadImages()
    }

    /// Load whatever the library has selected (also call after files change in Finder).
    func reloadImages() {
        var poses: [PetPose: NSImage] = [:]
        for pose in PetPose.allCases {
            poses[pose] = library.selectedURL(.pose(pose)).flatMap { NSImage(contentsOf: $0) }
        }
        var fx: [EffectAsset: NSImage] = [:]
        for asset in EffectAsset.allCases {
            fx[asset] = library.selectedURL(.effect(asset)).flatMap { NSImage(contentsOf: $0) }
        }
        images = poses
        effects = fx
    }

    func say(_ text: String?, seconds: Double = 5) {
        speechTask?.cancel()
        speech = text
        guard text != nil else { return }
        speechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.speech = nil
        }
    }

    static var testAttackReason: String { L("测试攻击！这就是熬夜的下场 😈", "Test attack! This is what staying up late gets you 😈") }
    static var fullHealReason: String { L("满血复活！这次要好好表现哦", "Fully revived! Behave this time") }

    func poke() {
        let en = AppLanguage.isEnglish
        let lines: [String]
        if isDead {
            lines = en ? ["…(out cold)", "Let me sleep 💤"] : ["……（昏迷中）", "让我睡会儿 💤"]
        } else if hp < 30 {
            lines = en ? ["I can't hold on much longer. Bed early tonight?", "HP so low… 😣", "Please, no more late nights"]
                : ["我快撑不住了，今晚早点睡好吗？", "HP 好低… 😣", "别再熬夜了求你了"]
        } else {
            lines = en ? ["Stay disciplined today!", "I'm watching you 👀", "Drink water, get up and stretch~", "Past midnight means bedtime"]
                : ["今天也要自律哦！", "我在盯着你 👀", "记得喝水、起来走走～", "过了 12 点就该睡觉啦"]
        }
        say(lines.randomElement(), seconds: 3)
    }

    private func record(_ delta: Int, _ reason: String) {
        log.insert(LogEntry(date: Date(), delta: delta, reason: reason), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
        if let data = try? JSONEncoder().encode(log) {
            UserDefaults.standard.set(data, forKey: "log")
        }
    }
}

extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    var pngData: Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
