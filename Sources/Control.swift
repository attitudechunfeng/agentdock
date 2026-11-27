import Cocoa
import ApplicationServices

// 在后台点原应用的界面：输入框下方的模型 / 权限下拉、侧栏会话菜单（重命名、分叉、置顶、归档、删除）、新建会话。
// 都是先在后台切到那条会话（不切前台），再按按钮、选菜单项。

enum Chip: String { case model, perm }


private func appAX(_ s: Session) async throws -> (NSRunningApplication, AXUIElement) {
    guard AXIsProcessTrusted() else { throw SendError(message: tr("Convoy 还没有“辅助功能”权限", "Convoy doesn’t have Accessibility permission yet")) }
    let app = try await ensureRunning(s.appPath)
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAX(ax)
    return (app, ax)
}

private func menuItems(_ ax: AXUIElement) -> [AXNode] {
    axNodes(ax).filter { $0.role == "AXMenuItem" && !$0.label.isEmpty && $0.frame.height > 0 }
}

private func key(_ pid: pid_t, _ code: CGKeyCode) {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!.postToPid(pid)
    }
}

/// 一次打开的下拉菜单：记住应用、按钮和当前这层的选项，选的时候按序号
final class OpenMenu {
    let kind: Kind
    let app: NSRunningApplication
    let ax: AXUIElement
    let button: AXUIElement
    let chip: Chip
    var items: [AXNode] = []
    var effortItem: AXUIElement?   // Codex 的“强度”滑块
    var before = ""                // 打开前按钮上的值（Codex 打开后按钮文字会变）

    init(_ kind: Kind, _ app: NSRunningApplication, _ ax: AXUIElement, _ button: AXUIElement, _ chip: Chip) {
        self.kind = kind; self.app = app; self.ax = ax; self.button = button; self.chip = chip
    }

    /// 给页面看的选项。Codex 的“强度”滑块换成“降低 / 提高”两项
    var labels: [String] {
        items.map { $0.label } + (effortItem != nil ? [tr("◀ 降低强度", "◀ Lower effort"), tr("提高强度 ▶", "Raise effort ▶")] : [])
    }

    /// 按钮上现在写的值（选完后用来刷新页面上的标签）
    var current: String { chipLabel(button, chip, kind) }
}

func chipLabel(_ b: AXUIElement, _ chip: Chip, _ kind: Kind) -> String {
    let l = axLabel(b)
    // Antigravity：“Select model, current: Gemini 4 Neon High”
    if kind == .antigravity, let r = l.range(of: "current: ") { return String(l[r.upperBound...]) }
    if chip == .model { return L.stripPrefix(l, L.modelPrefix) }
    if L.anyPrefix(l, L.permPrefix) { return L.stripPrefix(l, L.permPrefix) }
    if kind == .codex {  // Codex 权限按钮标题是“更改权限”，值在里面的文字上
        return axNodesUnder(b).first { $0.role == "AXStaticText" }?.label ?? l
    }
    return l
}

private func axNodesUnder(_ el: AXUIElement, depth: Int = 6) -> [AXNode] {
    var out: [AXNode] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d < depth else { return }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            out.append(AXNode(el: c, role: (axGet(c, kAXRoleAttribute) as String?) ?? "", label: axLabel(c), frame: axFrame(c)))
            walk(c, d + 1)
        }
    }
    walk(el, 0)
    return out
}

/// 输入框附近（往上 8 层）的下拉按钮
func chipButton(_ composer: AXUIElement, _ chip: Chip, _ kind: Kind) -> AXUIElement? {
    var box = composer
    for _ in 0..<8 { if let p: AXUIElement = axGet(box, kAXParentAttribute) { box = p } }
    let pops = axNodesUnder(box, depth: 14).filter { $0.role == "AXPopUpButton" }
    switch (kind, chip) {
    case (.claude, .model): return pops.first { L.anyPrefix($0.label, L.modelPrefix) }?.el
    // 已有会话里写“跳过权限确认”，新会话页写“权限：跳过权限确认”
    case (.claude, .perm): return pops.first { L.any($0.label, L.claudePermNames) || L.anyPrefix($0.label, L.permPrefix) }?.el
    case (.codex, .model):
        // 模型下拉和“更改权限”在输入框下方同一排；别的下拉（比如回复下面的“评价回复”）不在这一排
        guard let perm = pops.first(where: { L.any($0.label, L.codexPerm) }) else { return nil }
        return pops.first { !L.any($0.label, L.codexPerm) && abs($0.frame.midY - perm.frame.midY) < 6 && $0.frame.minX > perm.frame.maxX }?.el
    case (.codex, .perm): return pops.first { L.any($0.label, L.codexPerm) }?.el
    case (.antigravity, .model): return pops.first { $0.label.hasPrefix("Select model") }?.el
    case (.antigravity, .perm): return pops.first { $0.label.hasPrefix("Agent permissions") }?.el
    default: return nil
    }
}

func openChip(_ s: Session, _ chip: Chip) async throws -> OpenMenu {
    let (app, ax) = try await appAX(s)
    guard let (_, composer) = await navigateQuietly(ax, s) else { throw SendError(message: tr("没在 \(s.app) 里切到这条会话", "Couldn’t switch to this session in \(s.app)")) }
    return try await openChipOn(app, ax, composer, chip, s.kind)
}

/// 在某个输入框旁的下拉框上打开菜单（已有会话、新会话页都用它）
func openChipOn(_ app: NSRunningApplication, _ ax: AXUIElement, _ composer: AXUIElement, _ chip: Chip, _ kind: Kind) async throws -> OpenMenu {
    let s = (kind: kind, app: app.localizedName ?? "")
    guard let b = chipButton(composer, chip, kind) else { throw SendError(message: tr("没在 \(s.app) 里找到这个下拉框", "Couldn’t find this dropdown in \(s.app)")) }
    let m = OpenMenu(kind, app, ax, b, chip)
    m.before = m.current
    log("chip \(chip) \(s.app): button found, current=\(m.before)")
    let before = Set(menuItems(ax).map { $0.label })
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    // 菜单弹出有快有慢：1.5 秒内等到选项出来为止
    for _ in 0..<10 {
        await sleep(0.15)
        m.items = menuItems(ax).filter { !before.contains($0.label) }
        if !m.items.isEmpty { await sleep(0.1); m.items = menuItems(ax).filter { !before.contains($0.label) }; break }
    }
    if s.kind == .antigravity {
        m.items = m.items.map { AXNode(el: $0.el, role: $0.role, label: $0.label.hasSuffix(" New") ? String($0.label.dropLast(4)) : $0.label, frame: $0.frame) }
    }
    if kind == .codex, let e = m.items.first(where: { L.any($0.label, L.codexEffort) }) {
        m.effortItem = e.el
        m.items.removeAll { L.any($0.label, L.codexEffort) }
    }
    log("chip \(chip) \(s.app): \(m.labels)")
    return m
}

/// 选第 index 项。点开了下一层（比如“选择模型”“思考强度”）就返回 true，菜单换成下一层的选项
func chooseChip(_ m: OpenMenu, _ index: Int) async -> Bool {
    if index >= m.items.count, let e = m.effortItem {
        // Codex 强度滑块：聚焦后发左右方向键（只发给 Codex 进程）
        axSet(e, kAXFocusedAttribute, kCFBooleanTrue)
        await sleep(0.1)
        key(m.app.processIdentifier, index == m.items.count ? 123 : 124)
        await sleep(0.3)
        return true
    }
    guard m.items.indices.contains(index) else { return false }
    let before = Set(menuItems(m.ax).map { $0.label })
    AXUIElementPerformAction(m.items[index].el, kAXPressAction as CFString)
    await sleep(0.5)
    let new = menuItems(m.ax).filter { !before.contains($0.label) }
    if !new.isEmpty {
        m.items = new
        m.effortItem = nil
        return true
    }
    return false
}

/// 不选了：先发 Esc；Claude 的下拉 Esc 关不掉，就点一下当前选中的那项（等于不变）
func closeChip(_ m: OpenMenu) async {
    key(m.app.processIdentifier, 53)
    await sleep(0.3)
    let left = menuItems(m.ax)
    guard !left.isEmpty else { return }
    let cur = m.current
    if let same = left.first(where: { cur.hasPrefix($0.label) || $0.label.hasPrefix(cur) }) {
        AXUIElementPerformAction(same.el, kAXPressAction as CFString)
    } else {
        key(m.app.processIdentifier, 53)
    }
}

// MARK: 会话管理

enum SessionAction: String { case rename, fork, pin, archive, delete }

func runSessionAction(_ s: Session, _ action: SessionAction, newName: String = "") async throws {
    let (app, ax) = try await appAX(s)
    // 打开这条会话的菜单：Claude 是“更多选项”按钮，Codex 是侧栏条目的右键菜单
    let before = Set(menuItems(ax).map { $0.label })
    if s.kind == .claude {
        guard let b = findButton(ax, { L.any($0.label, L.claudeMore(s.title)) }) else { throw SendError(message: tr("在 Claude 侧栏里没找到这条会话", "Couldn’t find this session in the Claude sidebar")) }
        AXUIElementPerformAction(b.el, kAXPressAction as CFString)
    } else if s.kind == .antigravity {
        // 侧栏里会话是个链接，同一行里有“More options”下拉
        guard let link = axNodes(ax).first(where: { $0.role == "AXLink" && $0.label == s.title }) else { throw SendError(message: tr("在 Antigravity 侧栏里没找到这条会话", "Couldn’t find this session in the Antigravity sidebar")) }
        var row = link.el
        if let p: AXUIElement = axGet(row, kAXParentAttribute) { row = p }
        guard let more = axNodesUnder(row).first(where: { $0.role == "AXPopUpButton" && $0.label == "More options" }) else { throw SendError(message: tr("没找到这条会话的菜单", "Couldn’t find this session’s menu")) }
        AXUIElementPerformAction(more.el, kAXPressAction as CFString)
    } else {
        guard let b = findButton(ax, { $0.role == "AXButton" && $0.label == s.title }) else { throw SendError(message: tr("在 Codex 侧栏里没找到这条会话", "Couldn’t find this session in the Codex sidebar")) }
        AXUIElementPerformAction(b.el, kAXShowMenuAction as CFString)
    }
    await sleep(0.5)
    // 按菜单路径一层层点（Codex 的分叉要再点“创建聊天分支”）
    var pressed = false
    for names in L.menuPath[s.kind]![action]! {
        guard let it = menuItems(ax).first(where: { L.item($0.label, names) }) else { continue }
        AXUIElementPerformAction(it.el, kAXPressAction as CFString)
        pressed = true
        await sleep(0.5)
    }
    guard pressed else {
        key(app.processIdentifier, 53)
        throw SendError(message: tr("\(s.app) 的菜单里没有这一项", "\(s.app)’s menu doesn’t have this option"))
    }
    switch action {
    case .rename:
        // Claude：侧栏里变成输入框；Codex：弹出“重命名聊天”对话框
        guard let f = axNodes(ax).first(where: { $0.role == "AXTextField" && (L.any($0.label, L.renameField) || $0.label == s.title || $0.label.lowercased().contains("rename") || $0.label.lowercased().contains("title")) }) else {
            throw SendError(message: tr("没找到重命名输入框", "Couldn’t find the rename field"))
        }
        AXUIElementSetAttributeValue(f.el, kAXValueAttribute as CFString, newName as CFString)
        axSet(f.el, kAXFocusedAttribute, kCFBooleanTrue)
        await sleep(0.2)
        if s.kind == .codex, let save = findButton(ax, { $0.role == "AXButton" && L.any($0.label, L.save) }) {
            AXUIElementPerformAction(save.el, kAXPressAction as CFString)
        } else {
            key(app.processIdentifier, 36)
        }
    case .delete:
        // 删除一般会再弹一次确认：找新冒出来的“删除”按钮
        await sleep(0.3)
        if let ok = axNodes(ax).first(where: { $0.role == "AXButton" && L.any($0.label, L.deleteConfirm) && $0.frame.height > 0 }) {
            AXUIElementPerformAction(ok.el, kAXPressAction as CFString)
            log("delete confirmed in dialog")
        }
    default: break
    }
    await sleep(0.5)
    log("session action \(action) \(s.app) \(s.title): done")
}

// MARK: 新建会话：Claude / Codex 点侧栏里“在 某目录 中新建”，写入第一条消息并发送；Antigravity 用 agentapi

/// 原应用里已经打开的新会话页：应用、界面、输入框
typealias NewSessionUI = (app: NSRunningApplication, ax: AXUIElement, composer: AXUIElement)

/// 新建会话。prepared：已经为了选模型/权限打开过新会话页，就直接在那里发；agyModel：Antigravity 指定模型 id
func newSession(kind: Kind, appPath: String, folder: String, text: String,
                prepared: NewSessionUI? = nil, agyModel: String? = nil) async throws {
    if kind == .antigravity {
        _ = try await ensureRunning(appPath)
        let args = ["new-conversation"] + (agyModel.map { ["--model=\($0)"] } ?? []) + [text]
        try await Task.detached { try runAgentapi(args) }.value
        return
    }
    let ui: NewSessionUI
    if let p = prepared { ui = p } else { ui = try await openNewSessionUI(kind: kind, appPath: appPath, folder: folder) }
    try await sendInComposer(ui, text)
    log("new session \(kind) in \((folder as NSString).lastPathComponent): sent")
}

/// 在原应用里点“在 某目录 中新建”，等新会话的空输入框出来
func openNewSessionUI(kind: Kind, appPath: String, folder: String) async throws -> NewSessionUI {
    guard AXIsProcessTrusted() else { throw SendError(message: tr("Convoy 还没有“辅助功能”权限", "Convoy doesn’t have Accessibility permission yet")) }
    let app = try await ensureRunning(appPath)
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAX(ax)
    let name = (folder as NSString).lastPathComponent
    let wants = kind == .claude ? L.claudeNew(name) : L.codexNew(name)
    guard let b = findButton(ax, { L.any($0.label, wants) }) ?? (kind == .codex ? findButton(ax, { L.any($0.label, L.newChat) }) : nil) else {
        throw SendError(message: tr("在应用侧栏里没找到「\(wants[0])」", "Couldn’t find “\(wants[0])” in the app sidebar"))
    }
    AXUIElementPerformAction(b.el, kAXPressAction as CFString)
    // 新会话还没有标题，取主窗口里最靠下、空着的输入框
    var composer: AXUIElement?
    for _ in 0..<12 {
        await sleep(0.3)
        let wins = ((axGet(ax, kAXWindowsAttribute) as [AXUIElement]?) ?? [])
            .filter { (axGet($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
        composer = wins.lazy.compactMap { w in
            axNodesIn(w).filter { $0.role == kAXTextAreaRole }.max { $0.frame.minY < $1.frame.minY }?.el
        }.first
        if let c = composer, composerEmpty(c) { break }
    }
    guard let c = composer, composerEmpty(c) else { throw SendError(message: tr("新会话的输入框没准备好，消息没发", "The new session’s input box wasn’t ready. The message wasn’t sent.")) }
    return (app, ax, c)
}

func sendInComposer(_ ui: NewSessionUI, _ text: String) async throws {
    let c = ui.composer
    guard composerEmpty(c) || normalized(composerValue(c)) == normalized(text) else { throw SendError(message: tr("新会话的输入框里已经有内容，没发", "The new session’s input box already has text. Nothing was sent.")) }
    AXUIElementSetAttributeValue(c, kAXValueAttribute as CFString, text as CFString)
    // 界面刷新有延迟：1.5 秒内反复核对
    var ok = false
    for _ in 0..<10 {
        await sleep(0.15)
        if normalized(composerValue(c)) == normalized(text) { ok = true; break }
    }
    guard ok else { throw SendError(message: tr("写入新会话输入框的内容对不上，没发", "The text written into the new session’s input box doesn’t match. Nothing was sent.")) }
    guard let send = sendButton(c) else { throw SendError(message: tr("新会话里没找到发送按钮", "Couldn’t find the send button in the new session")) }
    AXUIElementPerformAction(send, kAXPressAction as CFString)
}

// MARK: Antigravity 新会话的选项：模型列表从本地服务读，权限预设是固定四档

let agyPresets = ["Request Review", "Default", "Auto", "Turbo"]

func agyModels() async -> [(label: String, id: String)] {
    guard let r = try? await agyRPC("GetCascadeModelConfigData", [:]) else { return [] }
    return ((r["clientModelConfigs"] as? [[String: Any]]) ?? []).compactMap { c in
        guard c["disabled"] as? Bool != true, let l = c["label"] as? String, let id = c["modelId"] as? String else { return nil }
        return (l, id)
    }
}

func axNodesIn(_ win: AXUIElement) -> [AXNode] {
    var out: [AXNode] = []
    var left = 30000
    func walk(_ e: AXUIElement, _ d: Int) {
        left -= 1
        guard left > 0, d < 80 else { return }
        out.append(AXNode(el: e, role: (axGet(e, kAXRoleAttribute) as String?) ?? "", label: axLabel(e), frame: axFrame(e)))
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) }
    }
    walk(win, 0)
    return out
}

// MARK: 停止、排队发送、用量

/// 按输入框旁的“停止”
func stopSession(_ s: Session) async throws {
    if s.kind == .antigravity {
        _ = try await agyRPC("CancelCascadeInvocation", ["cascadeId": s.rawId])
        log("stop antigravity \(s.title)")
        return
    }
    let (_, ax) = try await appAX(s)
    guard let (_, c) = await navigateQuietly(ax, s) else { throw SendError(message: tr("没在 \(s.app) 里切到这条会话", "Couldn’t switch to this session in \(s.app)")) }
    guard let b = buttonsNear(c).first(where: { L.any(axLabel($0), L.stop) }) else { throw SendError(message: tr("\(s.app) 里这条会话没有在跑", "This session isn’t running in \(s.app)")) }
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    log("stop \(s.app) \(s.title)")
}

// MARK: 用量

struct UsageItem: Hashable {
    let label: String      // 5 小时 / 每周 / Gemini 每周 …
    let used: Double?      // 已用比例 0–1；没有比例的（比如 Codex 额度）为空
    let note: String       // 重置时间或额度数字
}

struct UsageApp: Identifiable, Hashable {
    var id: String { app }
    let app: String
    let appPath: String
    let items: [UsageItem]
}

private let bjFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = tr("M月d日 HH:mm", "MMM d HH:mm")
    return f
}()

/// 用量：
/// - Claude：在后台点开输入框旁的“用量”面板，读两条进度条（5 小时、每周）和各自的重置时间，读完按 Esc 关掉
/// - Antigravity：本地服务的只读接口
/// - Codex：点开侧栏“用量”菜单读完关掉
func readUsage() async -> [UsageApp] {
    guard AXIsProcessTrusted() else { return [] }
    var out: [UsageApp] = []
    for (name, path) in claudeApps {
        guard let app = runningApp(path) else { continue }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        enableWebAX(ax)
        guard let b = axNodes(ax).first(where: { $0.role == "AXPopUpButton" && L.anyPrefix($0.label, L.claudeUsagePrefix) }) else { continue }
        AXUIElementPerformAction(b.el, kAXPressAction as CFString)
        await sleep(0.6)
        let nodes = axNodes(ax)
        let levels = nodes.filter { $0.role == "AXLevelIndicator" }
        let texts = nodes.filter { $0.role == "AXStaticText" && ($0.label.hasSuffix("重置") || $0.label.lowercased().hasPrefix("resets")) }
        let items: [UsageItem] = levels.map { lv in
            let v = (axGet(lv.el, kAXValueAttribute) as NSNumber?)?.doubleValue ?? 0
            // 重置时间写在进度条上方那一行的右侧
            let reset = texts.min { abs($0.frame.maxY - lv.frame.minY) < abs($1.frame.maxY - lv.frame.minY) }?.label ?? ""
            let label = lv.label.replacingOccurrences(of: "限额", with: "").replacingOccurrences(of: " · 所有模型", with: "")
                .replacingOccurrences(of: " limit", with: "").replacingOccurrences(of: " · All models", with: "")
            return UsageItem(label: label.trimmingCharacters(in: .whitespaces), used: v / 100, note: reset)
        }
        key(app.processIdentifier, 53)
        if !items.isEmpty { out.append(UsageApp(app: name, appPath: path, items: items)) }
    }
    if let r = try? await agyRPC("RetrieveUserQuotaSummary", [:]),
       let groups = (r["response"] as? [String: Any])?["groups"] as? [[String: Any]] {
        var items: [UsageItem] = []
        for g in groups {
            let gname = (g["displayName"] as? String ?? "").replacingOccurrences(of: "Gemini Models", with: "Gemini")
                .replacingOccurrences(of: "Claude and GPT models", with: "Claude/GPT")
            for bk in (g["buckets"] as? [[String: Any]]) ?? [] {
                guard let f = bk["remainingFraction"] as? Double else { continue }
                let w = bk["window"] as? String == "weekly" ? tr("每周", "weekly") : bk["window"] as? String == "5h" ? tr("5 小时", "5-hour") : (bk["window"] as? String ?? "")
                let reset = (bk["resetTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }.map { tr(bjFormatter.string(from: $0) + " 重置", "Resets " + bjFormatter.string(from: $0)) } ?? ""
                items.append(UsageItem(label: "\(gname) \(w)", used: 1 - f, note: reset))
            }
        }
        if !items.isEmpty { out.append(UsageApp(app: "Antigravity", appPath: "/Applications/Antigravity.app", items: items)) }
    }
    // Codex：会话记录里每轮都写一份用量（rate_limits）。够新就直接用，不去点 Codex 的界面；
    // 旧了再点侧栏“用量”菜单读；Codex 没开窗口（菜单不存在）时退回用记录里最后一次的数字
    let fileUsage = codexUsageFromFiles()
    if let f = fileUsage, Date().timeIntervalSince(f.at) < 30 * 60 {
        out.append(UsageApp(app: "Codex", appPath: codexAppPath, items: f.items))
    } else if let app = runningApp(codexAppPath), let items = await codexUsageFromUI(app), !items.isEmpty {
        out.append(UsageApp(app: "Codex", appPath: codexAppPath, items: items))
    } else if let f = fileUsage {
        out.append(UsageApp(app: "Codex", appPath: codexAppPath, items: f.items))
    }
    return out
}

/// 从 ~/.codex/sessions 里最近写过的记录，取最后一条带 rate_limits 的事件
func codexUsageFromFiles() -> (items: [UsageItem], at: Date)? {
    let root = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
    var files: [(URL, Date)] = []
    for case let u as URL in e where u.pathExtension == "jsonl" {
        files.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
    }
    for (u, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(3) {
        guard let h = try? FileHandle(forReadingFrom: u) else { continue }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        for chunk in [UInt64(512 << 10), 8 << 20] {
            try? h.seek(toOffset: size > chunk ? size - chunk : 0)
            guard let d = try? h.readToEnd(), let text = String(data: d, encoding: .utf8) else { break }
            guard let line = text.split(separator: "\n").last(where: { $0.contains("\"rate_limits\":{") }),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let rl = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else {
                if size <= chunk { break } else { continue }
            }
            let at = (obj["timestamp"] as? String).flatMap { isoFrac.date(from: $0) } ?? Date()
            var items: [UsageItem] = []
            for k in ["primary", "secondary"] {
                guard let w = rl[k] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                let label = mins >= 7 * 24 * 60 ? tr("每周", "Weekly") : mins == 300 ? tr("5 小时", "5-hour") : tr("\(mins / 60) 小时", "\(mins / 60)-hour")
                let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                if let r = reset, r < Date() {   // 记录之后窗口已经重置过
                    items.append(UsageItem(label: label, used: 0, note: tr("已重置", "Reset")))
                } else {
                    items.append(UsageItem(label: label, used: used / 100,
                                           note: reset.map { tr(bjFormatter.string(from: $0) + " 重置", "Resets " + bjFormatter.string(from: $0)) } ?? ""))
                }
            }
            if let c = rl["credits"] as? [String: Any], c["unlimited"] as? Bool != true,
               let b = Double("\(c["balance"] ?? "")") {
                items.append(UsageItem(label: tr("额度", "Credits"), used: nil, note: Int(b).formatted()))
            }
            return items.isEmpty ? nil : (items, at)
        }
    }
    return nil
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// 点开 Codex 侧栏的“用量”菜单读完关掉（要 Codex 开着窗口）
private func codexUsageFromUI(_ app: NSRunningApplication) async -> [UsageItem]? {
    do {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        enableWebAX(ax)
        if let b = findButton(ax, { $0.role == "AXPopUpButton" && L.any($0.label, L.codexUsage) }) {
            AXUIElementPerformAction(b.el, kAXPressAction as CFString)
            await sleep(0.5)
            // 菜单项有时是中文（每周限额 剩余 78%），有时是英文（Weekly limit 78% left）
            var items: [UsageItem] = []
            for n in axNodes(ax) where n.role == "AXMenuItem" {
                let l = n.label
                if let m = l.firstMatch(of: #/(\d+)%/#), l.contains("限额") || l.lowercased().contains("limit") {
                    let weekly = l.lowercased().contains("weekly") || l.contains("每周")
                    items.append(UsageItem(label: weekly ? tr("每周", "Weekly") : tr("5 小时", "5-hour"), used: 1 - (Double(m.1) ?? 0) / 100, note: ""))
                } else if let m = l.firstMatch(of: #/([\d,]+)/#), l.hasPrefix("额度") || l.hasPrefix("Credits") {
                    items.append(UsageItem(label: tr("额度", "Credits"), used: nil, note: String(m.1)))
                }
            }
            key(app.processIdentifier, 53)
            return items
        }
        return nil
    }
}


// MARK: 批准请求：agent 中途要你批准时，在 Convoy 里直接批

/// 一个待批准的请求。Claude / Codex 的按钮是原应用里的；Antigravity 走它本地服务的接口
struct Approval {
    let title: String
    let detail: String
    let labels: [String]
    var buttons: [AXUIElement] = []                 // Claude / Codex：对应原应用里的按钮
    var agy: (trajectoryId: String, stepIndex: Int, kind: String)?   // Antigravity
}

/// Claude / Codex：在输入框区域找批准卡片上的按钮（文字在批准 / 拒绝两组同义词里），连同卡片上的说明文字
func findApproval(_ s: Session, navigate: Bool) async -> Approval? {
    guard AXIsProcessTrusted(), let app = runningApp(s.appPath) else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAX(ax)
    let t = navigate ? await navigateQuietly(ax, s) : findTargetPublic(ax, s)
    guard let (_, composer) = t else { return nil }
    var box = composer
    for _ in 0..<9 { if let p: AXUIElement = axGet(box, kAXParentAttribute) { box = p } }
    var buttons: [(AXUIElement, String)] = []
    var texts: [String] = []
    var left = 4000
    func walk(_ e: AXUIElement, _ d: Int) {
        left -= 1
        guard left > 0, d < 16 else { return }
        let role: String = axGet(e, kAXRoleAttribute) ?? ""
        let l = axLabel(e)
        if role == kAXButtonRole, L.item(l, L.approve) || L.item(l, L.deny) { buttons.append((e, l)) }
        if role == "AXStaticText", l.count > 1 { texts.append(l) }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) }
    }
    walk(box, 0)
    // 同意类和拒绝类按钮都在，才算一张批准卡片（防止把别的按钮误当成批准）
    guard buttons.contains(where: { L.item($0.1, L.approve) }), buttons.contains(where: { L.item($0.1, L.deny) }) else { return nil }
    let detail = texts.suffix(6).joined(separator: " ").prefix(300)
    return Approval(title: tr("\(s.app) 在等你批准", "\(s.app) is waiting for your approval"), detail: String(detail), labels: buttons.map(\.1), buttons: buttons.map(\.0))
}

/// Antigravity：最近几步里状态是 WAITING、带批准请求的那一步
func agyApproval(_ s: Session, offset: Int) async -> Approval? {
    guard let r = try? await agyRPC("GetCascadeTrajectorySteps", ["cascadeId": s.rawId, "stepOffset": offset]) else { return nil }
    for st in ((r["steps"] as? [[String: Any]]) ?? []).reversed() where (st["status"] as? String)?.hasSuffix("WAITING") == true {
        guard let req = (st["requestedInteraction"] as? [String: Any]),
              let info = (st["metadata"] as? [String: Any])?["sourceTrajectoryStepInfo"] as? [String: Any],
              let traj = info["trajectoryId"] as? String else { continue }
        let step = (info["stepIndex"] as? Int) ?? Int("\(info["stepIndex"] ?? "")") ?? 0
        let kind = req["filePermission"] != nil ? "filePermission" : "permission"
        let target = ((req["permission"] as? [String: Any])?["resource"] as? [String: Any])?["target"] as? String
            ?? (req["filePermission"] as? [String: Any])?["absolutePathUri"] as? String ?? ""
        let what = ((st["type"] as? String) ?? "").replacingOccurrences(of: "CORTEX_STEP_TYPE_", with: "").lowercased()
        return Approval(title: tr("Antigravity 在等你批准", "Antigravity is waiting for your approval"), detail: [what, target].filter { !$0.isEmpty }.joined(separator: tr("：", ": ")).prefix(300).description,
                        labels: [tr("批准（这一次）", "Approve (once)"), tr("拒绝", "Deny")], agy: (traj, step, kind))
    }
    return nil
}

func answerApproval(_ s: Session, _ a: Approval, _ index: Int) async throws {
    if let g = a.agy {
        let allow = index == 0
        _ = try await agyRPC("HandleCascadeUserInteraction", [
            "cascadeId": s.rawId,
            "interaction": ["trajectoryId": g.trajectoryId, "stepIndex": g.stepIndex,
                            g.kind: ["allow": allow, "scope": "PERMISSION_SCOPE_ONCE"]],
        ])
        log("approval antigravity \(s.title): allow=\(allow)")
        return
    }
    AXUIElementPerformAction(a.buttons[index], kAXPressAction as CFString)
    log("approval \(s.app) \(s.title): pressed \(a.labels[index])")
}


// MARK: 自检：启动时和原应用版本变化时，对每个应用检查关键操作还能不能用（只读，不发送、不改设置）

struct CheckItem: Hashable { let name: String; let ok: Bool }
struct AppCheck: Identifiable, Hashable {
    var id: String { app }
    let app: String
    let version: String
    let items: [CheckItem]
    var failed: [String] { items.filter { !$0.ok }.map(\.name) }
}

let checkApps: [(name: String, path: String, kind: Kind)] = claudeApps.map { ($0.label, $0.path, Kind.claude) } + [
    ("Codex", codexAppPath, .codex),
    ("Antigravity", "/Applications/Antigravity.app", .antigravity),
]

func appVersion(_ path: String) -> String {
    Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
}

func selfCheck(_ sessions: [Session]) async -> [AppCheck] {
    var out: [AppCheck] = []
    for a in checkApps {
        guard let app = runningApp(a.path) else { continue }
        var items: [CheckItem] = []
        let mine = sessions.filter { $0.appPath == a.path }
        // 记录格式：最近一条会话能解析出内容
        if let s = mine.first(where: { $0.transcript != nil }) { items.append(CheckItem(name: tr("记录格式", "Transcript format"), ok: !readDetail(s).items.isEmpty)) }
        if AXIsProcessTrusted() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            enableWebAX(ax)
            let wins = ((axGet(ax, kAXWindowsAttribute) as [AXUIElement]?) ?? []).filter { (axGet($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
            guard !wins.isEmpty else {
                items.append(CheckItem(name: tr("窗口没开，界面检查跳过", "No window open, UI checks skipped"), ok: true))
                out.append(AppCheck(app: a.name, version: appVersion(a.path), items: items))
                continue
            }
            // 刚打开辅助功能时界面结构要一会儿才完整：最多等 3 秒，等到输入框出来
            var nodes: [AXNode] = []
            var composer: AXUIElement?
            for _ in 0..<12 {
                nodes = wins.flatMap { axNodesIn($0) }
                composer = nodes.filter { $0.role == kAXTextAreaRole }.max { $0.frame.minY < $1.frame.minY }?.el
                if composer != nil { break }
                await sleep(0.25)
            }
            items.append(CheckItem(name: tr("输入框", "Input box"), ok: composer != nil))
            if let c = composer {
                items.append(CheckItem(name: tr("模型下拉", "Model menu"), ok: chipButton(c, .model, a.kind) != nil))
                items.append(CheckItem(name: tr("权限下拉", "Permission menu"), ok: chipButton(c, .perm, a.kind) != nil))
            }
            let titles = Set(mine.map(\.title))
            let sidebar: Bool
            switch a.kind {
            case .claude: sidebar = nodes.contains { n in n.role == "AXPopUpButton" && titles.contains { t in L.any(n.label, L.claudeMore(t)) } }
            case .codex: sidebar = nodes.contains { $0.role == "AXButton" && titles.contains($0.label) }
            case .antigravity: sidebar = nodes.contains { $0.role == "AXLink" && titles.contains($0.label) }
            }
            items.append(CheckItem(name: tr("侧栏会话", "Sidebar sessions"), ok: sidebar))
            switch a.kind {
            case .claude: items.append(CheckItem(name: tr("用量", "Usage"), ok: nodes.contains { $0.role == "AXPopUpButton" && L.anyPrefix($0.label, L.claudeUsagePrefix) }))
            case .codex: items.append(CheckItem(name: tr("用量", "Usage"), ok: nodes.contains { $0.role == "AXPopUpButton" && L.any($0.label, L.codexUsage) }))
            case .antigravity: break
            }
        } else {
            items.append(CheckItem(name: tr("辅助功能权限", "Accessibility permission"), ok: false))
        }
        if a.kind == .antigravity {
            items.append(CheckItem(name: tr("本地接口", "Local API"), ok: (try? await agyRPC("GetPermissionSettings", [:])) != nil))
        }
        out.append(AppCheck(app: a.name, version: appVersion(a.path), items: items))
    }
    return out
}

// MARK: Claude 的问题卡片（AskUserQuestion）
// 原应用里是一张卡片：一次显示一道题（卡片的说明就是题目），选项是可勾选的按钮（名字是“选项 说明”），
// 末尾一个“其他”；右上角翻题，右下角“跳过”“下一步”（最后一题可能叫“提交”）。

struct AskAnswer { let labels: [String]; let other: String }

private func askCard(_ win: AXUIElement) -> AXUIElement? {
    var found: AXUIElement?
    var budget = 30000
    func hasCheck(_ e: AXUIElement, _ d: Int) -> Bool {
        if (axGet(e, kAXRoleAttribute) as String?) == kAXCheckBoxRole { return true }
        guard d < 4 else { return false }
        return ((axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? []).contains { hasCheck($0, d + 1) }
    }
    func walk(_ e: AXUIElement, _ d: Int) {
        budget -= 1
        guard budget > 0, d < 90, found == nil else { return }
        if (axGet(e, kAXSubroleAttribute) as String?) == "AXApplicationGroup", hasCheck(e, 0) { found = e; return }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) }
    }
    walk(win, 0)
    return found
}

private struct CardParts {
    var checks: [(AXUIElement, String)] = []
    var buttons: [(AXUIElement, String)] = []
    var fields: [AXUIElement] = []
}

private func cardParts(_ card: AXUIElement) -> CardParts {
    var p = CardParts()
    var budget = 3000
    func walk(_ e: AXUIElement, _ d: Int) {
        budget -= 1
        guard budget > 0, d < 20 else { return }
        switch axGet(e, kAXRoleAttribute) as String? {
        case kAXCheckBoxRole: p.checks.append((e, axLabel(e)))
        case kAXButtonRole: p.buttons.append((e, axLabel(e)))
        case kAXTextAreaRole, kAXTextFieldRole: p.fields.append(e)
        default: break
        }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) }
    }
    walk(card, 0)
    return p
}

/// 卡片说明是截短的题目
private func sameQuestion(_ desc: String, _ q: String) -> Bool {
    let a = normalized(desc).trimmingCharacters(in: CharacterSet(charactersIn: "…. ")), b = normalized(q)
    return !a.isEmpty && (b.hasPrefix(a) || a.hasPrefix(b))
}

private func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }

private func isChecked(_ e: AXUIElement) -> Bool { ((axGet(e, kAXValueAttribute) as NSNumber?)?.intValue ?? 0) != 0 }

func answerAsk(_ s: Session, _ ask: PendingAsk, _ answers: [AskAnswer]) async throws {
    guard AXIsProcessTrusted() else { throw SendError(message: tr("Convoy 还没有辅助功能权限", "Convoy doesn’t have Accessibility permission yet")) }
    guard let app = runningApp(s.appPath) else { throw SendError(message: tr("\(s.app) 没在运行", "\(s.app) isn’t running")) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAX(ax)
    guard let (win, _) = await navigateQuietly(ax, s) else { throw SendError(message: tr("在 \(s.app) 里没找到这条会话", "Couldn’t find this session in \(s.app)")) }
    for (i, q) in ask.questions.enumerated() where i < answers.count {
        let a = answers[i]
        // 找到这道题：卡片停在别的题上就翻过去
        var card: AXUIElement?
        for _ in 0..<16 {
            guard let c = askCard(win) else { await sleep(0.25); continue }
            let desc: String = axGet(c, kAXDescriptionAttribute) ?? ""
            if sameQuestion(desc, q.question) { card = c; break }
            let at = ask.questions.firstIndex { sameQuestion(desc, $0.question) } ?? 0
            let names = at < i ? L.askNext : L.askPrev
            guard let b = cardParts(c).buttons.first(where: { L.any($0.1, names) }) else { break }
            press(b.0)
            await sleep(0.3)
        }
        guard let card else { throw SendError(message: tr("在 \(s.app) 里没找到第 \(i + 1) 题的卡片", "Couldn’t find the card for question \(i + 1) in \(s.app)")) }
        // 先等卡片稳定一下（刚出来时原应用会把单选的第一项设成默认勾选）
        await sleep(0.3)
        func wanted(_ l: String) -> Bool { a.labels.contains { l == $0 || l.hasPrefix($0 + " ") } }
        for l in a.labels where !cardParts(card).checks.contains(where: { $0.1 == l || $0.1.hasPrefix(l + " ") }) {
            throw SendError(message: tr("第 \(i + 1) 题里没找到选项“\(l)”", "Couldn’t find the option “\(l)” in question \(i + 1)"))
        }
        // 点选，再核对：勾上的正好是要的那些、隔一会儿再看还是这样才算数；对不上就不提交。
        // 每次都重新找卡片（原应用重绘后旧的界面元素会失效，读出来是空的，不能当成“没勾”）
        func current() -> [(AXUIElement, String)]? {
            guard let c = askCard(win), sameQuestion(axGet(c, kAXDescriptionAttribute) ?? "", q.question) else { return nil }
            let checks = cardParts(c).checks
            return checks.filter({ !L.any($0.1, L.askOther) }).count == q.options.count ? checks : nil
        }
        func mismatch(_ checks: [(AXUIElement, String)]) -> (opts: [(AXUIElement, String)], other: AXUIElement?) {
            let other = checks.first { L.any($0.1, L.askOther) }?.0
            let otherBad = a.other.isEmpty ? (other.map(isChecked) ?? false) : !(other.map(isChecked) ?? false)
            return (checks.filter { !L.any($0.1, L.askOther) && isChecked($0.0) != wanted($0.1) }, otherBad ? other : nil)
        }
        var ok = false
        for _ in 0..<5 {
            guard let checks = current() else { await sleep(0.3); continue }
            let (bad, other) = mismatch(checks)
            if bad.isEmpty && other == nil {
                await sleep(0.4)
                if let again = current(), mismatch(again).opts.isEmpty, mismatch(again).other == nil { ok = true; break }
                continue
            }
            // 多选：不对的都点一下；单选：只点要的那项（会顶掉默认勾选的）
            for (el, l) in bad where q.multiSelect || wanted(l) { press(el); await sleep(0.25) }
            if let o = other { press(o); await sleep(0.3) }
            await sleep(0.3)
        }
        guard ok else {
            let state = (current() ?? []).map { "\($0.1.split(separator: " ").first ?? "")\(isChecked($0.0) ? "✓" : "")" }.joined(separator: " ")
            log("ask q\(i + 1) mismatch: \(state)")
            throw SendError(message: tr("第 \(i + 1) 题没能选成你要的（现在是：\(state)），没有提交，请到 \(s.app) 里看一下", "Question \(i + 1) didn’t end up with your choice (now: \(state)). Nothing was submitted. Please check in \(s.app)."))
        }
        if !a.other.isEmpty {
            var field: AXUIElement?
            for _ in 0..<8 {
                if let c = askCard(win), let f = cardParts(c).fields.first { field = f; break }
                await sleep(0.25)
            }
            guard let field else { throw SendError(message: tr("第 \(i + 1) 题点了“其他”但没出现输入框", "Question \(i + 1): clicked “Other” but no text field appeared")) }
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, a.other as CFString)
            await sleep(0.3)
            if normalized((axGet(field, kAXValueAttribute) as String?) ?? "") != normalized(a.other) {
                throw SendError(message: tr("第 \(i + 1) 题“其他”的文字没写进去", "Question \(i + 1): the “Other” text didn’t get written in"))
            }
        }
        // 单选点完可能自己跳到下一题；还停在这题才按“下一步/提交”
        if let c = askCard(win), sameQuestion(axGet(c, kAXDescriptionAttribute) ?? "", q.question) {
            guard let next = cardParts(c).buttons.first(where: { L.any($0.1, L.askSubmit) }) else {
                throw SendError(message: tr("第 \(i + 1) 题没找到“下一步”按钮", "Question \(i + 1): couldn’t find the “Next” button"))
            }
            press(next.0)
            await sleep(0.4)
        }
    }
    // 以记录为准：Claude 收到回答会写一条这个问题的工具结果
    func answered() -> Bool {
        guard let f = s.transcript else { return false }
        return tailLines(f, 400_000).contains { $0.contains("\"tool_use_id\":\"\(ask.id)\"") }
    }
    for round in 0..<2 {
        for _ in 0..<12 {
            if answered() { log("ask \(s.title): answered \(answers.count)"); return }
            await sleep(0.25)
        }
        // 最后可能还有一页确认：找“提交”按一下再等
        guard round == 0, let b = axNodes(ax).first(where: { $0.role == kAXButtonRole && L.any($0.label, ["提交", "Submit"]) }) else { break }
        press(b.el)
    }
    throw SendError(message: tr("回答已经填好，但 \(s.app) 还没收到，请到原应用里看一下", "The answers are filled in, but \(s.app) hasn’t received them yet. Please check in the original app."))
}
