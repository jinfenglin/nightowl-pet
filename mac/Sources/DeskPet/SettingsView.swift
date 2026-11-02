import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: PetStore
    @AppStorage(Pref.language) private var language = AppLanguage.system.rawValue
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Text(L("通用", "General")) }.tag("general")
            SelectionTab(store: store, library: store.library).tabItem { Text(L("形象", "Appearance")) }.tag("selection")
            GenerationTab(store: store, library: store.library).tabItem { Text(L("素材生成", "Generate")) }.tag("generation")
            RulesTab(store: store).tabItem { Text(L("规则", "Rules")) }.tag("rules")
            LogTab(store: store).tabItem { Text(L("记录", "Log")) }.tag("log")
            BackupTab(store: store).tabItem { Text(L("备份", "Backup")) }.tag("backup")
        }
        .id(language)  // strings are plain values: rebuild everything when the language changes
        .padding(.top, 8)
        .frame(width: 600, height: 700)
    }
}

private func pickImageURL(_ message: String) -> URL? {
    let open = NSOpenPanel()
    open.allowedContentTypes = [.image]
    open.message = message
    return open.runModal() == .OK ? open.url : nil
}

// MARK: - 通用

private struct GeneralTab: View {
    @AppStorage(Pref.language) private var language = AppLanguage.system.rawValue
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(L("开机时自动启动 DeskPet", "Open DeskPet at login"), isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text(L("还需要在「系统设置 → 通用 → 登录项」里允许 DeskPet。",
                               "DeskPet also needs to be allowed in System Settings → General → Login Items."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("打开系统设置", "Open System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(L("启动", "Startup"))
            } footer: {
                Text(L("登录项记录的是 App 现在的位置；移动 DeskPet.app 之后需要重新打开这个开关。",
                       "The login item points at where the app is now; toggle this again after moving DeskPet.app."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(L("界面语言", "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text(L("语言", "Language"))
            } footer: {
                Text(L("菜单、设置、看板和宠物说的话都会切换。发给 AI 的提示词始终是英文，不受影响。",
                       "Switches menus, settings, the dashboard and what the pet says. Prompts sent to the AI are always English."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        // The user may approve or remove the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("设置失败：", "Couldn't change it: ") + error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: - 形象 (pick what to use)

private struct SelectionTab: View {
    @ObservedObject var store: PetStore
    @ObservedObject var library: AssetLibrary
    @AppStorage(Pref.attackStyle) private var attackStyle = AttackStyle.lightning.rawValue

    private var style: AttackStyle { AttackStyle(rawValue: attackStyle) ?? .lightning }

    var body: some View {
        Form {
            Section {
                ForEach(AssetSlot.poses) { AssetPickerRow(store: store, library: library, slot: $0, noneLabel: L("滤镜效果", "Filter")) }
            } header: {
                Text(L("宠物状态图", "Pet Poses"))
            } footer: {
                Text(L("「滤镜效果」= 不用图片，用变灰 / 倒下 / 染红代替。",
                       "\u{201C}Filter\u{201D} = no image; the pet is greyed out, tipped over or tinted red instead."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker(L("攻击特效", "Attack effect"), selection: $attackStyle) {
                    ForEach(AttackStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(L("试一下（不扣血）", "Try it (no damage)")) {
                    store.damage(9, reason: PetStore.testAttackReason, preview: true)
                }
                ForEach(style.assets) { AssetPickerRow(store: store, library: library, slot: .effect($0), noneLabel: L("代码绘制", "Drawn")) }
            } header: {
                Text(L("攻击特效", "Attack Effect"))
            } footer: {
                Text((style == .random
                      ? L("随机会在三种特效里挑，所以三种的素材都列出来。", "Random picks one of the three effects, so all their art is listed. ")
                      : L("下面是这个特效用到的素材。", "This is the art this effect uses. "))
                     + L("每类素材都在自己的文件夹里（\(AssetLibrary.root.path)）。点「打开文件夹」，把图片直接拖进去也会出现在这里；右键缩略图可以删除（移到废纸篓）。",
                         "Each kind has its own folder (\(AssetLibrary.root.path)). Click \u{201C}Open Folder\u{201D} and drop images in to add them here; right-click a thumbnail to delete it (moves to Trash)."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: attackStyle)
        .onAppear(perform: rescan)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in rescan() }
    }

    /// Pick up files added or removed in Finder.
    private func rescan() {
        library.refresh()
        store.reloadImages()
    }
}

private struct AssetPickerRow: View {
    @ObservedObject var store: PetStore
    @ObservedObject var library: AssetLibrary
    let slot: AssetSlot
    let noneLabel: String

    var body: some View {
        let files = library.files[slot] ?? []
        let selected = library.selectedURL(slot)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slot.title).font(.callout.weight(.semibold))
                Text(L("\(files.count) 张", files.count == 1 ? "1 image" : "\(files.count) images")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("导入…", "Import…")) {
                    if let url = pickImageURL(L("导入到「\(slot.title)」", "Import into \u{201C}\(slot.title)\u{201D}")),
                       let copy = library.importFile(url, for: slot) {
                        store.select(copy, for: slot)
                    }
                }
                Button(L("打开文件夹", "Open Folder")) { library.reveal(slot) }
            }
            .controlSize(.small)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tile(selected == nil) {
                        Text(noneLabel).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .onTapGesture { store.select(nil, for: slot) }
                    ForEach(files, id: \.self) { url in
                        tile(library.isSelected(url, in: slot)) {
                            if let thumb = library.thumbnail(url) {
                                Image(nsImage: thumb).resizable().interpolation(.high).scaledToFit().padding(4)
                            }
                        }
                        .onTapGesture { store.select(url, for: slot) }
                        .help(url.lastPathComponent)
                        .contextMenu {
                            Button(L("使用这张", "Use This")) { store.select(url, for: slot) }
                            Button(L("在 Finder 中显示", "Show in Finder")) { library.reveal(url) }
                            Divider()
                            Button(L("删除（移到废纸篓）", "Delete (Move to Trash)")) {
                                library.delete(url, from: slot)
                                store.reloadImages()
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private func tile<Content: View>(_ isSelected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.82))
            content()
        }
        .frame(width: 72, height: 72)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 素材生成 (make new assets)

private struct GenerationTab: View {
    @ObservedObject var store: PetStore
    @ObservedObject var library: AssetLibrary

    var body: some View {
        Form {
            if store.isBusy {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.speech ?? L("生成中…", "Generating…")).font(.callout).lineLimit(2)
                    }
                }
            }

            AISettingsSection()

            Section {
                GenerateRow(store: store, library: library, slot: .pose(.normal),
                            note: L("从一张真实照片生成，完成后会接着生成另外 3 张", "Made from a real photo; the other 3 poses follow automatically"),
                            copyPrompt: { Pref.prompt(for: .normal) },
                            buttonTitle: L("选照片生成…", "Choose Photo…")) {
                    guard let url = pickImageURL(L("选一张照片，会被制作成卡通形象", "Choose a photo to turn into a cartoon character")),
                          let photo = NSImage(contentsOf: url)?.cgImage else { return }
                    Task { await store.createCharacter(from: photo) }
                } prompt: {
                    EditablePrompt(title: L("提示词", "Prompt"), key: Pref.promptKey(for: .normal), defaultValue: Pref.defaultPrompt(for: .normal))
                }
                ForEach(PetPose.variants) { pose in
                    GenerateRow(store: store, library: library, slot: .pose(pose),
                                note: L("以当前满血图为参考", "Uses the current full-HP image as reference"),
                                copyPrompt: { Pref.prompt(for: pose) },
                                disabled: store.petImage == nil) {
                        Task { await store.generatePoses(only: [pose]) }
                    } prompt: {
                        EditablePrompt(title: L("提示词", "Prompt"), key: Pref.promptKey(for: pose), defaultValue: Pref.defaultPrompt(for: pose))
                    }
                }
                Button(L("生成残血 / 受击 / 阵亡", "Generate Low HP / Hit / Knocked Out")) { Task { await store.generatePoses() } }
                    .disabled(store.isBusy || store.petImage == nil)
            } header: {
                Text(L("宠物状态图", "Pet Poses"))
            }

            Section {
                EditablePrompt(title: L("风格（所有特效素材共用）", "Style (shared by all effect art)"), key: EffectAsset.styleKey, defaultValue: EffectAsset.defaultStyle)
                ForEach(EffectAsset.allCases) { asset in
                    GenerateRow(store: store, library: library, slot: .effect(asset),
                                note: asset.reference == nil ? nil
                                    : L("以当前「\(EffectAsset.throwerIdle.title)」为参考", "Uses the current \u{201C}\(EffectAsset.throwerIdle.title)\u{201D} as reference"),
                                copyPrompt: { asset.prompt }) {
                        Task { await store.generateEffects(only: [asset]) }
                    } prompt: {
                        EditablePrompt(title: L("素材描述", "Description"), key: asset.promptKey, defaultValue: asset.defaultSubject)
                    }
                }
                Button(L("生成全部特效素材", "Generate All Effect Art")) { Task { await store.generateEffects() } }
                    .disabled(store.isBusy)
            } header: {
                Text(L("特效素材", "Effect Art"))
            }

            Section {
                Text(L("生成的图片按类型自动存进素材库对应的文件夹（如 pet/hurt、fx/cloud），文件名带时间戳，不会覆盖旧图，并自动设为当前使用。想换回旧图或删除，去「形象」页。没有 API Key 时，可以「复制提示词」到 Gemini / ChatGPT 网页版生成，再到「形象」页导入。",
                       "Generated images are saved by type into the asset library (e.g. pet/hurt, fx/cloud) with a timestamp, never overwriting older ones, and become the current choice. To switch back or delete, go to Appearance. Without an API key, use \u{201C}Copy Prompt\u{201D} in the Gemini / ChatGPT web app, then import the result in Appearance."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GenerateRow<Prompt: View>: View {
    @ObservedObject var store: PetStore
    @ObservedObject var library: AssetLibrary
    let slot: AssetSlot
    var note: String?
    let copyPrompt: () -> String
    var buttonTitle = L("生成", "Generate")
    var disabled = false
    let generate: () -> Void
    @ViewBuilder let prompt: () -> Prompt

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.82))
                    if let url = library.selectedURL(slot), let thumb = library.thumbnail(url) {
                        Image(nsImage: thumb).resizable().interpolation(.high).scaledToFit().padding(3)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.title).font(.callout.weight(.semibold))
                    Text(note ?? generatedCount)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? L("收起提示词", "Hide Prompt") : L("提示词", "Prompt")) { withAnimation { expanded.toggle() } }
                Button(L("复制提示词", "Copy Prompt")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyPrompt(), forType: .string)
                }
                Button(buttonTitle, action: generate)
                    .disabled(store.isBusy || disabled)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            if expanded { prompt() }
        }
        .padding(.vertical, 2)
    }

    private var generatedCount: String {
        let n = (library.files[slot] ?? []).count
        return L("\(n) 张已生成 / 导入", n == 1 ? "1 generated / imported" : "\(n) generated / imported")
    }
}

// MARK: - AI 设置 (top of 素材生成)

private struct AISettingsSection: View {
    @AppStorage(Pref.provider) private var provider = ImageProvider.openAI.rawValue
    @AppStorage(Pref.apiKey) private var apiKey = ""
    @AppStorage(Pref.apiBase) private var apiBase = "https://api.openai.com/v1"
    @AppStorage(Pref.imageModel) private var imageModel = "gpt-image-1"
    @AppStorage(Pref.geminiKey) private var geminiKey = ""
    @AppStorage(Pref.geminiModel) private var geminiModel = "gemini-2.5-flash-image"
    @AppStorage(Pref.proxy) private var proxy = ""

    private var selected: ImageProvider { ImageProvider(rawValue: provider) ?? .openAI }

    var body: some View {
        Section {
            Picker(L("服务商", "Provider"), selection: $provider) {
                ForEach(ImageProvider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            switch selected {
            case .openAI:
                SecureField(L("API Key（留空读取 OPENAI_API_KEY）", "API key (blank = use OPENAI_API_KEY)"), text: $apiKey)
                TextField("API Base URL", text: $apiBase)
                ModelField(model: $imageModel, presets: selected.modelPresets)
            case .gemini:
                SecureField(L("API Key（留空读取 GEMINI_API_KEY）", "API key (blank = use GEMINI_API_KEY)"), text: $geminiKey)
                ModelField(model: $geminiModel, presets: selected.modelPresets)
            }
            TextField(L("代理（可选，如 http://127.0.0.1:7890）", "Proxy (optional, e.g. http://127.0.0.1:7890)"), text: $proxy)
        } header: {
            Text(L("AI 设置", "AI Settings"))
        } footer: {
            Group {
                switch selected {
                case .openAI:
                    Text(L("任何兼容 OpenAI 图像接口的服务都可以：改 Base URL 和模型名即可。",
                           "Any service compatible with the OpenAI images API works: just change the base URL and model name."))
                case .gemini:
                    Text(L("在 aistudio.google.com 获取 Key。Gemini 输出白底图，会自动抠成透明。",
                           "Get a key at aistudio.google.com. Gemini returns white backgrounds, which are made transparent automatically."))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ModelField: View {
    @Binding var model: String
    let presets: [String]

    var body: some View {
        HStack {
            TextField(L("模型", "Model"), text: $model)
            Menu(L("预设", "Presets")) {
                ForEach(presets, id: \.self) { name in
                    Button(name) { model = name }
                }
            }
            .fixedSize()
        }
    }
}

private struct EditablePrompt: View {
    let title: String
    let defaultValue: String
    @AppStorage private var text: String

    init(title: String, key: String, defaultValue: String) {
        self.title = title
        self.defaultValue = defaultValue
        _text = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button(L("恢复默认", "Reset")) { text = defaultValue }
                    .controlSize(.small)
                    .disabled(text == defaultValue)
            }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        }
    }
}

// MARK: - 规则

private struct RulesTab: View {
    @ObservedObject var store: PetStore

    @AppStorage(Pref.curfewStart) private var curfewStart = 0
    @AppStorage(Pref.curfewEnd) private var curfewEnd = 360
    @AppStorage(Pref.lateNightDamage) private var lateNightDamage = 2
    @AppStorage(Pref.goodNightHeal) private var goodNightHeal = 30
    @AppStorage(Pref.sittingEnabled) private var sittingEnabled = true
    @AppStorage(Pref.sittingLimit) private var sittingLimit = 90
    @AppStorage(Pref.sittingDamage) private var sittingDamage = 1
    @AppStorage(Pref.breakMinutes) private var breakMinutes = 5

    var body: some View {
        Form {
            Section(L("血量 · 当前 \(store.hp) / \(store.maxHP)", "HP · now \(store.hp) / \(store.maxHP)")) {
                Button(L("回满血（作弊）", "Full Heal (Cheat)")) {
                    store.heal(store.maxHP, reason: PetStore.fullHealReason)
                }
                .disabled(store.hp >= store.maxHP)
            }

            Section(L("熬夜惩罚", "Late-Night Penalty")) {
                DatePicker(L("宵禁开始", "Curfew starts"), selection: timeBinding($curfewStart), displayedComponents: .hourAndMinute)
                DatePicker(L("宵禁结束", "Curfew ends"), selection: timeBinding($curfewEnd), displayedComponents: .hourAndMinute)
                Stepper(L("宵禁期间每使用 1 分钟扣 \(lateNightDamage) HP", "Lose \(lateNightDamage) HP per minute of use during curfew"),
                        value: $lateNightDamage, in: 1...20)
                Stepper(L("整晚没违规，早上回复 \(goodNightHeal) HP", "Regain \(goodNightHeal) HP in the morning after a clean night"),
                        value: $goodNightHeal, in: 0...100, step: 5)
            }

            Section(L("久坐惩罚", "Sitting Penalty")) {
                Toggle(L("启用", "Enabled"), isOn: $sittingEnabled)
                Stepper(L("连续使用超过 \(sittingLimit) 分钟开始扣血", "Start losing HP after \(sittingLimit) minutes of continuous use"),
                        value: $sittingLimit, in: 15...240, step: 15)
                Stepper(L("超时后每分钟扣 \(sittingDamage) HP", "Then lose \(sittingDamage) HP per minute"), value: $sittingDamage, in: 1...10)
                Stepper(L("离开 \(breakMinutes) 分钟算休息", "A \(breakMinutes)-minute break resets it"), value: $breakMinutes, in: 1...30)
            }
            .disabled(!sittingEnabled)
        }
        .formStyle(.grouped)
        .environment(\.locale, AppLanguage.locale)  // 12/24-hour clock in the time pickers
    }

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes.wrappedValue * 60)) },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = c.hour! * 60 + c.minute!
            }
        )
    }
}

// MARK: - 备份

private struct BackupTab: View {
    @ObservedObject var store: PetStore

    var body: some View {
        Form {
            Section {
                Button(L("导出配置…", "Export Config…")) { ConfigTransfer.runExport(store: store) }
                Button(L("导入配置…", "Import Config…")) { ConfigTransfer.runImport(store: store) }
                    .disabled(store.isBusy)
            } header: {
                Text(L("导入 / 导出一整套配置", "Import / Export a Complete Config"))
            } footer: {
                Text(L("""
                包含：四张状态图、特效素材、规则（宵禁 / 扣血 / 久坐 / 奖励）、攻击特效、服务商与模型、全部提示词。
                API Key 默认不导出（导出时可勾选）；导入的文件没有 Key 时保留现在的 Key。
                不包含：当前 HP、扣血记录、代理、语言和窗口位置。
                """, """
                Includes: the four poses, effect art, rules (curfew / damage / sitting / reward), attack effect, provider and model, and all prompts.
                API keys aren't exported unless you tick the box; importing a file without keys keeps your current ones.
                Not included: current HP, the log, proxy, language and window position.
                """))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 记录

private struct LogTab: View {
    @ObservedObject var store: PetStore

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        Form {
            Section {
                Button(L("打开血量看板（最近 30 天每日最低血量）", "Open HP Dashboard (daily minimum, last 30 days)")) { DashboardWindow.show() }
            }
            Section(L("最近记录", "Recent")) {
                if store.log.isEmpty {
                    Text(L("还没有记录", "Nothing yet")).foregroundStyle(.secondary)
                }
                ForEach(store.log.prefix(100)) { entry in
                    HStack {
                        Text(Self.timeFormat.string(from: entry.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(entry.delta > 0 ? "+\(entry.delta)" : "\(entry.delta)")
                            .monospacedDigit()
                            .foregroundStyle(entry.delta > 0 ? .green : .red)
                            .frame(width: 36, alignment: .trailing)
                        Text(entry.reason).lineLimit(1)
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

