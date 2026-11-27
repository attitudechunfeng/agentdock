import Cocoa
import ApplicationServices
import WebKit

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "全部", codex = "Codex", claude = "Claude", antigravity = "Antigravity"
    var id: String { rawValue }
    /// 显示文字（rawValue 是 id，不翻译）
    var label: String { self == .all ? tr("全部", "All") : rawValue }
    func match(_ s: Session) -> Bool {
        switch self {
        case .all: return true
        case .codex: return s.kind == .codex
        case .claude: return s.kind == .claude
        case .antigravity: return s.kind == .antigravity
        }
    }
}

enum ListMode: String, CaseIterable, Identifiable {
    case time = "按时间", folder = "按目录", project = "按项目"
    var id: String { rawValue }
    /// 显示文字（rawValue 是 id，不翻译）
    var label: String {
        switch self {
        case .time: return tr("按时间", "By time")
        case .folder: return tr("按目录", "By folder")
        case .project: return tr("按项目", "By project")
        }
    }
}

/// 新建会话时右边显示的草稿：选好了应用和目录，等第一条消息
struct Draft: Equatable {
    let kind: Kind
    let app: String
    let appPath: String
    let folder: String
}

/// 本机装了哪些 agent 应用（按安装位置找，没装的不列）
let newSessionApps: [(kind: Kind, app: String, path: String)] = (claudeApps.map { (Kind.claude, $0.label, $0.path) } + [
    (.codex, "Codex", codexAppPath),
    (.antigravity, "Antigravity", "/Applications/Antigravity.app"),
]).filter { FileManager.default.fileExists(atPath: $0.path) }

/// 首页环境检查里的一行
struct AgentStatus: Identifiable, Equatable {
    var id: String { app }
    let app: String
    let path: String
    let installed: Bool
    let running: Bool
    let sessions: Int
}

/// 任务在跑时发的消息先在这里排队；会话空闲后按顺序发出
struct Queued: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let text: String        // 已经带上附件路径的完整消息
    let created: Date
    var sending = false
}

/// 会话列表：每 2 秒扫一次
/// 诊断模式下不弹授权、不读用量
var headless = false

final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedId: String? {
        didSet {
            if selectedId != nil { draft = nil; board = nil }
            if let s = selected { markSeen(s); explicitUnread.remove(s.id); markReadNative(s); log("select \(s.title)") }
            chat.select(selected)
        }
    }

    // MARK: 未读：会话在你上次看过之后又有了新输出

    /// 每条会话“看过的最新输出时间”，存在本地，重启后还在
    @Published var seen: [String: Date] = [:]
    private let seenURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentDock/seen.json")

    func outputTime(_ s: Session) -> Date { s.outputAt ?? s.updated }

    /// 未读以原应用为准：原应用标着未读、没在跑、也不是正在看的这条。
    /// 例外：你在 Convoy 里看过最新输出、只是原应用还没来得及记成已读，就不算未读；
    /// 但如果是你在原应用里手动“标为未读”（没有新输出、原应用却从已读变成未读），照样算未读
    func isUnread(_ s: Session) -> Bool {
        guard !s.running, s.id != selectedId, s.nativeUnread else { return false }
        if explicitUnread.contains(s.id) { return true }
        return outputTime(s).timeIntervalSince(seen[s.id] ?? .distantPast) > 1
    }

    private var explicitUnread = Set<String>()
    private var prevNative: [String: Bool] = [:]
    private var markedRead: [String: Date] = [:]

    /// 在 Convoy 里看了：替你在原应用里也标成已读（原应用标着未读时才做）
    private func markReadNative(_ s: Session) {
        guard !demoMode, s.nativeUnread, !s.running else { return }
        let t = outputTime(s)
        if let m = markedRead[s.id], m >= t { return }   // 这次输出已经标过
        markedRead[s.id] = t
        Task { @MainActor in
            switch s.kind {
            case .antigravity:
                // 官方接口：写入查看时间，清掉“标为未读”
                let now = ISO8601DateFormatter().string(from: Date())
                _ = try? await agyRPC("UpdateConversationAnnotations", ["cascadeIds": [s.rawId],
                                                                       "annotations": ["lastUserViewTime": now, "markedAsUnread": false],
                                                                       "mergeAnnotations": true])
            case .claude, .codex:
                // 没有接口：在后台把原应用切到这条会话，原应用自己记成已读
                guard AXIsProcessTrusted(), let app = runningApp(s.appPath) else { return }
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                enableWebAX(ax)
                _ = await navigateQuietly(ax, s)
            }
            log("mark read in \(s.app): \(s.title)")
        }
    }

    private func markSeen(_ s: Session) {
        let t = outputTime(s)
        if (seen[s.id] ?? .distantPast) < t { seen[s.id] = t; saveSeen() }
    }

    private func saveSeen() {
        if demoMode { return }
        let d = seen.mapValues { $0.timeIntervalSince1970 }
        try? JSONSerialization.data(withJSONObject: d).write(to: seenURL)
    }

    /// 正在看的那条随时记成看过；原应用里手动“标为未读”的认出来
    private func syncSeen(_ list: [Session]) {
        var changed = false
        for s in list {
            let was = prevNative[s.id]
            prevNative[s.id] = s.nativeUnread
            if let was, was != s.nativeUnread { log("native \(s.nativeUnread ? "unread" : "read") in \(s.app): \(s.title)") }
            if s.id == selectedId {
                let t = outputTime(s)
                if (seen[s.id] ?? .distantPast) < t { seen[s.id] = t; changed = true }
                markReadNative(s)
                continue
            }
            if !s.nativeUnread { explicitUnread.remove(s.id) }
            // 原应用从已读变成未读，但没有新输出：是你在原应用里手动标的
            else if was == false, outputTime(s) <= (seen[s.id] ?? .distantPast) { explicitUnread.insert(s.id) }
        }
        if changed { saveSeen() }
    }
    @Published var draft: Draft? { didSet { if let d = draft { selectedId = nil; board = nil; chat.startDraft(d) } } }
    /// 右边显示看板：空字符串是总览，否则是项目 id
    @Published var board: String? { didSet { if board != nil { if selectedId != nil { selectedId = nil }; if draft != nil { draft = nil } } } }
    let boards = BoardStore()
    /// 上一遍扫描时在跑的会话：这一遍停了，就是一轮结束
    private var wasRunning = Set<String>()
    private var caughtUp = false
    @Published var filter: AppFilter = .all
    @Published var mode: ListMode = .time
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var hits: [SearchHit] = []
    @Published var searching = false
    private var searchGen = 0
    private let searchQueue = DispatchQueue(label: "agentdock.search", qos: .utility)
    private var warmed = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var toast: String?
    @Published var agents: [AgentStatus] = []
    @Published var checks: [AppCheck] = []
    @Published var checking = false
    @Published var checkTime: Date?
    private var checkedVersions: [String: String] = [:]
    @Published var usage: [UsageApp] = []
    @Published var usageTime: Date?
    @Published var usageLoading = false
    @Published var queue: [String: [Queued]] = [:] { didSet { saveQueue(); chat.pushQueue() } }
    /// 刚发出去、还没看到它开始跑的会话：这段时间不发下一条，免得连发
    private var awaitingRun: [String: Date] = [:]
    private let queueURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentDock/queue.json")
    let chat = ChatController()
    private let scanQueue = DispatchQueue(label: "agentdock.scan") // 串行：扫描里有缓存

    var selected: Session? { sessions.first { $0.id == selectedId } }

    var visible: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { filter.match($0) && (q.isEmpty || $0.title.lowercased().contains(q) || $0.project.lowercased().contains(q)) }
    }

    /// 按目录分组：目录按里面最近一次活动排序
    var folders: [(path: String, sessions: [Session])] {
        let g = Dictionary(grouping: visible) { $0.cwd.isEmpty ? tr("（无目录）", "(No folder)") : $0.cwd }
        return g.map { ($0.key, $0.value) }.sorted { ($0.sessions.first?.updated ?? .distantPast) > ($1.sessions.first?.updated ?? .distantPast) }
    }

    init() {
        chat.model = self
        if demoMode { demoModelRef = self }
        boards.lookup = { [weak self] id in self?.sessions.first { $0.id == id } }
        boards.allSessions = { [weak self] in self?.sessions ?? [] }
        if let d = try? Data(contentsOf: seenURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] {
            seen = o.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if let d = try? Data(contentsOf: queueURL) {
            let dec = JSONDecoder()
            queue = ((try? dec.decode([String: [Queued]].self, from: d)) ?? [:]).mapValues { $0.map { var q = $0; q.sending = false; return q } }
        }
        // 没授权时让系统弹出授权请求，按当前签名登记
        trusted = headless ? AXIsProcessTrusted() : AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if !headless { log("launch \(Bundle.main.bundlePath) trusted=\(trusted)") }
        refresh()
        // 有变化才刷新：会话记录、状态库的文件一变，或 Claude 侧栏某一行变了（未读、在跑）
        for r in watchRoots() {
            watchers.append(FileWatcher(paths: [r.dir], accept: r.accept) { [weak self] in self?.scheduleRefresh() })
        }
        ClaudeSidebar.shared.onChange = { [weak self] in self?.scheduleRefresh() }
        // 切换语言：会话列表里的模型名、权限名是扫描时生成的，重扫一遍
        NotificationCenter.default.addObserver(forName: .languageChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        if !demoMode { ClaudeSidebar.shared.start(claudeApps.map(\.path)) }
        // 原应用退出：会话都不在跑了，马上刷新
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let p = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path ?? ""
            if checkApps.contains(where: { $0.path == p }) { self?.scheduleRefresh() }
        }
        // 兜底：只剩“跑了很久没动静、按中断算”这种不会有任何通知的情况，分钟级就够了
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            ClaudeSidebar.shared.attachAll()
            self?.refresh()
        }
        if !headless {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refreshUsage() }
            // 自检：启动 10 秒后一次；之后原应用每次启动（更新后必然重启）时看版本，变了就再查一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.runSelfCheck() }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let p = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path ?? ""
                guard let self, checkApps.contains(where: { $0.path == p }) else { return }
                // 等它窗口和界面起来再查
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    let now = Dictionary(uniqueKeysWithValues: checkApps.map { ($0.name, appVersion($0.path)) })
                    if now != self.checkedVersions { self.runSelfCheck() }
                }
            }
        }
        // Antigravity 的全局默认权限预设：启动时读一次；之后只会在 Antigravity 里改，所以每次你从它切走、它启动时再读
        refreshAgyPreset()
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path == "/Applications/Antigravity.app" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + (name == NSWorkspace.didLaunchApplicationNotification ? 5 : 0.5)) { self?.refreshAgyPreset() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refreshUsage() }
    }

    private var watchers: [FileWatcher] = []
    private var scanning = false, rescan = false, lastScan = Date.distantPast

    /// 文件或侧栏变了：马上扫一遍；正在扫就等这遍扫完再补一遍。两遍之间至少隔 1 秒（正在跑的会话一直在写记录）
    func scheduleRefresh() {
        if scanning { rescan = true; return }
        scanning = true
        let wait = max(0, 1 - Date().timeIntervalSince(lastScan))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.refresh() }
    }

    func refresh() {
        let t = AXIsProcessTrusted()
        if t != trusted { trusted = t; if t { ClaudeSidebar.shared.attachAll() } }
        scanQueue.async {
            let s = scanSessions()
            DispatchQueue.main.async {
                self.lastScan = Date()
                self.scanning = false
                if self.rescan { self.rescan = false; self.scheduleRefresh() }
                self.watchPids(s)
                self.pickNewest(s)
                self.noteTurns(s)
                if s != self.sessions { self.sessions = s }
                self.syncSeen(s)
                if !self.warmed {
                    self.warmed = true
                    self.searchQueue.async { warmSearch(s) }
                }
                let st = (claudeApps.map { ($0.label, $0.path) } +
                          [("Codex", codexAppPath), ("Antigravity", "/Applications/Antigravity.app")]).compactMap { name, path -> AgentStatus? in
                    let installed = FileManager.default.fileExists(atPath: path)
                    // Claude 没装就不列
                    if !installed && name.hasPrefix("Claude") { return nil }
                    return AgentStatus(app: name, path: path, installed: installed, running: runningApp(path) != nil,
                                       sessions: s.filter { $0.app == name || ($0.kind == .codex && name == "Codex") }.count)
                }
                if st != self.agents { self.agents = st }
                self.chat.update(self.selected)
                self.pump()
            }
        }
    }

    /// 一轮回复结束（在跑 → 停下）：交给看板增量更新
    private func noteTurns(_ list: [Session]) {
        let now = Set(list.filter(\.running).map(\.id))
        for s in list where wasRunning.contains(s.id) && !now.contains(s.id) { boards.turnEnded(s) }
        wasRunning = now
        if !caughtUp && !headless { caughtUp = true; boards.catchUp(list); boards.writeContextFiles() }
    }

    func openInApp(_ s: Session) {
        guard let link = s.link else {
            runningApp(s.appPath)?.activate()
            return
        }
        NSWorkspace.shared.open([link], withApplicationAt: URL(fileURLWithPath: s.appPath),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: 排队

    private func saveQueue() {
        if demoMode { return }
        try? FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(queue).write(to: queueURL)
    }

    func enqueue(_ s: Session, _ text: String) {
        queue[s.id, default: []].append(Queued(text: text, created: Date()))
    }

    func unqueue(_ sid: String, _ qid: String) {
        queue[sid]?.removeAll { $0.id == qid && !$0.sending }
        if queue[sid]?.isEmpty == true { queue[sid] = nil }
    }

    /// 排队的某条改成立即发送：任务还在跑，就等于插话引导
    func sendNow(_ sid: String, _ qid: String) async throws {
        guard let s = sessions.first(where: { $0.id == sid }), let i = queue[sid]?.firstIndex(where: { $0.id == qid }) else { return }
        queue[sid]![i].sending = true
        do {
            try await deliver(s, queue[sid]![i].text)
            unqueueSent(sid, qid)
            awaitingRun[sid] = Date()
        } catch {
            if let j = queue[sid]?.firstIndex(where: { $0.id == qid }) { queue[sid]![j].sending = false }
            throw error
        }
    }

    private func unqueueSent(_ sid: String, _ qid: String) {
        queue[sid]?.removeAll { $0.id == qid }
        if queue[sid]?.isEmpty == true { queue[sid] = nil }
    }

    /// 每次扫描后：空闲下来的会话发出队首那条
    private func pump() {
        for (sid, items) in queue {
            guard let first = items.first, !first.sending,
                  let s = sessions.first(where: { $0.id == sid }) else { continue }
            if s.running { awaitingRun[sid] = nil; continue }
            // 刚发出去的那条还没开始跑（扫描有延迟），等它跑起来再说；超过 60 秒没跑就不等了
            if let t = awaitingRun[sid], Date().timeIntervalSince(t) < 60 { continue }
            queue[sid]![0].sending = true
            Task { @MainActor in
                do {
                    try await deliver(s, first.text)
                    unqueueSent(sid, first.id)
                    awaitingRun[sid] = Date()
                    say(tr("已发出「\(s.title)」排队的消息", "Sent the queued message in “\(s.title)”"))
                } catch let e as SendError {
                    if let j = queue[sid]?.firstIndex(where: { $0.id == first.id }) { queue[sid]![j].sending = false }
                    awaitingRun[sid] = Date() // 失败也先缓一缓，别每 2 秒重试一次
                    say(tr("排队的消息没发出去：\(e.message)", "Couldn’t send the queued message: \(e.message)"))
                } catch {}
            }
        }
    }

    // MARK: 正文搜索

    /// 输入停 0.3 秒再搜；新的输入会让旧的结果作废
    private func scheduleSearch() {
        searchGen += 1
        let gen = searchGen, q = query, list = sessions
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { hits = []; searching = false; return }
        searching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard gen == self.searchGen else { return }
            self.searchQueue.async {
                let r = searchSessions(list, q)
                DispatchQueue.main.async {
                    guard gen == self.searchGen else { return }
                    self.hits = r
                    self.searching = false
                }
            }
        }
    }

    /// 打开命中的会话并滚到那条消息
    func openHit(_ h: SearchHit) {
        selectedId = h.sessionId
        chat.focus(h.itemId)
    }

    func say(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.toast == text { self.toast = nil } }
    }

    func act(_ s: Session, _ a: SessionAction, newName: String = "") {
        let names: [SessionAction: String] = [.rename: "重命名", .fork: "分叉", .pin: "置顶", .archive: "归档", .delete: "删除"]
        let doing: [SessionAction: String] = [.rename: "Renaming", .fork: "Forking", .pin: "Pinning", .archive: "Archiving", .delete: "Deleting"]
        let did: [SessionAction: String] = [.rename: "Renamed", .fork: "Forked", .pin: "Pinned", .archive: "Archived", .delete: "Deleted"]
        say(tr("正在\(names[a]!)「\(s.title)」…", "\(doing[a]!) “\(s.title)”…"))
        Task { @MainActor in
            do {
                try await runSessionAction(s, a, newName: newName)
                say(tr("已\(names[a]!)「\(s.title)」", "\(did[a]!) “\(s.title)”"))
                refresh()
            } catch let e as SendError {
                say(e.message)
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    func refreshAgyPreset() {
        Task {
            guard let r = try? await agyRPC("GetPermissionSettings", [:]), let p = r["globalPreset"] as? String else { return }
            scanQueue.async { agyGlobalPreset = p }
        }
    }

    func runSelfCheck() {
        guard !checking else { return }
        checking = true
        checkedVersions = Dictionary(uniqueKeysWithValues: checkApps.map { ($0.name, appVersion($0.path)) })
        let list = sessions
        Task { @MainActor in
            checks = await selfCheck(list)
            checking = false
            checkTime = Date()
            let bad = checks.filter { !$0.failed.isEmpty }
            if !bad.isEmpty {
                say(isEnglish
                    ? "Self-check: " + bad.map { "\($0.app): \($0.failed.joined(separator: ", ")) not working" }.joined(separator: "; ") + ". See the home page for details."
                    : "自检：" + bad.map { "\($0.app) 的「\($0.failed.joined(separator: "、"))」不可用" }.joined(separator: "；") + "。详情看首页")
            }
            log("selfcheck: " + checks.map { "\($0.app) \($0.version) " + $0.items.map { "\($0.name)=\($0.ok ? "ok" : "FAIL")" }.joined(separator: " ") }.joined(separator: " | "))
        }
    }

    func refreshUsage() {
        guard !usageLoading else { return }
        usageLoading = true
        Task { @MainActor in
            usage = await readUsage()
            usageTime = Date()
            usageLoading = false
        }
    }

    /// 新建会话发出去后，等它出现在列表里就选中：每次列表刷新（新会话的文件一写出来就会刷新）时看一眼，20 秒没出现就算了
    private var newest: (kind: Kind, after: Date, until: Date, then: ((Session) -> Void)?)?
    func selectNewest(kind: Kind, after: Date, then: ((Session) -> Void)? = nil) {
        newest = (kind, after, Date().addingTimeInterval(20), then)
        pickNewest(sessions)
    }

    private func pickNewest(_ list: [Session]) {
        guard let n = newest else { return }
        if Date() > n.until { newest = nil; return }
        guard let s = list.first(where: { $0.kind == n.kind && $0.updated >= n.after.addingTimeInterval(-2) }) else { return }
        newest = nil
        selectedId = s.id
        n.then?(s)
    }

    /// Claude 会话的进程：每个挂一个“进程退出”通知，进程崩了、被杀了（来不及写状态文件）也能马上知道
    private var pidWatch: [Int32: DispatchSourceProcess] = [:]
    private func watchPids(_ list: [Session]) {
        let pids = Set(list.compactMap(\.pid))
        for (p, src) in pidWatch where !pids.contains(p) { src.cancel(); pidWatch[p] = nil }
        for p in pids where pidWatch[p] == nil {
            let src = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: .main)
            src.setEventHandler { [weak self] in
                self?.pidWatch[p]?.cancel()
                self?.pidWatch[p] = nil
                self?.scheduleRefresh()
            }
            src.resume()
            pidWatch[p] = src
        }
    }
}

/// 右侧详情：一个网页视图，Swift 把会话头部、条目、运行状态推给页面；页面把发送、停止、下拉选择等操作发回来
final class ChatController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var model: Model?
    let web: WKWebView
    private var ready = false
    private var session: Session?
    private var draft: Draft?
    private var lastSig = ""            // 记录文件 + 后台任务输出文件的修改时间，变了才重读
    private var taskFiles: [String] = []
    private var lastSent = 0            // 上次推给页面的内容的哈希，一样就不推
    private var reading = false
    private var limit = 150             // 默认只推最近 150 条，页面上点“显示更早”再放开
    private var lastHeader = ""
    private var menu: OpenMenu?
    private let queue = DispatchQueue(label: "agentdock.chat")
    /// 选文件面板：系统的选文件界面在独立进程里，第一次打开要起服务、很慢，所以启动后就先建好
    private lazy var openPanel: NSOpenPanel = {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = tr("选择要附上的文件或图片", "Choose files or images to attach")
        return p
    }()

    override init() {
        let cfg = WKWebViewConfiguration()
        web = ClickThroughWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "ad")
        // 告诉聊天页用哪种语言（页面里用 tr('中文','English') 取文案）
        cfg.userContentController.addUserScript(WKUserScript(source: "window.AD_LANG = '\(appLang)';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 切换语言：换掉注入的语言、重新加载聊天页（加载完会把当前会话再推一遍）
        NotificationCenter.default.addObserver(forName: .languageChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let uc = self.web.configuration.userContentController
            uc.removeAllUserScripts()
            uc.addUserScript(WKUserScript(source: "window.AD_LANG = '\(appLang)';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            self.ready = false
            self.web.reload()
        }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        let res = Bundle.main.resourceURL!
        web.loadFileURL(res.appendingPathComponent("chat.html"), allowingReadAccessTo: res)
        // 不定时轮询：对话记录、后台任务输出文件一变就重读（见 rewatch）；批准卡片在状态变了、记录变了时去找
    }

    // MARK: 文件变动通知：盯住正在看的这条会话的记录文件和还在跑的后台任务输出文件

    private var fileWatch: FileWatcher?
    private var watched: [String] = []
    private var dirty = false   // 正在读时又变了：读完再读一遍

    private func rewatch() {
        guard let f = session?.transcript else { fileWatch = nil; watched = []; return }
        // 系统通知里给的是真实路径（/tmp 是 /private/tmp 的链接），比较前先解开链接
        let paths = ([f.path] + taskFiles).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard paths != watched else { return }
        watched = paths
        let want = Set(paths)
        let dirs = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent }))
        fileWatch = FileWatcher(paths: dirs, latency: 0.15, accept: { want.contains($0) }) { [weak self] in
            self?.reload()
            self?.checkApproval()
        }
    }

    /// 只有 Antigravity 在跑时才需要定时取：它正在生成的那一步只在它的本地服务里，没有文件也没有推送
    private var liveTimer: Timer?
    private func updateLiveTimer() {
        let want = ready && session?.kind == .antigravity && session?.running == true
        if want, liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollLive() }
        } else if !want, liveTimer != nil {
            liveTimer?.invalidate(); liveTimer = nil
            pollLive()   // 清掉页面上残留的预览
        }
    }

    func select(_ s: Session?) {
        guard s != nil || draft == nil else { return }
        session = s
        draft = nil
        lastSig = ""; lastSent = 0; taskFiles = []; limit = 150; agySteps = 0; lastLive = ""; approval = nil; lastApproval = ""; ask = nil
        lastHeader = ""
        lastState = s.map { "\($0.running)\($0.waiting)\($0.asking)" } ?? ""
        pushHeader()
        rewatch()
        reload()
        checkApproval()
        updateLiveTimer()
    }

    private var pendingFocus: String?

    // MARK: Antigravity 实时预览：它写进记录前，从本地服务取正在生成的那一步

    private var agySteps = 0
    private var liveBusy = false
    private var lastLive = ""

    // MARK: 批准请求

    private var approval: Approval?
    private var ask: PendingAsk?   // Claude 在等你回答的问题
    private var approvalBusy = false
    private var approvalGen = 0
    private var lastLook = Date.distantPast
    private var lastState = ""
    private var lastApproval = ""

    /// 找批准卡片：只在有变化时找——进入会话、会话状态变了（Claude 进程变成 waiting、开始或停止跑）、记录文件变了。
    /// 界面比文件慢半拍，所以每次触发后再补看两次。Claude 在等时会切到那条会话找卡片；Codex 只在窗口正显示这条会话时看；
    /// Antigravity 从本地服务找 WAITING 的步骤
    private func checkApproval() {
        guard ready, let s = session else { return }
        let need = s.kind == .claude ? s.waiting && !s.asking : s.running
        guard need else { approvalGen += 1; setApproval(nil); return }
        approvalGen += 1
        let g = approvalGen
        for d in [0.0, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.approvalGen == g else { return }
                self.lookApproval()
            }
        }
    }

    private func lookApproval() {
        guard ready, !approvalBusy, let s = session else { return }
        // Claude 在等回答问题时不用找批准卡片：问题卡片直接从记录里读
        let need = s.kind == .claude ? s.waiting && !s.asking : s.running
        guard need else { setApproval(nil); return }
        // Codex 只能扫界面，开销大一些：记录写得很勤时也至少隔 2 秒
        if Date().timeIntervalSince(lastLook) < (s.kind == .codex ? 2 : 0.8) { return }
        lastLook = Date()
        approvalBusy = true
        Task { @MainActor in
            defer { approvalBusy = false }
            let a: Approval?
            switch s.kind {
            case .antigravity: a = await agyApproval(s, offset: max(0, agySteps - 3))
            case .claude: a = await findApproval(s, navigate: true)
            case .codex: a = await findApproval(s, navigate: false)
            }
            guard session?.id == s.id else { return }
            setApproval(a)
        }
    }

    private func setApproval(_ a: Approval?) {
        approval = a
        let payload = a.map { jsonString(["title": $0.title, "detail": $0.detail, "labels": $0.labels,
                                          "approve": $0.labels.map { L.item($0, L.approve) || $0.hasPrefix("批准") }]) } ?? "null"
        guard payload != lastApproval else { return }
        lastApproval = payload
        js("AD.approval(\(payload))")
    }

    private func pollLive() {
        guard ready, !liveBusy, let s = session, s.kind == .antigravity else { return }
        guard s.running else {
            if !lastLive.isEmpty { lastLive = ""; js("AD.live(null)") }
            return
        }
        liveBusy = true
        let offset = max(0, agySteps - 2)
        Task { @MainActor in
            defer { liveBusy = false }
            guard let r = try? await agyRPC("GetCascadeTrajectorySteps", ["cascadeId": s.rawId, "stepOffset": offset]),
                  session?.id == s.id else { return }
            let steps = (r["steps"] as? [[String: Any]]) ?? []
            // 最后一个还没完成的模型回复步骤：里面是已经生成出来的那部分文字
            var text = "", thinking = ""
            for st in steps.reversed() where (st["type"] as? String)?.hasSuffix("PLANNER_RESPONSE") == true {
                guard (st["status"] as? String) != "CORTEX_STEP_STATUS_DONE" else { break }
                let pr = st["plannerResponse"] as? [String: Any] ?? [:]
                text = pr["modifiedResponse"] as? String ?? pr["response"] as? String ?? ""
                thinking = pr["thinking"] as? String ?? ""
                break
            }
            let payload = text.isEmpty && thinking.isEmpty ? "null" : jsonString(["text": text, "thinking": thinking])
            guard payload != lastLive else { return }
            lastLive = payload
            js("AD.live(\(payload))")
        }
    }

    /// 打开会话后滚到某条消息：把这条会话全部载入，推完内容再让页面定位
    func focus(_ itemId: String) {
        pendingFocus = itemId
        limit = 100_000
        lastSig = ""; lastSent = 0
        reload()
    }

    // 新会话草稿的选择：Claude / Codex 选模型时会在原应用里打开新会话页，之后就在那里发；Antigravity 记下模型 id 和预设
    private var draftUI: NewSessionUI?
    private var draftModel: String?
    private var draftPerm: String?
    private var draftAgyModelId: String?
    private var agyChoices: [(label: String, id: String)] = []
    private var agyChip: Chip?

    func startDraft(_ d: Draft) {
        session = nil
        draft = d
        draftUI = nil; draftModel = nil; draftPerm = nil; draftAgyModelId = nil
        lastHeader = ""
        pushHeader()
    }

    /// 列表刷新后同步状态（在跑/空闲、标题、模型）
    func update(_ s: Session?) {
        guard let s, s.id == session?.id else { return }
        let fileChanged = s.transcript != session?.transcript
        session = s
        pushHeader()
        if fileChanged { rewatch(); reload() }
        // 开始或停止跑、进入或离开等待：重新找批准卡片，Antigravity 的实时预览跟着开关
        let st = "\(s.running)\(s.waiting)\(s.asking)"
        if st != lastState {
            lastState = st
            reload()
            checkApproval()
            updateLiveTimer()
        }
    }

    private func js(_ code: String) {
        guard ready else { return }
        web.evaluateJavaScript(code)
    }

    private func encode(_ v: some Encodable) -> String {
        String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
    }

    private func jsonString(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: v), as: UTF8.self)
    }

    private struct Header: Encodable {
        let id, kind, title, app, project, hint, model, perm: String
        let running, canOpen, canChip, draft: Bool
    }

    private func pushHeader() {
        var h: Header
        if let d = draft {
            let recent = model?.sessions.first { $0.appPath == d.appPath }
            h = Header(id: "draft-\(d.kind.rawValue)-\(d.folder)", kind: d.kind.rawValue, title: tr("新会话", "New session"), app: d.app,
                       project: (d.folder as NSString).lastPathComponent,
                       hint: tr("写下第一条消息，回车后会在 \(d.app) 里新建会话并发送。模型和权限可以先选好。",
                                 "Write the first message. Press Return to start a new session in \(d.app) and send it. You can pick the model and permissions first."),
                       model: draftModel ?? recent?.model ?? "", perm: draftPerm ?? recent?.perm ?? "",
                       running: false, canOpen: false, canChip: true, draft: true)
        } else if let s = session {
            let hint = s.running
                ? tr("任务在跑：回车先排队，结束后按顺序发出；想插话就点排队消息下的「立即发送」。Shift+回车换行。",
                     "Running: Return queues your message and sends it in order when the task finishes. To cut in, click “Send now” under a queued message. Shift+Return for a new line.")
                : s.kind == .antigravity
                    ? tr("回车发送，Shift+回车换行。通过 Antigravity 的本地接口发送。", "Return to send, Shift+Return for a new line. Sent through Antigravity’s local API.")
                    : tr("回车发送，Shift+回车换行。全程在后台操作 \(s.app)，不切前台。", "Return to send, Shift+Return for a new line. \(s.app) is driven in the background and never brought to the front.")
            h = Header(id: s.id, kind: s.kind.rawValue, title: s.title, app: s.app, project: s.project, hint: hint,
                       model: s.model, perm: s.perm, running: s.running, canOpen: s.link != nil,
                       canChip: true, draft: false)
        } else { return }
        let j = encode(h)
        guard j != lastHeader else { return }
        lastHeader = j
        defer { pushQueue() }
        js("AD.setSession(\(j))")
    }

    /// 当前会话的排队消息推给页面
    func pushQueue() {
        let items = session.flatMap { model?.queue[$0.id] } ?? []
        js("AD.setQueue(\(encode(items.map { ["id": $0.id, "text": $0.text, "sending": $0.sending ? "1" : ""] })))")
    }

    private func reload() {
        if reading { dirty = true; return }
        guard ready, let s = session, let f = s.transcript else { return }
        let files = [f.path] + taskFiles
        let sig = files.map { p in
            ((try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date)?.timeIntervalSince1970).map { "\($0)" } ?? "-"
        }.joined(separator: "|") + "|\(limit)"
        guard sig != lastSig else { return }
        lastSig = sig
        reading = true
        let limit = self.limit
        queue.async {
            let full = readDetail(s)
            var shown = Detail(items: Array(full.items.suffix(limit)), tasks: full.tasks, suggestion: full.suggestion,
                               plan: full.plan, model: full.model, hidden: max(0, full.items.count - limit))
            shown.steps = full.steps
            shown.ask = full.ask
            let j = self.encode(shown)
            let h = j.hashValue
            DispatchQueue.main.async {
                self.reading = false
                if self.dirty { self.dirty = false; DispatchQueue.main.async { self.reload() } }
                guard self.session?.id == s.id else { return }
                self.taskFiles = full.tasks.filter { $0.status == "running" }.map(\.outputFile)
                self.rewatch()
                self.agySteps = full.steps
                self.ask = full.ask
                if h != self.lastSent {
                    self.lastSent = h
                    self.js("AD.setDetail(\(j))")
                }
                if let f = self.pendingFocus {
                    self.pendingFocus = nil
                    self.js("AD.focus(\(self.jsonString([f])))")
                }
            }
        }
    }

    private func reply(_ fn: String, _ payload: [String: Any]) {
        js("AD.\(fn)(\(jsonString(payload)))")
    }

    // MARK: 页面发来的消息

    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        let body = msg.body as! [String: Any]
        let type = body["type"] as! String
        if type == "ready" {
            ready = true
            lastHeader = ""
            lastSig = ""; lastSent = 0
            pushHeader()
            reload()
            checkApproval()
            updateLiveTimer()
            return
        }
        if type == "debug" { log("web \(body["text"] as? String ?? "")"); return }
        if type == "open", let s = session { model?.openInApp(s); return }
        if type == "copy" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
            return
        }
        Task { @MainActor in
            do {
                try await handle(type, body)
            } catch let e as SendError {
                reply("result", ["ok": false, "notice": e.message, "type": type])
            } catch {
                reply("result", ["ok": false, "notice": error.localizedDescription, "type": type])
            }
        }
    }

    @MainActor
    private func handle(_ type: String, _ body: [String: Any]) async throws {
        switch type {
        case "pick":
            let panel = openPanel
            guard let win = web.window else { return }
            panel.beginSheetModal(for: win) { r in
                self.js("AD.pickDone()")
                guard r == .OK else { return }
                self.reply("attached", ["files": panel.urls.map { ["path": $0.path, "name": $0.lastPathComponent] }])
            }
        case "more":
            // 页面要看更早的消息
            limit += 300
            lastSig = ""
            reload()
        case "saveBlob":
            // 粘贴 / 拖进来的图片没有路径，先存到本地
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "pasted.png"
            let b64 = (body["data"] as! String).split(separator: ",").last.map(String.init) ?? ""
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentDock/uploads")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(name)")
            try Data(base64Encoded: b64)!.write(to: f)
            reply("attached", ["files": [["path": f.path, "name": name]], "thumb": body["thumb"] as? Bool ?? false])
        case "send":
            let files = body["files"] as? [String] ?? []
            let (sess, dr) = (session, draft)
            let raw = body["text"] as! String
            let text = await Task.detached { self.withAttachments(raw, files, session: sess, draft: dr) }.value
            if let d = draft {
                let t0 = Date()
                try await newSession(kind: d.kind, appPath: d.appPath, folder: d.folder, text: text,
                                     prepared: draftUI, agyModel: draftAgyModelId)
                reply("result", ["ok": true, "type": type, "notice": tr("已在 \(d.app) 里新建会话，稍等它出现在左边列表", "Started a new session in \(d.app). It’ll show up in the list on the left shortly.")])
                // Antigravity 的权限预设要等会话建好后再设
                let preset = d.kind == .antigravity ? draftPerm : nil
                model?.selectNewest(kind: d.kind, after: t0) { s in
                    guard let p = preset, p != s.perm else { return }
                    Task { @MainActor in
                        guard let m = try? await openChip(s, .perm), let i = m.items.firstIndex(where: { $0.label.hasPrefix(p) }) else { return }
                        _ = await chooseChip(m, i)
                    }
                }
                return
            }
            guard let s = session else { return }
            // 任务在跑，或者前面还有排队的：先排队，保证顺序
            if s.running || !(model?.queue[s.id] ?? []).isEmpty {
                model?.enqueue(s, text)
                reply("result", ["ok": true, "type": type, "notice": ""])
                return
            }
            try await deliver(s, text)
            reply("result", ["ok": true, "type": type, "notice": ""])
            confirmArrived(s, text)
        case "sendNow":
            guard let s = session else { return }
            try await model?.sendNow(s.id, body["qid"] as! String)
            reply("result", ["ok": true, "type": type, "notice": tr("已立即发送，\(s.app) 会在当前任务里处理它", "Sent now. \(s.app) will handle it in the current task.")])
        case "unqueue":
            guard let s = session else { return }
            model?.unqueue(s.id, body["qid"] as! String)
        case "approve":
            guard let s = session, let a = approval else { return }
            let i = body["index"] as! Int
            try await answerApproval(s, a, i)
            setApproval(nil)
            reply("result", ["ok": true, "type": type, "notice": tr("已\(a.labels[i])", "Chose “\(a.labels[i])”")])
        case "answer":
            // 问题卡片：在原应用里替你逐题点选并提交
            guard let s = session, let a = ask, a.id == body["id"] as? String else {
                reply("result", ["ok": false, "type": type, "notice": tr("这组问题已经回答过或不在了", "These questions were already answered or are gone.")]); return
            }
            let answers = ((body["answers"] as? [[String: Any]]) ?? []).map {
                AskAnswer(labels: $0["labels"] as? [String] ?? [], other: $0["other"] as? String ?? "")
            }
            try await answerAsk(s, a, answers)
            reply("result", ["ok": true, "type": type, "notice": tr("已在 \(s.app) 里提交回答", "Submitted your answers in \(s.app).")])
        case "stop":
            guard let s = session else { return }
            try await stopSession(s)
            reply("result", ["ok": true, "type": type, "notice": tr("已让 \(s.app) 停止", "Stopped \(s.app).")])
        case "chip":
            guard let chip = Chip(rawValue: body["chip"] as! String) else { return }
            if let m = menu { await closeChip(m); menu = nil }
            if let d = draft {
                if d.kind == .antigravity {
                    // Antigravity：选项自己列，选完记下，新建时带上
                    agyChip = chip
                    agyChoices = chip == .model ? await agyModels() : agyPresets.map { ($0, $0) }
                    reply("menu", ["chip": chip.rawValue, "items": agyChoices.map(\.label),
                                   "current": (chip == .model ? draftModel : draftPerm) ?? tr("默认", "Default")])
                    return
                }
                // Claude / Codex：先在原应用里打开新会话页，再点它的下拉
                if draftUI == nil { draftUI = try await openNewSessionUI(kind: d.kind, appPath: d.appPath, folder: d.folder) }
                let ui = draftUI!
                let m = try await openChipOn(ui.app, ui.ax, ui.composer, chip, d.kind)
                menu = m
                reply("menu", ["chip": chip.rawValue, "items": m.labels, "current": m.before])
                return
            }
            guard let s = session else { return }
            let m = try await openChip(s, chip)
            menu = m
            reply("menu", ["chip": chip.rawValue, "items": m.labels, "current": m.before])
        case "choose":
            if draft != nil, let chip = agyChip {
                let c = agyChoices[body["index"] as! Int]
                if chip == .model { draftModel = c.label; draftAgyModelId = c.id } else { draftPerm = c.label }
                agyChip = nil
                reply("menuDone", ["chip": chip.rawValue, "current": c.label])
                return
            }
            guard let m = menu else { return }
            let more = await chooseChip(m, body["index"] as! Int)
            if more {
                reply("menu", ["chip": m.chip.rawValue, "items": m.labels, "current": m.before])
            } else {
                menu = nil
                if draft != nil { if m.chip == .model { draftModel = m.current } else { draftPerm = m.current } }
                reply("menuDone", ["chip": m.chip.rawValue, "current": m.current])
            }
        case "closeMenu":
            agyChip = nil
            if let m = menu {
                menu = nil
                await closeChip(m)
                reply("menuDone", ["chip": m.chip.rawValue, "current": m.current])
            }
        default: break
        }
    }

    /// 附件：把文件的完整路径附在消息末尾，agent 自己去读。Antigravity 只能读工作区里的文件，先复制进去
    nonisolated private func withAttachments(_ text: String, _ files: [String], session: Session?, draft: Draft?) -> String {
        guard !files.isEmpty else { return text }
        var paths = files
        let kind = session?.kind ?? draft?.kind
        let cwd = session?.cwd ?? draft?.folder ?? ""
        if kind == .antigravity, !cwd.isEmpty {
            let dir = URL(fileURLWithPath: cwd).appendingPathComponent("agentdock_uploads")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            paths = files.map { f in
                let dst = dir.appendingPathComponent(URL(fileURLWithPath: f).lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: f), to: dst)
                return dst.path
            }
        }
        let list = paths.map { "- \($0)" }.joined(separator: "\n")
        return (text.isEmpty ? "" : text + "\n\n") + tr("附件（请直接读取这些文件）：", "Attachments (read these files directly):") + "\n" + list
    }

    /// 发出去 10 秒内对话记录里应当出现这条消息；没出现就提醒，可能发到了别的会话
    private func confirmArrived(_ s: Session, _ text: String) {
        let key = String(text.filter { !$0.isWhitespace }.prefix(20))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard self.session?.id == s.id else { return }
            self.queue.async {
                let hit = readTranscript(s).suffix(30).contains { $0.kind == "user" && $0.text.filter { !$0.isWhitespace }.contains(key) }
                DispatchQueue.main.async {
                    if !hit { self.js("AD.notice('" + tr("10 秒内没在这条会话的记录里看到刚发的消息，可能发到了 \(s.app) 的别的会话，请去应用里确认",
                                                    "The message didn’t show up in this session within 10 seconds. It may have gone to another \(s.app) session. Please check in the app.") + "')") }
                }
            }
        }
    }

    /// 聊天页里的链接只交给系统打开这几种地址；别的协议（file:、各个应用自己的）不处理
    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    // 链接一律用系统浏览器打开，页面本身不跳走
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.navigationType == .linkActivated, let u = a.request.url {
            if let s = u.scheme?.lowercased(), Self.linkSchemes.contains(s) { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(a.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// 窗口不在前台时，网页里的按钮点第一下就生效（WKWebView 默认只拿第一下激活窗口）
final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
