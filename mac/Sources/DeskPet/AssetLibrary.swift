import AppKit
import ImageIO

/// Every kind of art the app can use. Each slot has its own folder in the library.
enum AssetSlot: Hashable, Identifiable {
    case pose(PetPose)
    case effect(EffectAsset)

    static var poses: [AssetSlot] { PetPose.allCases.map(AssetSlot.pose) }
    static var effects: [AssetSlot] { EffectAsset.allCases.map(AssetSlot.effect) }
    static var all: [AssetSlot] { poses + effects }

    var id: String { folder }

    var title: String {
        switch self {
        case .pose(let p): return p.title
        case .effect(let e): return e.title
        }
    }

    /// File-name prefix, also the leaf folder name.
    var name: String {
        switch self {
        case .pose(let p): return p.rawValue
        case .effect(let e):
            switch e {
            case .throwerIdle: return "thrower-idle"
            case .throwerToss: return "thrower-toss"
            case .throwerThrow: return "thrower-throw"
            default: return e.rawValue
            }
        }
    }

    /// Folder inside the library, e.g. "pet/hurt" or "fx/thrower-toss".
    var folder: String {
        switch self {
        case .pose: return "pet/\(name)"
        case .effect: return "fx/\(name)"
        }
    }
}

/// The on-disk asset library: generated and imported images, one folder per slot, plus which
/// file is currently in use for each slot. Files dropped into a folder in Finder show up too.
@MainActor
final class AssetLibrary: ObservableObject {
    static let shared = AssetLibrary()

    /// Newest first.
    @Published private(set) var files: [AssetSlot: [URL]] = [:]
    @Published private(set) var selection: [AssetSlot: String] = [:]

    private var thumbnails: [URL: NSImage] = [:]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff"]

    static var root: URL { PetStore.supportDir.appendingPathComponent("Library", isDirectory: true) }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private init() {
        for slot in AssetSlot.all {
            if let name = UserDefaults.standard.string(forKey: Self.selectionKey(slot)) { selection[slot] = name }
        }
        migrateLegacyFiles()
        installDefaults()
        refresh()
    }

    func directory(_ slot: AssetSlot) -> URL {
        let url = Self.root.appendingPathComponent(slot.folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Re-scan every folder (picks up files added or removed in Finder).
    func refresh() {
        for slot in AssetSlot.all {
            files[slot] = scan(slot)
            if let name = selection[slot], !FileManager.default.fileExists(atPath: directory(slot).appendingPathComponent(name).path) {
                select(nil, for: slot)
            }
        }
    }

    func selectedURL(_ slot: AssetSlot) -> URL? {
        guard let name = selection[slot] else { return nil }
        let url = directory(slot).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Compare by file name: the folder is fixed per slot, and paths can differ through symlinks
    /// (/tmp vs /private/tmp) while naming the same file.
    func isSelected(_ url: URL, in slot: AssetSlot) -> Bool {
        selection[slot] == url.lastPathComponent
    }

    func select(_ url: URL?, for slot: AssetSlot) {
        selection[slot] = url?.lastPathComponent
        if let name = url?.lastPathComponent {
            UserDefaults.standard.set(name, forKey: Self.selectionKey(slot))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectionKey(slot))
        }
    }

    /// Save a new image as `<name>_<timestamp>[_tag].png` in the slot's folder.
    @discardableResult
    func add(_ image: NSImage, for slot: AssetSlot, tag: String? = nil) -> URL? {
        guard let png = image.pngData else { return nil }
        let base = "\(slot.name)_\(Self.stamp.string(from: Date()))" + (tag.map { "_\($0)" } ?? "")
        var url = directory(slot).appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory(slot).appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        guard (try? png.write(to: url)) != nil else { return nil }
        files[slot] = scan(slot)
        return url
    }

    /// Copy an outside image into the slot's folder (converted to PNG).
    @discardableResult
    func importFile(_ source: URL, for slot: AssetSlot) -> URL? {
        guard let image = NSImage(contentsOf: source) else { return nil }
        return add(image, for: slot, tag: "import")
    }

    /// Moves the file to the Trash (recoverable).
    func delete(_ url: URL, from slot: AssetSlot) {
        if isSelected(url, in: slot) { select(nil, for: slot) }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        thumbnails[url] = nil
        files[slot] = scan(slot)
    }

    func reveal(_ slot: AssetSlot) {
        NSWorkspace.shared.activateFileViewerSelecting([selectedURL(slot) ?? directory(slot)])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func thumbnail(_ url: URL) -> NSImage? {
        if let cached = thumbnails[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[url] = image
        return image
    }

    private func scan(_ slot: AssetSlot) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory(slot), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { date($0) > date($1) }
    }

    private static func selectionKey(_ slot: AssetSlot) -> String { "asset.selected.\(slot.folder)" }

    /// Built-in art shipped in the app (Contents/Resources/Defaults/<folder>.png). Each one is copied
    /// into its library folder once, as `<name>_default.png`, and used if nothing is chosen for that
    /// slot yet. After that it's an ordinary library file: deselecting or deleting it sticks.
    private func installDefaults() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Defaults", isDirectory: true) else { return }
        let fm = FileManager.default
        for slot in AssetSlot.all {
            let key = "asset.defaultInstalled.\(slot.folder)"
            let source = bundled.appendingPathComponent(slot.folder + ".png")
            guard !UserDefaults.standard.bool(forKey: key), fm.fileExists(atPath: source.path) else { continue }
            let target = directory(slot).appendingPathComponent("\(slot.name)_default.png")
            guard fm.fileExists(atPath: target.path) || (try? fm.copyItem(at: source, to: target)) != nil else { continue }
            UserDefaults.standard.set(true, forKey: key)
            if selection[slot] == nil { select(target, for: slot) }
        }
    }

    /// Earlier versions kept one file per slot directly in the data folder (pet.png, pet_hurt.png,
    /// fx_cloud.png…). Move each into its library folder and keep it selected.
    private func migrateLegacyFiles() {
        let fm = FileManager.default
        for slot in AssetSlot.all {
            let legacy: String
            switch slot {
            case .pose(let p): legacy = p == .normal ? "pet.png" : "pet_\(p.rawValue).png"
            case .effect(let e): legacy = "fx_\(e.rawValue).png"
            }
            let old = PetStore.supportDir.appendingPathComponent(legacy)
            guard fm.fileExists(atPath: old.path) else { continue }
            let new = directory(slot).appendingPathComponent("\(slot.name)_legacy.png")
            if (try? fm.moveItem(at: old, to: new)) != nil, selection[slot] == nil {
                select(new, for: slot)
            }
        }
    }
}
