import Foundation

/// UserDefaults keys + defaults. Times are minutes since midnight.
enum Pref {
    static let curfewStart = "curfewStart"
    static let curfewEnd = "curfewEnd"
    static let lateNightDamage = "lateNightDamage"
    static let idleThreshold = "idleThreshold"
    static let sittingEnabled = "sittingEnabled"
    static let sittingLimit = "sittingLimit"
    static let sittingDamage = "sittingDamage"
    static let breakMinutes = "breakMinutes"
    static let goodNightHeal = "goodNightHeal"
    static let attackStyle = "attackStyle"
    static let language = "language"

    static let provider = "provider"
    static let apiKey = "apiKey"
    static let apiBase = "apiBase"
    static let imageModel = "imageModel"
    static let geminiKey = "geminiKey"
    static let geminiModel = "geminiModel"
    static let proxy = "proxy"
    static let stylePrompt = "stylePrompt"

    /// Settings carried by an exported config (API keys are opt-in; machine-specific
    /// things like the proxy, and runtime state like HP, are left out).
    static var exportable: [String] {
        [curfewStart, curfewEnd, lateNightDamage, idleThreshold, sittingEnabled, sittingLimit, sittingDamage,
         breakMinutes, goodNightHeal, attackStyle, provider, apiBase, imageModel, geminiModel]
            + PetPose.allCases.map(promptKey)
            + [EffectAsset.styleKey] + EffectAsset.allCases.map(\.promptKey)
    }

    static let secrets = [apiKey, geminiKey]

    // internal bookkeeping
    static let violatedTonight = "violatedTonight"
    static let lastSettledCurfewEnd = "lastSettledCurfewEnd"

    static let defaultPrompt = """
    Turn the main subject of this photo into a cute chibi cartoon character for a desktop pet: \
    full body, big head, bold clean outlines, flat vibrant colors, soft cel shading, friendly expression, \
    centered, keep the recognizable features of the original, no text.
    """

    private static let referencePreamble = """
    Use the attached image as the character reference. Draw exactly the same character: same art style, \
    colors, outfit and proportions, centered and at the same scale.
    """

    static func promptKey(for pose: PetPose) -> String {
        pose == .normal ? stylePrompt : "posePrompt.\(pose.rawValue)"
    }

    static func defaultPrompt(for pose: PetPose) -> String {
        switch pose {
        case .normal:
            return defaultPrompt
        case .low:
            return referencePreamble + " Now at LOW HEALTH: exhausted and worn out, sweating, droopy half-closed eyes, " +
                "slouching, a couple of band-aids, tired wobbly stance. No text."
        case .hurt:
            return referencePreamble + " Now GETTING HIT: flinching in pain, eyes squeezed shut, mouth open yelling \"ouch\", " +
                "body recoiling, cartoon impact stars around the head. No text."
        case .dead:
            return referencePreamble + " Now KNOCKED OUT with zero health: lying flat on its back, eyes drawn as X marks, " +
                "tongue sticking out, a small cute ghost floating up from the body. Comedic, not gory. No text."
        }
    }

    static func prompt(for pose: PetPose) -> String {
        let saved = UserDefaults.standard.string(forKey: promptKey(for: pose)) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt(for: pose) : saved
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            curfewStart: 0,          // 00:00
            curfewEnd: 6 * 60,       // 06:00
            lateNightDamage: 2,      // HP per active minute after curfew
            idleThreshold: 120.0,    // seconds without input => considered away
            sittingEnabled: true,
            sittingLimit: 90,        // minutes of continuous use
            sittingDamage: 1,        // HP per minute beyond the limit
            breakMinutes: 5,         // away this long resets the streak
            goodNightHeal: 30,       // HP restored after a clean night
            attackStyle: AttackStyle.lightning.rawValue,
            provider: ImageProvider.openAI.rawValue,
            apiBase: "https://api.openai.com/v1",
            imageModel: "gpt-image-1",
            geminiModel: "gemini-2.5-flash-image",
        ])
    }
}

enum ImageProvider: String, CaseIterable, Identifiable {
    case openAI, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return L("OpenAI 兼容接口", "OpenAI-compatible")
        case .gemini: return "Google Gemini"
        }
    }

    /// Suggestions for the model field; any other model name can be typed in.
    var modelPresets: [String] {
        switch self {
        case .openAI: return ["gpt-image-1", "gpt-image-1-mini", "dall-e-2"]
        case .gemini: return ["gemini-2.5-flash-image", "gemini-2.0-flash-preview-image-generation"]
        }
    }
}

struct Curfew {
    let start: Int
    let end: Int

    static var current: Curfew {
        let d = UserDefaults.standard
        return Curfew(start: d.integer(forKey: Pref.curfewStart), end: d.integer(forKey: Pref.curfewEnd))
    }

    var enabled: Bool { start != end }

    func contains(_ date: Date) -> Bool {
        guard enabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = c.hour! * 60 + c.minute!
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// The latest curfew end time that is <= now.
    func mostRecentEnd(before now: Date) -> Date? {
        guard enabled else { return nil }
        let cal = Calendar.current
        var e = cal.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: now)!
        if e > now { e = cal.date(byAdding: .day, value: -1, to: e)! }
        return e
    }
}
