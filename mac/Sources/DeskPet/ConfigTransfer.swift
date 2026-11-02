import AppKit
import UniformTypeIdentifiers

enum ConfigError: LocalizedError {
    case notConfig
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notConfig: return L("这不是 DeskPet 配置文件", "This isn't a DeskPet config file")
        case .newerVersion(let v): return L("配置文件版本 \(v) 比当前 App 新，请先更新 DeskPet", "Config version \(v) is newer than this app. Please update DeskPet first")
        }
    }
}

/// One JSON file holding the settings, prompts and all pose images (base64 PNG).
@MainActor
enum ConfigTransfer {
    static let format = "deskpet-config"
    static let version = 1

    static func export(store: PetStore, includeSecrets: Bool) throws -> Data {
        let d = UserDefaults.standard
        var settings: [String: Any] = [:]
        for key in Pref.exportable {
            settings[key] = d.object(forKey: key)
        }
        for pose in PetPose.allCases {
            settings[Pref.promptKey(for: pose)] = Pref.prompt(for: pose)
        }
        settings[EffectAsset.styleKey] = EffectAsset.style
        for asset in EffectAsset.allCases {
            settings[asset.promptKey] = asset.subject
        }
        if includeSecrets {
            for key in Pref.secrets {
                if let value = d.string(forKey: key), !value.isEmpty { settings[key] = value }
            }
        }
        var images: [String: String] = [:]
        for (pose, image) in store.images {
            images[pose.rawValue] = image.pngData?.base64EncodedString()
        }
        var effects: [String: String] = [:]
        for (asset, image) in store.effects {
            effects[asset.rawValue] = image.pngData?.base64EncodedString()
        }
        let root: [String: Any] = [
            "format": format,
            "version": version,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
            "images": images,
            "effects": effects,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Replaces settings and the whole pose set. API keys are only overwritten when the file has them.
    @discardableResult
    static func apply(_ data: Data, to store: PetStore) throws -> (settings: Int, images: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ConfigError.notConfig }
        let fileVersion = root["version"] as? Int ?? 0
        guard fileVersion <= version else { throw ConfigError.newerVersion(fileVersion) }

        let d = UserDefaults.standard
        let allowed = Set(Pref.exportable + Pref.secrets)
        var settingCount = 0
        for (key, value) in root["settings"] as? [String: Any] ?? [:]
        where allowed.contains(key) && (value is String || value is NSNumber) {
            d.set(value, forKey: key)
            settingCount += 1
        }

        let images = root["images"] as? [String: String] ?? [:]
        var imageCount = 0
        for pose in PetPose.allCases {
            if let b64 = images[pose.rawValue], let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
                store.setImage(image, for: pose)
                imageCount += 1
            } else {
                store.removeImage(for: pose)
            }
        }
        let effects = root["effects"] as? [String: String] ?? [:]
        for asset in EffectAsset.allCases {
            if let b64 = effects[asset.rawValue], let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
                store.setEffect(image, for: asset)
                imageCount += 1
            } else {
                store.removeEffect(asset)
            }
        }
        return (settingCount, imageCount)
    }

    // MARK: - UI

    private static var jsonType: UTType { .json }

    static func runExport(store: PetStore) {
        let save = NSSavePanel()
        save.allowedContentTypes = [jsonType]
        save.nameFieldStringValue = L("DeskPet 配置.json", "DeskPet Config.json")
        save.message = L("导出形象、状态图、规则和提示词", "Export character, poses, rules and prompts")
        let secrets = NSButton(checkboxWithTitle: L("包含 API Key（分享给别人时不要勾选）", "Include API keys (leave off when sharing)"), target: nil, action: nil)
        secrets.state = .off
        save.accessoryView = wrap(secrets)
        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try export(store: store, includeSecrets: secrets.state == .on).write(to: url, options: .atomic)
            store.say(L("配置已导出 📦", "Config exported 📦"), seconds: 4)
        } catch {
            alert(L("导出失败", "Export failed"), error.localizedDescription)
        }
    }

    static func runImport(store: PetStore) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [jsonType]
        open.message = L("选择 DeskPet 配置文件", "Choose a DeskPet config file")
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }

        let confirm = NSAlert()
        confirm.messageText = L("导入这套配置？", "Import this config?")
        confirm.informativeText = L("会替换当前的形象、全部状态图、规则和提示词。文件里没有 API Key 时会保留现在的 Key。", "This replaces the current character, all poses, rules and prompts. If the file has no API keys, your current keys are kept.")
        confirm.addButton(withTitle: L("导入", "Import"))
        confirm.addButton(withTitle: L("取消", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            let result = try apply(try Data(contentsOf: url), to: store)
            store.say(L("配置已导入：\(result.settings) 项设置、\(result.images) 张图片 ✅", "Config imported: \(result.settings) settings, \(result.images) images ✅"), seconds: 5)
        } catch {
            alert(L("导入失败", "Import failed"), error.localizedDescription)
        }
    }

    private static func wrap(_ view: NSControl) -> NSView {
        view.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.frame.width + 40, height: view.frame.height + 16))
        view.setFrameOrigin(NSPoint(x: 20, y: 8))
        container.addSubview(view)
        return container
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }
}
