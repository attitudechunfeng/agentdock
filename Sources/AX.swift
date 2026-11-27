import Cocoa
import ApplicationServices

// 辅助功能接口的小工具：读写属性、导出界面树（排查找不到输入框时用）。

func axGet<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func axSet(_ el: AXUIElement, _ name: String, _ v: CFTypeRef) {
    AXUIElementSetAttributeValue(el, name as CFString, v)
}

func axFrame(_ el: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v: AXValue = axGet(el, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
    if let v: AXValue = axGet(el, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}

func runningApp(_ path: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
}

/// 这个应用是不是你正在用的（最前面那个）：是的话别在后台点它的界面
func isFrontmost(_ path: String) -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleURL?.path == path
}

/// 打开 Electron 应用的网页控件辅助功能；第一次打开后界面树要一会儿才长出来
func enableWebAX(_ app: AXUIElement) {
    axSet(app, "AXManualAccessibility", kCFBooleanTrue)
    axSet(app, "AXEnhancedUserInterface", kCFBooleanTrue)
}

/// Convoy --dump-ax <应用路径> <输出文件>：把应用所有窗口的界面树写到文件里
func dumpAX(appPath: String, out: String) {
    guard let app = runningApp(appPath) else {
        try! "not running: \(appPath)\n".write(toFile: out, atomically: true, encoding: .utf8)
        return
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    enableWebAX(ax)
    Thread.sleep(forTimeInterval: 2)
    var lines = ["trusted=\(AXIsProcessTrusted()) pid=\(app.processIdentifier)"]
    if let f: AXUIElement = axGet(ax, kAXFocusedUIElementAttribute) {
        lines.append("focused: \(describe(f))")
    }
    var budget = 30000
    func walk(_ el: AXUIElement, _ depth: Int) {
        budget -= 1
        guard budget > 0, depth < 80 else { return }
        lines.append(String(repeating: "  ", count: depth) + describe(el))
        for c in (axGet(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
    }
    for w in (axGet(ax, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { walk(w, 0) }
    try! lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
}

private func describe(_ el: AXUIElement) -> String {
    let role: String = axGet(el, kAXRoleAttribute) ?? "?"
    let sub: String = axGet(el, kAXSubroleAttribute) ?? ""
    let title: String = axGet(el, kAXTitleAttribute) ?? ""
    let desc: String = axGet(el, kAXDescriptionAttribute) ?? ""
    let val = (axGet(el, kAXValueAttribute) as String?).map { String($0.prefix(40)) } ?? ""
    let ph: String = axGet(el, "AXPlaceholderValue") ?? ""
    let f = axFrame(el)
    let cls = ((axGet(el, "AXDOMClassList") as [String]?) ?? []).joined(separator: ".")
    let help: String = axGet(el, kAXHelpAttribute) ?? ""
    return "\(role)/\(sub) t=\(title.prefix(40)) d=\(desc.prefix(40)) v=\(val) ph=\(ph.prefix(30))\(help.isEmpty ? "" : " h=\(help.prefix(40))")\(cls.isEmpty ? "" : " c=\(cls.prefix(120))") [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
        .replacingOccurrences(of: "\n", with: "⏎")
}

// MARK: 下拉框 / 菜单：在后台按下按钮，收集新冒出来的选项

struct AXNode {
    let el: AXUIElement
    let role: String
    let label: String   // 标题、说明、值里第一个非空的
    let frame: CGRect
}

func axLabel(_ el: AXUIElement) -> String {
    for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let s: String = axGet(el, k), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
    }
    return ""
}

/// 整个应用所有窗口里的节点（含弹出的菜单窗口）
func axNodes(_ app: AXUIElement, budget: Int = 40000) -> [AXNode] {
    var out: [AXNode] = []
    var left = budget
    func walk(_ e: AXUIElement, _ d: Int) {
        left -= 1
        guard left > 0, d < 90 else { return }
        out.append(AXNode(el: e, role: (axGet(e, kAXRoleAttribute) as String?) ?? "", label: axLabel(e), frame: axFrame(e)))
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) }
    }
    for w in (axGet(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { walk(w, 0) }
    return out
}

private let choiceRoles: Set<String> = ["AXMenuItem", "AXMenuButton", "AXRadioButton", "AXCheckBox", "AXButton", "AXPopUpButton", "AXCell", "AXRow", "AXStaticText"]

/// 按下 button，返回新出现的可选项（按出现顺序）。不关闭
func openChoices(_ app: AXUIElement, _ button: AXUIElement) async -> [AXNode] {
    let before = Set(axNodes(app).map { "\($0.role)|\($0.label)|\(Int($0.frame.minX)),\(Int($0.frame.minY))" })
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    await sleep(0.5)
    return axNodes(app).filter { n in
        choiceRoles.contains(n.role) && !n.label.isEmpty && n.frame.height > 0 &&
            !before.contains("\(n.role)|\(n.label)|\(Int(n.frame.minX)),\(Int(n.frame.minY))")
    }
}

/// 关掉弹出的下拉/菜单：对应用发 Esc（只发给这个进程，不抢前台）
func closePopup(_ pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)!
        e.postToPid(pid)
    }
}

func findButton(_ app: AXUIElement, _ match: (AXNode) -> Bool) -> AXNode? {
    axNodes(app).first { ($0.role == "AXPopUpButton" || $0.role == "AXButton") && match($0) }
}



/// 应用没开就在后台启动（不抢前台），等它的主窗口出现。用到哪个应用才启动哪个
func ensureRunning(_ path: String) async throws -> NSRunningApplication {
    if let a = runningApp(path) { return a }
    guard FileManager.default.fileExists(atPath: path) else { throw SendError(message: tr("没装 \((path as NSString).lastPathComponent)", "\((path as NSString).lastPathComponent) isn’t installed")) }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
    for _ in 0..<60 {
        await sleep(0.5)
        guard let a = runningApp(path) else { continue }
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        enableWebAX(ax)
        let wins = ((axGet(ax, kAXWindowsAttribute) as [AXUIElement]?) ?? [])
            .filter { (axGet($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
        if !wins.isEmpty { await sleep(1.5); return a }   // 窗口出来后再等一下界面加载完
    }
    throw SendError(message: tr("\((path as NSString).lastPathComponent) 启动超时", "\((path as NSString).lastPathComponent) took too long to launch"))
}

// MARK: Claude 侧栏的未读蓝点

/// 侧栏元素：每个 Claude 进程记一个，下次直接从它开始读，不用再从窗口一路找下来
private var claudeSidebarCache: [pid_t: AXUIElement] = [:]

private func axClasses(_ el: AXUIElement) -> [String] { (axGet(el, "AXDOMClassList") as [String]?) ?? [] }

/// 侧栏一行：行按钮的名字是“标题 + 状态词”，标题是它下面第一段文字。不是这种按钮就返回 nil
func claudeSidebarRow(_ el: AXUIElement) -> (title: String, unread: Bool)? {
    func firstText(_ el: AXUIElement, _ depth: Int) -> String? {
        guard depth < 4 else { return nil }
        for c in (axGet(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (axGet(c, kAXRoleAttribute) as String?) == "AXStaticText", let v: String = axGet(c, kAXValueAttribute), !v.isEmpty { return v }
            if let v = firstText(c, depth + 1) { return v }
        }
        return nil
    }
    guard let t: String = axGet(el, kAXTitleAttribute), !t.isEmpty, let name = firstText(el, 0), t.hasPrefix(name) else { return nil }
    let rest = t.dropFirst(name.count)
    return (name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), L.claudeUnread.contains { rest.contains($0) })
}

/// Claude 侧栏每一行是不是挂着未读蓝点：行按钮的名字是“标题 + 状态词”，未读时状态词里有“未读回复”。
/// 返回 标题 → 是否未读；窗口关了、侧栏收起来或读不到行时返回 nil（交给会话表推算）。同名的几行不算
func claudeSidebarUnread(_ appPath: String) -> [String: Bool]? {
    guard AXIsProcessTrusted(), let app = runningApp(appPath) else { return nil }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)

    var rows: [String: Bool] = [:]
    var dup = Set<String>()
    var budget = 3000
    func scanRows(_ el: AXUIElement, _ depth: Int) {
        budget -= 1
        guard budget > 0, depth < 30 else { return }
        if (axGet(el, kAXRoleAttribute) as String?) == "AXButton", let r = claudeSidebarRow(el) {
            if rows[r.title] != nil { dup.insert(r.title) }
            rows[r.title] = r.unread
            return
        }
        for c in (axGet(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { scanRows(c, depth + 1) }
    }
    /// 从窗口往下找侧栏：某一层的孩子里有侧栏，就只进侧栏（旁边的对话区很大，不进去）
    func findSidebar(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
        budget -= 1
        guard budget > 0, depth < 25 else { return nil }
        let kids = (axGet(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        if let s = kids.first(where: { axClasses($0).contains("dframe-sidebar") }) { return s }
        for c in kids { if let s = findSidebar(c, depth + 1) { return s } }
        return nil
    }

    var side = claudeSidebarCache[pid]
    if let s = side { scanRows(s, 0) }
    if rows.isEmpty {
        enableWebAX(ax)
        side = nil
        for w in (axGet(ax, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
            if let s = findSidebar(w, 0) { side = s; break }
        }
        claudeSidebarCache[pid] = side
        budget = 3000
        if let s = side { scanRows(s, 0) }
    }
    for d in dup { rows[d] = nil }
    return rows.isEmpty ? nil : rows
}
