import Cocoa
import ApplicationServices

// 往会话里发消息。
// Antigravity：用它自带的本地接口 agentapi send-message。
// Codex / Claude：桌面端没有对外的发消息接口（Codex 还给打开的线程加了写锁），
// 所以模拟手动操作：用链接切到那条会话 → 找到输入框 → 贴进去 → 核对内容 → 回车。消息由原应用自己发出。

struct SendError: Error { let message: String }

private let debugURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AgentDock/send-debug.log")

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: debugURL) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: debugURL)
    }
}

func deliver(_ s: Session, _ text: String) async throws {
    switch s.kind {
    case .antigravity: try await sendAntigravity(s, text)
    case .codex, .claude: try await sendViaUI(s, text)
    }
}

// MARK: Antigravity

private func sendAntigravity(_ s: Session, _ text: String) async throws {
    _ = try await ensureRunning(s.appPath)
    try await Task.detached { try runAgentapi(["send-message", s.rawId, text]) }.value
}

/// 最新的那个 hub 文件里的端口和 csrf 令牌
private func agyHub() throws -> (port: Int, csrf: String) {
    let daemon = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon")
    let notRunning = SendError(message: tr("Antigravity 没在运行", "Antigravity isn’t running"))
    // 端口会随重启变，取最新的那个
    guard let hubs = try? FileManager.default.contentsOfDirectory(at: daemon, includingPropertiesForKeys: [.contentModificationDateKey]),
          let hub = hubs.filter({ $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }).max(by: { mtimeOf($0) < mtimeOf($1) })
    else { throw notRunning }
    let o = try JSONSerialization.jsonObject(with: Data(contentsOf: hub)) as? [String: Any]
    guard let port = (o?["httpPort"] as? Int) ?? (o?["httpPort"] as? String).flatMap({ Int($0) }) else {
        throw SendError(message: tr("Antigravity 本地服务的端口读不到", "Couldn't read the port of Antigravity's local service"))
    }
    return (port, o?["csrfToken"] as? String ?? "")
}

/// Antigravity 本地服务的接口（只在本机 127.0.0.1，带它自己的 csrf 令牌）
func agyRPC(_ method: String, _ body: [String: Any]) async throws -> [String: Any] {
    let hub = try agyHub()
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(hub.port)/exa.language_server_pb.LanguageServerService/\(method)")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    req.setValue(hub.csrf, forHTTPHeaderField: "x-codeium-csrf-token")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await URLSession.shared.data(for: req)
    let r = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    if let msg = r["message"] as? String, r["code"] != nil { throw SendError(message: "Antigravity：\(msg)") }
    return r
}

/// 调 Antigravity 自带的 agentapi（send-message / new-conversation），返回它的输出
@discardableResult
func runAgentapi(_ args: [String]) throws -> String {
    let hub = try agyHub()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server")
    p.arguments = ["agentapi"] + args
    var env = ProcessInfo.processInfo.environment
    env["ANTIGRAVITY_LS_ADDRESS"] = "127.0.0.1:\(hub.port)"
    env["ANTIGRAVITY_CSRF_TOKEN"] = hub.csrf
    p.environment = env
    let out = Pipe()
    p.standardError = out
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    log("agentapi \(args.first ?? "") exit=\(p.terminationStatus) \(text.prefix(300))")
    if p.terminationStatus != 0 { throw SendError(message: tr("Antigravity 拒收：", "Antigravity rejected it: ") + text.prefix(200)) }
    return text
}

private func mtimeOf(_ u: URL) -> Date {
    (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

// MARK: Codex / Claude：模拟手动操作

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

/// 在一个窗口里收集：网页标题（Claude 的会话名在这里）和所有文本区及其 y 坐标
private func scanWindow(_ win: AXUIElement) -> (titles: [String], areas: [(AXUIElement, CGFloat)]) {
    var titles: [String] = [(axGet(win, kAXTitleAttribute) as String?) ?? ""]
    var areas: [(AXUIElement, CGFloat)] = []
    var budget = 30000
    func walk(_ el: AXUIElement, _ depth: Int) {
        budget -= 1
        guard budget > 0, depth < 80 else { return }
        switch axGet(el, kAXRoleAttribute) as String? {
        case "AXWebArea": titles.append((axGet(el, kAXTitleAttribute) as String?) ?? "")
        case kAXTextAreaRole: areas.append((el, axFrame(el).minY))
        default: break
        }
        for c in (axGet(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
    }
    walk(win, 0)
    return (titles, areas)
}

func normalized(_ s: String) -> String {
    s.filter { !$0.isWhitespace }
}

/// 找到“标题对得上这条会话”的窗口，返回它和里面最靠下的文本区（输入框）。对不上就说明没切到目标会话
private func findTarget(_ app: AXUIElement, _ s: Session) -> (win: AXUIElement, composer: AXUIElement)? {
    let key = String(normalized(s.title).prefix(16))
    let wins = ((axGet(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [])
        .filter { (axGet($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
    for w in wins {
        let (titles, areas) = scanWindow(w)
        guard titles.contains(where: { normalized($0).contains(key) }),
              let c = areas.max(by: { $0.1 < $1.1 })?.0 else { continue }
        return (w, c)
    }
    return nil
}

/// 输入框是空的：值为空，或者只是占位文字（Codex 空输入框读出来就是占位文字）
func composerEmpty(_ el: AXUIElement) -> Bool {
    let v = normalized((axGet(el, kAXValueAttribute) as String?) ?? "")
    let hints = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
        .map { normalized((axGet(el, $0) as String?) ?? "") }
    return v.isEmpty || hints.contains(v)
}

private func key(_ code: CGKeyCode, cmd: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        if cmd { e.flags = .maskCommand }
        e.post(tap: .cghidEventTap)
    }
}

/// 全程在后台完成，不切前台：
/// 1. 窗口已经是这条会话就不动，否则按侧栏里这条会话的按钮；侧栏里找不到才退回用直达链接（会切前台一下）
/// 2. 输入框必须是空的（不碰你没发的草稿）
/// 3. 直接把文字写进输入框，核对一致
/// 4. 按输入框旁的“发送”按钮；没有发送按钮时才退回模拟回车（要切前台）
/// dryRun：走到第 3 步后清掉自己写的内容，不发送（测试用）
func sendViaUI(_ s: Session, _ text: String, dryRun: Bool = false) async throws {
    guard AXIsProcessTrusted() else {
        throw SendError(message: tr("Convoy 还没有“辅助功能”权限，没法替你操作 \(s.app)。到 系统设置 → 隐私与安全性 → 辅助功能 里打开 Convoy", "Convoy doesn’t have Accessibility permission yet, so it can’t operate \(s.app) for you. Turn on Convoy in System Settings → Privacy & Security → Accessibility."))
    }
    let app = try await ensureRunning(s.appPath)
    let me = NSRunningApplication.current
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    // Electron 应用默认不对外暴露网页里的控件，打开这个开关才能找到输入框
    enableWebAX(ax)

    // 1. 切到那条会话
    var target = await navigateQuietly(ax, s)
    var stoleFocus = false
    if target == nil, let link = s.link {
        log("\(s.app) \(s.rawId): 侧栏里没找到，改用直达链接")
        stoleFocus = true
        _ = try await NSWorkspace.shared.open([link], withApplicationAt: URL(fileURLWithPath: s.appPath),
                                              configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<20 {
            await sleep(0.3)
            target = findTarget(ax, s)
            if target != nil { break }
        }
    }
    defer { if stoleFocus { me.activate() } }
    // 刚切过来的会话，输入框可能还在重新渲染：等一下再重新找一次，拿最新的输入框
    if target != nil {
        await sleep(0.4)
        target = findTarget(ax, s) ?? target
    }
    guard var (_, composer) = target else {
        log("\(s.app) \(s.rawId): 没找到标题含「\(s.title)」的窗口或输入框")
        throw SendError(message: tr("在 \(s.app) 里没切到「\(s.title)」这条会话（或没找到输入框），消息没发", "Couldn’t switch to the session “\(s.title)” in \(s.app) (or couldn’t find its input box). The message wasn’t sent."))
    }

    // 2. 输入框必须是空的。例外：里面正好就是这次要发的内容（上次写进去但没发出去的残留），直接接着发
    let leftover = !composerEmpty(composer) && normalized(composerValue(composer)) == normalized(text)
    guard composerEmpty(composer) || leftover else {
        throw SendError(message: tr("\(s.app) 里这条会话的输入框有没发的草稿，为了不覆盖它，这次没发。清掉草稿再试", "This session’s input box in \(s.app) has an unsent draft. To avoid overwriting it, nothing was sent. Clear the draft and try again."))
    }

    // 3. 写入并核对。界面刷新有延迟，1.5 秒内反复读；每次都重新找输入框，防止拿着切换前的旧元素
    if !leftover { AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFString) }
    var written = ""
    for _ in 0..<10 {
        await sleep(0.15)
        if let t = findTarget(ax, s) { composer = t.composer }
        written = composerValue(composer)
        if normalized(written) == normalized(text) { break }
    }
    log("\(s.app) \(s.rawId): written = \(written.prefix(80))\(leftover ? "（沿用输入框里上次没发出去的内容）" : "")")
    guard normalized(written) == normalized(text) else {
        // 后台写入没对上（原应用改版等）：退回备用办法——切前台、借剪贴板粘贴、回车。会闪一下，但能发出去
        if !dryRun, composerEmpty(composer) {
            log("\(s.app) \(s.rawId): 后台写入没对上，改用剪贴板粘贴")
            stoleFocus = true
            try await pasteAndSend(app, ax, s, text)
            return
        }
        throw SendError(message: tr("写进 \(s.app) 输入框的内容和要发的不一致，没有发送。请到 \(s.app) 里看一眼输入框", "What got written into the \(s.app) input box doesn’t match the message, so it wasn’t sent. Please check the input box in \(s.app)."))
    }
    if dryRun {
        log("\(s.app) \(s.rawId): buttons near composer = \(buttonsNear(composer).map { "\(axLabel($0))|\((axGet($0, kAXEnabledAttribute) as Bool?) ?? false)" })")
        AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, "" as CFString)
        await sleep(0.3)
        log("\(s.app) \(s.rawId): dry run ok, cleared=\(composerEmpty(composer))")
        return
    }

    // 4. 发送
    if let btn = sendButton(composer), (axGet(btn, kAXEnabledAttribute) as Bool?) ?? false {
        AXUIElementPerformAction(btn, kAXPressAction as CFString)
        log("\(s.app) \(s.rawId): pressed 发送")
    } else {
        log("\(s.app) \(s.rawId): 没有可用的发送按钮，改为切前台按回车")
        stoleFocus = true
        app.activate()
        await sleep(0.3)
        axSet(composer, kAXFocusedAttribute, kCFBooleanTrue)
        await sleep(0.1)
        key(36)
    }
    await sleep(0.6)
    log("\(s.app) \(s.rawId): sent, composer empty after = \(composerEmpty(composer))")
}

/// 备用发送：切到原应用前台，聚焦输入框，借剪贴板粘贴，核对后回车。剪贴板用完恢复
private func pasteAndSend(_ app: NSRunningApplication, _ ax: AXUIElement, _ s: Session, _ text: String) async throws {
    app.activate()
    await sleep(0.4)
    guard let (_, c) = findTarget(ax, s), composerEmpty(c) else { throw SendError(message: tr("备用发送：\(s.app) 的输入框不是空的，没发", "Fallback send: the \(s.app) input box isn’t empty, so nothing was sent.")) }
    axSet(c, kAXFocusedAttribute, kCFBooleanTrue)
    await sleep(0.15)
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item in
        item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
    } ?? []
    pb.clearContents()
    pb.setString(text, forType: .string)
    key(9, cmd: true) // ⌘V
    await sleep(0.5)
    pb.clearContents()
    pb.writeObjects(saved.map { d in
        let item = NSPasteboardItem()
        for (t, v) in d { item.setData(v, forType: t) }
        return item
    })
    var ok = false
    for _ in 0..<8 {
        if let t = findTarget(ax, s), normalized(composerValue(t.composer)) == normalized(text) { ok = true; break }
        await sleep(0.15)
    }
    guard ok else { throw SendError(message: tr("备用发送：粘贴进 \(s.app) 的内容对不上，没有回车", "Fallback send: the text pasted into \(s.app) doesn’t match, so Return wasn’t pressed.")) }
    key(36) // 回车
    log("\(s.app) \(s.rawId): sent via paste fallback")
}

// MARK: 不切前台：侧栏点选切会话、直接写入输入框、按发送按钮

/// 在应用窗口里找标题对得上这条会话的侧栏按钮（Codex 标题就是会话名；Claude 是“会话名 + 运行中/分叉来源”）
func sidebarButton(_ app: AXUIElement, _ s: Session) -> AXUIElement? {
    let wins = ((axGet(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [])
        .filter { (axGet($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
    var best: AXUIElement?
    var budget = 30000
    func walk(_ e: AXUIElement, _ depth: Int) {
        budget -= 1
        guard budget > 0, depth < 80, best == nil else { return }
        let role: String = axGet(e, kAXRoleAttribute) ?? ""
        if role == kAXButtonRole {
            let t: String = axGet(e, kAXTitleAttribute) ?? ""
            if t == s.title || t.hasPrefix(s.title + " ") { best = e; return }
        }
        // Antigravity 侧栏里的会话是链接，名字在说明里
        if role == "AXLink", (axGet(e, kAXDescriptionAttribute) as String?) == s.title { best = e; return }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
    }
    for w in wins { walk(w, 0) }
    return best
}

/// 输入框附近的按钮：往上 6 层的容器里找
func buttonsNear(_ el: AXUIElement) -> [AXUIElement] {
    var box = el
    for _ in 0..<6 { if let p: AXUIElement = axGet(box, kAXParentAttribute) { box = p } }
    var out: [AXUIElement] = []
    var budget = 3000
    func walk(_ e: AXUIElement) {
        budget -= 1
        guard budget > 0 else { return }
        if (axGet(e, kAXRoleAttribute) as String?) == kAXButtonRole { out.append(e) }
        for c in (axGet(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c) }
    }
    walk(box)
    return out
}

func sendButton(_ composer: AXUIElement) -> AXUIElement? {
    buttonsNear(composer).first { b in
        L.any((axGet(b, kAXTitleAttribute) as String?) ?? "", L.send) || L.any((axGet(b, kAXDescriptionAttribute) as String?) ?? "", L.send)
    }
}

func composerValue(_ c: AXUIElement) -> String { (axGet(c, kAXValueAttribute) as String?) ?? "" }

/// 后台切到这条会话：已经是当前会话就不动；否则按侧栏按钮。返回窗口和输入框
func navigateQuietly(_ ax: AXUIElement, _ s: Session) async -> (win: AXUIElement, composer: AXUIElement)? {
    if demoMode { return nil }   // 演示模式不碰真实的原应用
    if let t = findTarget(ax, s) { return t }
    guard let b = sidebarButton(ax, s) else { return nil }
    AXUIElementPerformAction(b, kAXPressAction as CFString)
    for _ in 0..<20 {
        await sleep(0.25)
        if let t = findTarget(ax, s) { return t }
    }
    return nil
}

func findTargetPublic(_ app: AXUIElement, _ s: Session) -> (win: AXUIElement, composer: AXUIElement)? { findTarget(app, s) }
