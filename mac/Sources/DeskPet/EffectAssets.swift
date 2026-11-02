import AppKit
import SwiftUI

/// Optional illustrated art for the attack effects. Missing assets fall back to the drawn versions.
enum EffectAsset: String, CaseIterable, Identifiable {
    case cloud, throwerIdle, throwerToss, throwerThrow, can, hand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return L("乌云", "Storm cloud")
        case .throwerIdle: return L("小人 · 待机", "Thrower · idle")
        case .throwerToss: return L("小人 · 抛起", "Thrower · toss")
        case .throwerThrow: return L("小人 · 投掷", "Thrower · throw")
        case .can: return L("易拉罐", "Soda can")
        case .hand: return L("巴掌", "Slapping hand")
        }
    }

    /// Output size requested from OpenAI-style APIs.
    var size: String {
        switch self {
        case .cloud: return "1536x1024"
        case .throwerIdle, .throwerToss, .throwerThrow: return "1024x1536"
        case .can, .hand: return "1024x1024"
        }
    }

    /// Poses drawn from the idle thrower as a reference, so all three are the same character.
    var reference: EffectAsset? {
        switch self {
        case .throwerToss, .throwerThrow: return .throwerIdle
        default: return nil
        }
    }

    var promptKey: String { "fxPrompt.\(rawValue)" }

    var defaultSubject: String {
        switch self {
        case .cloud:
            return "A menacing dark storm cloud, volumetric and fluffy, deep charcoal and indigo tones, lit from within by a purple-blue lightning glow, a few small electric sparks under it. Wide horizontal shape, about 2:1."
        case .throwerIdle:
            return "A small mischievous chibi kid, full body, standing, red cap, blue hoodie, cheeky grin, one hand open and ready to catch, facing left."
        case .throwerToss:
            return "Same kid, pose: right arm raised straight up with the palm open, having just tossed something upward, looking up."
        case .throwerThrow:
            return "Same kid, pose: dynamic overhand throw, throwing arm extended forward toward the left, leaning forward."
        case .can:
            return "A red aluminum soda can, slightly dented, standing upright, crisp metallic highlights, no logo or text."
        case .hand:
            return "A cartoon open hand mid-slap, seen from the side, palm facing right, fingers together, wrist at the left edge."
        }
    }

    static let defaultStyle = """
    Japanese anime illustration style like a polished key visual: crisp fine ink linework, cel shading with soft painterly \
    highlights, subtle pencil cross-hatching texture, rich blacks, vivid red and electric blue accents, red and blue rim \
    lighting. A single isolated subject, centered, fully visible, transparent background, no text, no frame.
    """

    static let styleKey = "fxStyle"

    static var style: String {
        let saved = UserDefaults.standard.string(forKey: styleKey) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultStyle : saved
    }

    var subject: String {
        let saved = UserDefaults.standard.string(forKey: promptKey) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSubject : saved
    }

    /// The full prompt sent to the model (also what "复制提示词" copies).
    var prompt: String {
        let preamble = reference == nil ? "" :
            "Use the attached image as the character reference. Draw exactly the same character, outfit, colors and art style, full body, at the same scale. "
        return preamble + subject + " " + Self.style
    }
}

private struct EffectAssetsKey: EnvironmentKey {
    static let defaultValue: [EffectAsset: NSImage] = [:]
}

extension EnvironmentValues {
    /// Illustrated effect art available to the attack views.
    var effectAssets: [EffectAsset: NSImage] {
        get { self[EffectAssetsKey.self] }
        set { self[EffectAssetsKey.self] = newValue }
    }
}

/// Palette taken from the Cindy look: rich black, vivid red, electric blue, warm white.
enum Cindy {
    static let red = Color(red: 0.91, green: 0.13, blue: 0.16)
    static let redHot = Color(red: 1, green: 0.32, blue: 0.3)
    static let blue = Color(red: 0.18, green: 0.42, blue: 1)
    static let blueHot = Color(red: 0.45, green: 0.7, blue: 1)
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let paper = Color(red: 0.98, green: 0.96, blue: 0.93)
    static let gold = Color(red: 0.93, green: 0.72, blue: 0.25)

    /// Blue-to-red rim light used on outlines.
    static let rim = LinearGradient(colors: [blueHot, blue, red, redHot], startPoint: .leading, endPoint: .trailing)
}
