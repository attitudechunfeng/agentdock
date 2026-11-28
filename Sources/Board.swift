import Foundation
import AppKit

// 项目看板：以项目为单位，自动追踪当前目标、进度、问题、等你定的事、验证过的有效 / 无效做法。
// - 触发：会话一轮回复结束（在跑 → 停下），等 90 秒（这段时间里同一项目的其他会话也结束就合并），
//   把这轮新增的用户消息和回复交给汇总 agent 增量更新看板。不定时轮询
// - 归类：新会话先让 agent 判断属于哪个已有项目、还是新项目、还是零散问答；你手动挪过的以你为准
// - 汇总 agent：本机的 Claude Code（Haiku / Sonnet / Opus）或 Codex 命令行，无界面、不留会话记录
// - 输出：除了 Convoy 里的看板，每个项目还写一份 Markdown（~/.agentdock/boards/<项目>.md），
//   在会话里让 agent 先读这份文件，就能找回目标和已经验证过的结论

struct BoardEntry: Codable, Equatable, Identifiable {
    var uid = UUID().uuidString
    var text: String
    var date: String = ""
    var session: String = ""    // 出处会话名
    var state: String = ""      // 结论：有效 / 无效 / 待验证
    var evidence: String = ""   // 结论的依据：数据、现象
    var by: String = ""         // user：你加的或改过的，agent 保留原文
    var id: String { uid }

    init(text: String, date: String = "", session: String = "", state: String = "", evidence: String = "", by: String = "") {
        self.text = text; self.date = date; self.session = session; self.state = state; self.evidence = evidence; self.by = by
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        uid = (try? c.decode(String.self, forKey: .uid)) ?? UUID().uuidString
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        session = (try? c.decode(String.self, forKey: .session)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        evidence = (try? c.decode(String.self, forKey: .evidence)) ?? ""
        by = (try? c.decode(String.self, forKey: .by)) ?? ""
    }
    /// agent 输出的一条（结论的有效 / 无效写在 verdict 里）
    init(dict o: [String: Any]) {
        text = (o["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        date = o["date"] as? String ?? ""
        session = o["session"] as? String ?? ""
        state = o["verdict"] as? String ?? o["state"] as? String ?? ""
        evidence = o["evidence"] as? String ?? ""
    }
    var agentDict: [String: Any] {
        var o: [String: Any] = ["text": text]
        if !date.isEmpty { o["date"] = date }
        if !session.isEmpty { o["session"] = session }
        if !state.isEmpty { o["verdict"] = state }
        if !evidence.isEmpty { o["evidence"] = evidence }
        if !by.isEmpty { o["by"] = by }
        return o
    }
}

/// 一个大类：要解决的大问题或要达成的子目标，下面挂归纳后的结论、进展、下一步
struct Track: Codable, Equatable, Identifiable {
    var id = "t" + UUID().uuidString.prefix(6).lowercased()
    var title: String
    var goal = ""              // 做到什么算完成
    var state = "进行中"        // 进行中 / 卡住 / 等你定 / 已解决 / 搁置
    var now = ""               // 现在走到哪、离目标还差什么
    var updated = ""           // 最近一次进展的日期 MM-DD
    var learned: [BoardEntry] = []
    var log: [BoardEntry] = []
    var next: [BoardEntry] = []
    var manual = false         // 你建的或改过标题：agent 不改标题、不删

    static let states = ["进行中", "卡住", "等你定", "已解决", "搁置"]

    init(title: String, goal: String = "", manual: Bool = false) { self.title = title; self.goal = goal; self.manual = manual }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? id
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        goal = (try? c.decode(String.self, forKey: .goal)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "进行中"
        now = (try? c.decode(String.self, forKey: .now)) ?? ""
        updated = (try? c.decode(String.self, forKey: .updated)) ?? ""
        learned = (try? c.decode([BoardEntry].self, forKey: .learned)) ?? []
        log = (try? c.decode([BoardEntry].self, forKey: .log)) ?? []
        next = (try? c.decode([BoardEntry].self, forKey: .next)) ?? []
        manual = (try? c.decode(Bool.self, forKey: .manual)) ?? false
    }
}

/// 模型提的建议：新大类、改总目标、改某个大类的定义。采纳与否由你定
struct BoardSuggestion: Codable, Equatable, Identifiable {
    var uid = UUID().uuidString
    var kind: String          // 新大类 / 改目标 / 改大类
    var trackId = ""          // 改大类：改哪个
    var title = ""            // 新大类、改大类：大类名
    var goal = ""             // 新大类、改大类：完成标准；改目标：新的总目标
    var reason = ""
    var date = ""
    var id: String { uid }

    init(kind: String, trackId: String = "", title: String = "", goal: String = "", reason: String = "", date: String = "") {
        self.kind = kind; self.trackId = trackId; self.title = title; self.goal = goal; self.reason = reason; self.date = date
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        uid = (try? c.decode(String.self, forKey: .uid)) ?? UUID().uuidString
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "新大类"
        trackId = (try? c.decode(String.self, forKey: .trackId)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        goal = (try? c.decode(String.self, forKey: .goal)) ?? ""
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
    }
    /// 忽略后记进“不追踪的”用的文字
    var key: String {
        kind == "改目标" ? tr("建议改目标：", "Suggested goal: ") + goal
            : kind == "改大类" ? tr("建议改大类：\(title)：\(goal)", "Suggested workstream change: \(title): \(goal)") : title
    }
}

struct Project: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var goal = ""
    var goalByUser = false          // 目标是你写的：agent 不改
    var status = ""
    var decisions: [BoardEntry] = []
    var tracks: [Track] = []
    var ignored: [String] = []      // 你删掉、不想追踪的大类和条目：agent 不再加回来
    var sessions: [String] = []     // Session.id
    var updated: Date?
    var edits: [String] = []        // 上次刷新以来你在看板上做的修改，点“按修改刷新”时交给 agent
    var suggestions: [BoardSuggestion] = []   // 模型对目标、大类的建议，等你采纳

    var fileURL: URL { boardDir.appendingPathComponent(safeFileName(name) + ".md") }
    var activeTracks: [Track] { tracks.filter { $0.state != "已解决" && $0.state != "搁置" } }

    init(name: String) { self.name = name }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? id
        name = (try? c.decode(String.self, forKey: .name)) ?? tr("未命名", "Untitled")
        goal = (try? c.decode(String.self, forKey: .goal)) ?? ""
        goalByUser = (try? c.decode(Bool.self, forKey: .goalByUser)) ?? false
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        decisions = (try? c.decode([BoardEntry].self, forKey: .decisions)) ?? []
        tracks = (try? c.decode([Track].self, forKey: .tracks)) ?? []
        ignored = (try? c.decode([String].self, forKey: .ignored)) ?? []
        sessions = (try? c.decode([String].self, forKey: .sessions)) ?? []
        updated = try? c.decode(Date.self, forKey: .updated)
        edits = (try? c.decode([String].self, forKey: .edits)) ?? []
        suggestions = (try? c.decode([BoardSuggestion].self, forKey: .suggestions)) ?? []
    }

    mutating func track(_ tid: String, _ f: (inout Track) -> Void) {
        if let i = tracks.firstIndex(where: { $0.id == tid }) { f(&tracks[i]) }
    }
    mutating func ignore(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !ignored.contains(t) else { return }
        ignored.append(t)
        if ignored.count > 80 { ignored.removeFirst(ignored.count - 80) }
    }

    /// 交给 agent 的当前看板
    var agentJSON: String {
        var o: [String: Any] = ["goal": goal, "status": status, "decisions": decisions.map(\.agentDict)]
        if goalByUser { o["goalByUser"] = true }
        o["tracks"] = tracks.map { t -> [String: Any] in
            var d: [String: Any] = ["id": t.id, "title": t.title, "goal": t.goal, "state": t.state, "now": t.now, "updated": t.updated,
                                    "learned": t.learned.map(\.agentDict), "log": t.log.map(\.agentDict), "next": t.next.map(\.agentDict)]
            if t.manual { d["manual"] = true }
            return d
        }
        if !ignored.isEmpty { o["ignored"] = ignored }
        if !suggestions.isEmpty { o["pendingSuggestions"] = suggestions.map { ["kind": $0.kind, "title": $0.title, "goal": $0.goal] } }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    /// 用 agent 的输出更新。总目标和大类的定义（名字、完成标准、有哪些大类）不自动变：
    /// 只有项目刚建、还没有目标 / 大类时才采用模型给的初稿；之后模型的改动意见都变成“建议”，你采纳才生效。
    /// 你加的、改过的条目原文保留；你删掉的不再加回来
    mutating func apply(_ o: [String: Any]) {
        let ign = Set(ignored)
        let df = DateFormatter(); df.dateFormat = "MM-dd"
        let today = df.string(from: Date())
        var sugg: [BoardSuggestion] = []
        if goal.isEmpty, let g = o["goal"] as? String, !g.isEmpty { goal = g }
        if let s = o["status"] as? String, !s.isEmpty { status = s }
        func entries(_ v: Any?) -> [BoardEntry]? {
            (v as? [[String: Any]]).map { $0.map(BoardEntry.init(dict:)).filter { !$0.text.isEmpty && !ign.contains($0.text) } }
        }
        func merged(_ new: [BoardEntry]?, _ old: [BoardEntry]) -> [BoardEntry] {
            guard var out = new else { return old }
            for e in old where e.by == "user" {
                if let i = out.firstIndex(where: { $0.text == e.text }) { out[i].by = "user"; out[i].uid = e.uid }
                else { out.append(e) }
            }
            // 同一条保持原来的 id，界面上展开、编辑状态不跳
            for i in out.indices where out[i].by.isEmpty { if let e = old.first(where: { $0.text == out[i].text }) { out[i].uid = e.uid } }
            return out
        }
        decisions = merged(entries(o["decisions"]), decisions)
        let first = tracks.isEmpty
        if let ts = o["tracks"] as? [[String: Any]] {
            for t in ts {
                let title = (t["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let i = tracks.firstIndex { $0.id == (t["id"] as? String) } ?? tracks.firstIndex { $0.title == title }
                if i == nil {
                    guard !title.isEmpty, !ign.contains(title) else { continue }
                    if first { tracks.append(Track(title: title, goal: t["goal"] as? String ?? "")) }
                    else {
                        // 已有大类之外的新方向：只做建议
                        sugg.append(BoardSuggestion(kind: "新大类", title: title, goal: t["goal"] as? String ?? "",
                                                    reason: t["now"] as? String ?? "", date: today))
                        continue
                    }
                }
                let k = i ?? tracks.count - 1
                if let v = t["state"] as? String, Track.states.contains(v) { tracks[k].state = v }
                if let v = t["now"] as? String, !v.isEmpty { tracks[k].now = v }
                if let v = t["updated"] as? String, !v.isEmpty { tracks[k].updated = v }
                tracks[k].learned = merged(entries(t["learned"]), tracks[k].learned)
                tracks[k].log = merged(entries(t["log"]), tracks[k].log)
                tracks[k].next = merged(entries(t["next"]), tracks[k].next)
            }
        }
        for s in (o["suggestions"] as? [[String: Any]]) ?? [] {
            let kind = s["kind"] as? String ?? "新大类"
            guard ["新大类", "改目标", "改大类"].contains(kind) else { continue }
            var x = BoardSuggestion(kind: kind, title: s["title"] as? String ?? "", goal: s["goal"] as? String ?? "",
                                    reason: s["reason"] as? String ?? "", date: today)
            if kind == "改大类" {
                guard let t = tracks.first(where: { $0.id == (s["id"] as? String) } ) ?? tracks.first(where: { $0.title == (s["from"] as? String) }) else { continue }
                x.trackId = t.id
                if x.title.isEmpty { x.title = t.title }
                if x.title == t.title && x.goal == t.goal { continue }
            }
            if kind == "改目标" && (x.goal.isEmpty || x.goal == goal) { continue }
            if kind == "新大类" && (x.title.isEmpty || tracks.contains { $0.title == x.title }) { continue }
            sugg.append(x)
        }
        for x in sugg where !ign.contains(x.key) {
            if let i = suggestions.firstIndex(where: { $0.kind == x.kind && $0.title == x.title && $0.trackId == x.trackId }) { suggestions[i] = x }
            else { suggestions.append(x) }
        }
        if suggestions.count > 8 { suggestions.removeFirst(suggestions.count - 8) }
    }

    /// 采纳建议
    mutating func adopt(_ x: BoardSuggestion) {
        switch x.kind {
        case "改目标": goal = x.goal; goalByUser = true
        case "改大类": track(x.trackId) { $0.title = x.title; if !x.goal.isEmpty { $0.goal = x.goal }; $0.manual = true }
        default: tracks.append(Track(title: x.title, goal: x.goal, manual: true))
        }
        suggestions.removeAll { $0.uid == x.uid }
    }
}

struct BoardSettings: Codable, Equatable {
    var auto = false            // 新装默认不自动汇总（会花额度），在看板里勾选后才开始
    var agent = "claude"        // claude / codex
    var claudeModel = "opus"    // haiku / sonnet / opus
    var codexEffort = "medium"  // low / medium / high
    var geminiModel = "gemini-4-neon-high"

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? true
        agent = (try? c.decode(String.self, forKey: .agent)) ?? "claude"
        claudeModel = (try? c.decode(String.self, forKey: .claudeModel)) ?? "opus"
        codexEffort = (try? c.decode(String.self, forKey: .codexEffort)) ?? "medium"
        geminiModel = (try? c.decode(String.self, forKey: .geminiModel)) ?? "gemini-4-neon-high"
    }
    /// 当前选的模型（界面下拉用）
    var model: String { agent == "codex" ? codexEffort : agent == "gemini" ? geminiModel : claudeModel }
    var label: String { "\(agent) \(model)" }
}

struct BoardCursor: Codable, Equatable { var itemId: String; var ts: String }

private struct BoardState: Codable {
    var projects: [Project] = []
    var cursors: [String: BoardCursor] = [:]   // 每条会话汇总到了哪一条
    var loose: [String] = []                   // 判成零散问答、不进看板的会话
    var pinned: [String] = []                  // 你手动归过类的会话，agent 不再改
    var settings = BoardSettings()
}

let boardDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentdock/boards")
private let boardWork = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentdock/work")
private let boardStateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AgentDock/board.json")

func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? "未命名" : String(t.prefix(60))
}

/// 只在主线程用（汇总那几个异步方法也标在主线程上，等 agent 时不占主线程）
final class BoardStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var settings = BoardSettings() { didSet { if settings != oldValue { save() } } }
    @Published private(set) var busy: String?        // 正在做什么，界面上显示
    @Published private(set) var lastError: String?
    @Published private(set) var queued = 0
    @Published private(set) var refreshing = Set<String>()   // 等着或正在按修改刷新的项目

    private var cursors: [String: BoardCursor] = [:]
    private var loose = Set<String>()
    private var pinned = Set<String>()
    private var due: [String: Date] = [:]             // 会话 id → 什么时候处理
    private var force = Set<String>()                 // 手动“立即更新”的：没有新内容也照样处理（重建时）
    private var timer: Timer?
    private var running = false
    /// 由 Model 提供：按 id 拿最新的会话
    var lookup: (String) -> Session? = { _ in nil }
    var allSessions: () -> [Session] = { [] }

    static let debounce: TimeInterval = 90

    init() {
        if demoMode { projects = demoProjects(); return }
        if let d = try? Data(contentsOf: boardStateURL), let s = try? JSONDecoder().decode(BoardState.self, from: d) {
            projects = s.projects; cursors = s.cursors; loose = Set(s.loose); pinned = Set(s.pinned); settings = s.settings
        }
    }

    // MARK: 查询

    func project(of sid: String) -> Project? { projects.first { $0.sessions.contains(sid) } }
    func isLoose(_ sid: String) -> Bool { loose.contains(sid) }
    func tracked(_ sid: String) -> Bool { cursors[sid] != nil }
    var sorted: [Project] { projects.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) } }

    // MARK: 触发

    /// 会话一轮结束
    func turnEnded(_ s: Session) {
        guard settings.auto else { return }
        enqueue([s.id], after: Self.debounce)
    }

    /// Convoy 启动时：已在看板里、但在 Convoy 没开时又有新内容的会话，补上
    func catchUp(_ list: [Session]) {
        guard settings.auto else { return }
        let f = ISO8601DateFormatter()
        let ids = list.filter { s in
            guard !s.running, let c = cursors[s.id], !loose.contains(s.id) else { return false }
            let t = f.date(from: String(c.ts.prefix(19)) + "Z") ?? .distantPast
            return s.updated.timeIntervalSince(t) > 60
        }.map(\.id)
        if !ids.isEmpty { enqueue(ids, after: 5) }
    }

    /// 从最近几天的会话建起看板（第一次用时）
    func backfill(days: Double) {
        let since = Date().addingTimeInterval(-days * 86400)
        let ids = allSessions().filter { $0.updated > since && !$0.running && cursors[$0.id] == nil && !loose.contains($0.id) }
            .sorted { $0.updated < $1.updated }.map(\.id)
        enqueue(ids, after: 0)
    }
    func backfillCount(days: Double) -> Int {
        let since = Date().addingTimeInterval(-days * 86400)
        return allSessions().filter { $0.updated > since && cursors[$0.id] == nil && !loose.contains($0.id) }.count
    }

    func updateNow(_ p: Project) { enqueue(p.sessions, after: 0) }

    /// 测试用：把这些会话马上汇总一遍，等做完
    @MainActor func runForTest(_ ids: [String]) async {
        for id in ids { due[id] = .distantPast }
        await work()
    }

    /// 重建：清空看板内容，各会话从头再汇总一遍
    func rebuild(_ p: Project) {
        // 你写的目标、建的大类、加的条目、删掉的记录都留着，其余清空
        mutate(p.id) { q in
            // 目标和大类的定义不动，只清内容
            q.status = ""
            q.decisions = q.decisions.filter { $0.by == "user" }
            q.tracks = q.tracks.map { t in
                var t = t; t.now = ""; t.updated = ""
                t.learned = t.learned.filter { $0.by == "user" }; t.log = t.log.filter { $0.by == "user" }; t.next = t.next.filter { $0.by == "user" }
                return t
            }
        }
        for s in p.sessions { cursors[s] = nil; force.insert(s) }
        save()
        enqueue(p.sessions, after: 0)
    }

    private func enqueue(_ ids: [String], after: TimeInterval) {
        let at = Date().addingTimeInterval(after)
        for id in ids { due[id] = min(due[id] ?? at, at) }
        queued = due.count
        arm()
    }

    private func arm() {
        timer?.invalidate()
        guard !running, let first = refreshing.isEmpty ? due.values.min() : Date() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, first.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.work() }
        }
    }

    // MARK: 手动归类

    func move(_ sid: String, to pid: String?) {
        for i in projects.indices { projects[i].sessions.removeAll { $0 == sid } }
        loose.remove(sid)
        if let pid, let i = projects.firstIndex(where: { $0.id == pid }) { projects[i].sessions.append(sid) } else { loose.insert(sid) }
        pinned.insert(sid)
        // 挪进一个项目：从头把这条会话汇总进去
        if pid != nil { cursors[sid] = nil; enqueue([sid], after: 0) }
        save()
    }

    @discardableResult
    func newProject(_ name: String, with sid: String? = nil) -> Project {
        let p = Project(name: name)
        projects.append(p)
        if let sid { move(sid, to: p.id) }
        save()
        return p
    }

    func rename(_ pid: String, _ name: String) {
        guard let old = projects.first(where: { $0.id == pid }), !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: old.fileURL)
        mutate(pid) { $0.name = name }
        save()
    }

    /// 合并：会话并过去，内容由 agent 在下一次更新时整合
    func merge(_ pid: String, into target: String) {
        guard let src = projects.first(where: { $0.id == pid }), pid != target else { return }
        mutate(target) { t in
            t.sessions += src.sessions.filter { !t.sessions.contains($0) }
            t.decisions += src.decisions
            t.tracks += src.tracks.filter { st in !t.tracks.contains { $0.title == st.title } }
            t.ignored += src.ignored.filter { !t.ignored.contains($0) }
        }
        delete(pid)
        if let t = projects.first(where: { $0.id == target }) { enqueue(t.sessions, after: 0); force.formUnion(t.sessions) }
    }

    /// 删项目：它的会话记成零散、不再自动归类，不然这些会话下一轮一结束又会被归回来、项目重新出现。
    /// 想让某条会话重新进看板，右键它 →「归到项目」
    func delete(_ pid: String) {
        guard let p = projects.first(where: { $0.id == pid }) else { return }
        try? FileManager.default.removeItem(at: p.fileURL)
        projects.removeAll { $0.id == pid }
        refreshing.remove(pid)
        for sid in p.sessions where project(of: sid) == nil { loose.insert(sid); pinned.insert(sid); due[sid] = nil }
        queued = due.count
        save()
        log("board: deleted project \(p.name), \(p.sessions.count) sessions set aside")
    }

    /// 按你的修改刷新：把各会话最近的内容重读一遍，连同你的修改交给 agent，整体重新整理这个项目的看板
    func refresh(_ pid: String) {
        refreshing.insert(pid)
        arm()
    }

    /// 看板上手动改：改完存盘、写项目文件；note 记下改了什么，刷新时告诉 agent
    func edit(_ pid: String, note: String? = nil, _ f: (inout Project) -> Void) {
        mutate(pid, f)
        if let note { mutate(pid) { $0.edits.append(note); if $0.edits.count > 40 { $0.edits.removeFirst($0.edits.count - 40) } } }
        save()
    }

    private func mutate(_ pid: String, _ f: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == pid }) else { return }
        f(&projects[i])
    }

    // MARK: 存盘

    private func save() {
        if demoMode { return }   // 演示数据不落盘
        let s = BoardState(projects: projects, cursors: cursors, loose: Array(loose), pinned: Array(pinned), settings: settings)
        try? FileManager.default.createDirectory(at: boardStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: boardStateURL, options: .atomic) }
        writeFiles()
    }

    private func writeFiles() {
        try? FileManager.default.createDirectory(at: boardDir, withIntermediateDirectories: true)
        for p in projects { try? markdown(p).write(to: p.fileURL, atomically: true, encoding: .utf8) }
        var idx = tr("# 项目看板索引\n\n由 Convoy 根据各 agent 会话自动维护。开始或继续某个项目前，先读对应文件，找回当前目标、已验证的结论和等你定的事。\n\n",
                     "# Project board index\n\nMaintained automatically by Convoy from your agent sessions. Before starting or resuming a project, read its file to recover the current goal, verified findings, and decisions waiting on you.\n\n")
        for p in sorted { idx += "- [\(p.name)](\(p.fileURL.lastPathComponent))\(tr("：", ": "))\(p.goal.isEmpty ? tr("（待汇总）", "(not summarized yet)") : p.goal)\n" }
        try? idx.write(to: boardDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        writeContextFiles()
    }

    func markdown(_ p: Project) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let names = p.sessions.compactMap { lookup($0).map { tr("「\($0.title)」(\($0.app))", "\"\($0.title)\" (\($0.app))") } }
        let upd = p.updated.map { tr("，更新于 ", ", updated ") + df.string(from: $0) } ?? ""
        var m = "# \(p.name)\n\n> " + tr("由 Convoy 根据各会话自动维护\(upd)。关联会话：\(names.joined(separator: "、"))",
                                          "Maintained automatically by Convoy from its sessions\(upd). Linked sessions: \(names.joined(separator: ", "))") + "\n\n"
        func src(_ e: BoardEntry) -> String { e.session.isEmpty ? "" : tr("（\(e.session)）", " (\(e.session))") }
        if !p.goal.isEmpty { m += tr("## 当前目标", "## Current goal") + "\n\n\(p.goal)\n\n" }
        if !p.status.isEmpty { m += tr("## 现状", "## Status") + "\n\n\(p.status)\n\n" }
        if !p.decisions.isEmpty { m += tr("## 等你定", "## Needs your decision") + "\n\n" + p.decisions.map { "- " + $0.text + src($0) }.joined(separator: "\n") + "\n\n" }
        if !p.tracks.isEmpty {
            m += tr("## 各大类进度\n\n| 大类 | 状态 | 现在走到哪 | 最近 |", "## Workstreams\n\n| Workstream | State | Where it stands | Last update |") + "\n|---|---|---|---|\n"
            for t in p.tracks { m += "| \(t.title) | \(stateLabel(t.state)) | \(t.now.replacingOccurrences(of: "|", with: "/")) | \(t.updated) |\n" }
            m += "\n"
        }
        for t in p.tracks {
            m += "### \(t.title)" + tr("（\(t.state)）", " (\(stateLabel(t.state)))") + "\n\n"
            if !t.goal.isEmpty { m += tr("目标：", "Done when: ") + t.goal + "\n\n" }
            if !t.now.isEmpty { m += tr("现在：", "Now: ") + t.now + "\n\n" }
            let order = ["有效", "无效", "待验证"]
            let learned = t.learned.sorted { (order.firstIndex(of: $0.state) ?? 3) < (order.firstIndex(of: $1.state) ?? 3) }
            if !learned.isEmpty {
                m += tr("结论：", "Findings:") + "\n\n" + learned.map { e in
                    let tag = e.state == "无效" ? tr("【无效，别再试】", "[Doesn't work, don't retry] ")
                        : e.state.isEmpty ? "" : tr("【\(e.state)】", "[\(stateLabel(e.state))] ")
                    return "- \(tag)\(e.text)" + (e.evidence.isEmpty ? "" : tr("——依据：", " — evidence: ") + e.evidence) + src(e)
                }.joined(separator: "\n") + "\n\n"
            }
            if !t.next.isEmpty { m += tr("下一步：", "Next steps:") + "\n\n" + t.next.map { "- " + $0.text }.joined(separator: "\n") + "\n\n" }
            if !t.log.isEmpty { m += tr("进展：", "Progress:") + "\n\n" + t.log.reversed().map { "- " + ($0.date.isEmpty ? "" : $0.date + " ") + $0.text + src($0) }.joined(separator: "\n") + "\n\n" }
        }
        return m
    }

    // MARK: 汇总

    @MainActor
    private func work() async {
        guard !running else { return }
        let now = Date()
        let ready = due.filter { $0.value <= now }.map(\.key)
        guard !ready.isEmpty || !refreshing.isEmpty else { arm(); return }
        running = true
        defer { running = false; queued = due.count; busy = nil; arm() }
        for id in ready { due[id] = nil }
        queued = due.count

        // 刚启动、会话列表还没扫出来：等一会儿再做
        if allSessions().isEmpty {
            for id in ready { due[id] = Date().addingTimeInterval(5) }
            if !refreshing.isEmpty { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            return
        }

        // 1. 读每条会话这次新增的内容
        var deltas: [String: (s: Session, text: String, last: BoardCursor?)] = [:]
        for id in ready {
            guard let s = lookup(id) else { continue }
            if s.running { due[id] = Date().addingTimeInterval(Self.debounce); continue }   // 又跑起来了，等它停
            let cur = cursors[id]
            let d = await Task.detached { sessionDelta(s, after: cur) }.value
            if d.text.isEmpty && !force.contains(id) { if let c = d.last { cursors[id] = c }; continue }
            deltas[id] = (s, d.text, d.last)
        }
        force.subtract(ready)

        // 2. 没归类的先归类
        var groups: [String: [String]] = [:]   // 项目 id → 会话 id
        for (id, d) in deltas.sorted(by: { $0.value.s.updated < $1.value.s.updated }) {
            if let p = project(of: id) { groups[p.id, default: []].append(id); continue }
            if loose.contains(id) && (pinned.contains(id) || d.text.count < 3000) { if let c = d.last { cursors[id] = c }; continue }
            busy = tr("归类「\(d.s.title)」", "Classifying \"\(d.s.title)\"")
            do {
                let name = try await classify(d.s, d.text)
                if name.isEmpty {
                    loose.insert(id); if let c = d.last { cursors[id] = c }
                    log("board: loose \(d.s.title)")
                    continue
                }
                loose.remove(id)
                let p = projects.first { $0.name == name } ?? newProject(name)
                mutate(p.id) { $0.sessions.append(id) }
                groups[p.id, default: []].append(id)
                log("board: \(d.s.title) → \(name)")
            } catch {
                fail(error); due[id] = Date().addingTimeInterval(300)
            }
        }
        save()

        // 3. 每个项目一次更新，把这次各会话的新增内容一起给 agent
        for (pid, ids) in groups {
            guard let p = projects.first(where: { $0.id == pid }) else { continue }
            busy = tr("更新「\(p.name)」", "Updating \"\(p.name)\"")
            let text = ids.compactMap { deltas[$0] }.map { sessionHeading($0.s) + "\n\n\($0.text)" }.joined(separator: "\n\n")
            do {
                let t0 = Date()
                let b = try await update(p, text)
                mutate(pid) { q in q.apply(b); q.updated = Date() }
                for id in ids { if let c = deltas[id]?.last { cursors[id] = c } }
                // 有会话这次的内容其实是别的项目的事：重新归类（你手动归过的不动）
                for title in (b["moved"] as? [String]) ?? [] {
                    guard let id = ids.first(where: { deltas[$0]?.s.title == title }), !pinned.contains(id), let d = deltas[id] else { continue }
                    busy = tr("重新归类「\(title)」", "Reclassifying \"\(title)\"")
                    guard let name = try? await classify(d.s, d.text), name != p.name else { continue }
                    for i in projects.indices { projects[i].sessions.removeAll { $0 == id } }
                    if name.isEmpty { loose.insert(id); log("board: \(title) moved to loose"); continue }
                    let target = projects.first { $0.name == name } ?? newProject(name)
                    mutate(target.id) { $0.sessions.append(id) }
                    log("board: \(title) moved \(p.name) → \(name)")
                    if let t = projects.first(where: { $0.id == target.id }),
                       let o = try? await update(t, sessionHeading(d.s) + "\n\n\(d.text)") {
                        mutate(t.id) { q in q.apply(o); q.updated = Date() }
                    }
                }
                lastError = nil
                save()
                log("board: updated \(p.name) from \(ids.count) sessions, \(text.count) chars, \(Int(Date().timeIntervalSince(t0)))s")
            } catch {
                fail(error)
                for id in ids { due[id] = Date().addingTimeInterval(300) }
            }
        }

        // 4. 按你的修改刷新：重读各会话最近的内容，和你的修改一起交给 agent 整体重新整理
        for pid in refreshing {
            guard let p = projects.first(where: { $0.id == pid }) else { refreshing.remove(pid); continue }
            busy = tr("按修改刷新「\(p.name)」", "Refreshing \"\(p.name)\" with your edits")
            var parts: [String] = [], lasts: [String: BoardCursor] = [:]
            for sid in p.sessions {
                guard let s = lookup(sid) else { continue }
                let d = await Task.detached { sessionDelta(s, after: nil) }.value
                if let c = d.last { lasts[sid] = c }
                if !d.text.isEmpty { parts.append(sessionHeading(s) + "\n\n\(String(d.text.suffix(max(8000, 60000 / max(1, p.sessions.count)))))") }
            }
            let n = p.edits.count
            do {
                let t0 = Date()
                let o = try await update(p, parts.isEmpty ? tr("（没有会话内容，只按用户的修改重新整理）", "(No session content; reorganize based on the user's edits only.)") : parts.joined(separator: "\n\n"), reorganize: true)
                mutate(pid) { q in q.apply(o); q.updated = Date(); q.edits.removeFirst(min(n, q.edits.count)) }
                for (sid, c) in lasts { cursors[sid] = c }
                lastError = nil
                save()
                log("board: refreshed \(p.name) with \(n) edits, \(Int(Date().timeIntervalSince(t0)))s")
            } catch { fail(error) }
            refreshing.remove(pid)
        }
    }

    /// 先用你选的 agent；被模型的安全过滤误拦（正常内容也会偶尔被拦）时换一个模型再试
    @MainActor
    private func runAgent(system: String, prompt: String) async throws -> String {
        // 退路：Opus → Sonnet → Gemini（Antigravity 开着时）→ Codex → Haiku（最弱，放最后）
        var tries = [settings]
        func add(_ t: BoardSettings) { if !tries.contains(where: { $0.agent == t.agent && $0.model == t.model }) { tries.append(t) } }
        if claudeCLI() != nil { for m in ["opus", "sonnet"] { var t = settings; t.agent = "claude"; t.claudeModel = m; add(t) } }
        if runningApp("/Applications/Antigravity.app") != nil { var t = settings; t.agent = "gemini"; add(t) }
        if codexCLI() != nil { var t = settings; t.agent = "codex"; add(t) }
        if claudeCLI() != nil { var t = settings; t.agent = "claude"; t.claudeModel = "haiku"; add(t) }
        var last: Error = BoardError(tr("没有可用的汇总 agent", "No summarizer agent available"))
        for (i, t) in tries.enumerated() {
            do {
                let out = try await runBoardAgent(system: system, prompt: prompt, settings: t)
                if i > 0 { log("board: fell back to \(t.label)") }
                return out
            } catch let e as BoardError where e.message.contains("safeguards") || e.message.contains("flagged") || e.message.contains("Antigravity 没开") || e.message.contains("Antigravity isn't running") {
                last = e
                log("board: \(t.label) unavailable (\(e.message.prefix(60))), trying next")
            }
        }
        throw last
    }

    private func fail(_ e: Error) {
        lastError = (e as? BoardError)?.message ?? "\(e)"
        log("board FAIL \(lastError!)")
    }

    @MainActor
    private func classify(_ s: Session, _ text: String) async throws -> String {
        let list = projects.map { "- \($0.name)：\($0.goal.isEmpty ? "（还没有汇总）" : $0.goal)" }.joined(separator: "\n")
        let prompt = """
        已有项目：
        \(list.isEmpty ? "（还没有项目）" : list)

        会话标题：\(s.title)
        工作目录：\(s.cwd)
        会话内容（节选）：
        \(String(text.prefix(12000)))
        """ + (isEnglish ? englishClassifyNote : "")
        let out = try await runAgent(system: classifyPrompt, prompt: prompt)
        guard let o = parseJSON(out), let name = o["project"] as? String else { throw BoardError(tr("归类结果读不懂：", "Couldn't parse the classification result: ") + out.prefix(200)) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func update(_ p: Project, _ text: String, reorganize: Bool = false) async throws -> [String: Any] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let ask = !reorganize ? "" : """
        【这次是用户要求的整体刷新】用户觉得看板的目标和大类归纳得不够清楚，手动做了修改，以用户为准：
        \(p.edits.isEmpty ? "（用户没有改动，只要求重新整理）" : p.edits.map { "- " + $0 }.joined(separator: "\n"))

        请按用户的修改重新整理整个看板，而不是只做增量：
        - goal 和各大类的定义以看板里现在的为准（用户已经改好），不要改写。
        - 把已有的结论、进展、下一步按用户的大类划分重新归位；结合下面的会话内容补全每个大类的 state、now、结论、下一步。
        - 如果按用户的划分有内容放不下，或你觉得定义还可以更清楚，写进 suggestions，不要自己改。

        """
        let prompt = """
        \(ask)今天是 \(df.string(from: Date()))。项目：\(p.name)

        当前看板（JSON）：
        \(p.agentJSON)

        这次各会话新增的内容：
        \(text)
        """ + (isEnglish ? englishBoardNote : "")
        let out = try await runAgent(system: updatePrompt, prompt: prompt)
        guard let o = parseJSON(out), o["tracks"] != nil || o["goal"] != nil else { throw BoardError(tr("看板更新结果读不懂：", "Couldn't parse the board update: ") + out.prefix(200)) }
        return o
    }
}

struct BoardError: Error { let message: String; init(_ m: String) { message = m } }

/// 交给 agent 的会话内容小标题
private func sessionHeading(_ s: Session) -> String { tr("### 会话「\(s.title)」（\(s.app)）", "### Session \"\(s.title)\" (\(s.app))") }

// MARK: 读会话的新增内容

/// 游标之后新增的用户消息和回复（工具调用不要），太长时保留开头一条用户消息和最近的内容
func sessionDelta(_ s: Session, after cur: BoardCursor?) -> (text: String, last: BoardCursor?) {
    let items = readDetail(s).items.filter { $0.kind == "user" || $0.kind == "assistant" }
    guard let lastItem = items.last else { return ("", cur) }
    let last = BoardCursor(itemId: lastItem.id, ts: lastItem.ts)
    var start = 0
    if let cur {
        if let i = items.lastIndex(where: { $0.id == cur.itemId }) { start = i + 1 }
        else if !cur.ts.isEmpty { start = items.firstIndex { !$0.ts.isEmpty && $0.ts > cur.ts } ?? items.count }
    }
    let new = Array(items[start...])
    func line(_ it: Item) -> String {
        let who = it.kind == "user" ? tr("用户", "User") : tr("助手", "Assistant")
        let t = it.ts.count >= 16 ? " " + String(it.ts.dropFirst(5).prefix(11)).replacingOccurrences(of: "T", with: " ") : ""
        let body = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = it.kind == "user" ? 2500 : 3000
        return "[\(who)\(t)] " + (body.count > cap ? String(body.prefix(cap)) + tr("…（截断）", "… (truncated)") : body)
    }
    var lines = new.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(line)
    guard !lines.isEmpty else { return ("", last) }
    // 第一次汇总这条会话：带上会话开头的诉求
    var head: [String] = []
    if cur == nil, start == 0, let firstUser = items.first(where: { $0.kind == "user" }) { head = [line(firstUser)]; if lines.first == head.first { lines.removeFirst() } }
    let budget = 30000
    var tail: [String] = [], n = head.joined().count
    for l in lines.reversed() { if n + l.count > budget { break }; tail.insert(l, at: 0); n += l.count }
    let skipped = lines.count - tail.count
    let text = (head + (skipped > 0 ? [tr("……（中间省略 \(skipped) 条）", "… (\(skipped) messages omitted)")] : []) + tail).joined(separator: "\n\n")
    return (text, last)
}

// MARK: 调用汇总 agent

private let classifyPrompt = """
你在帮用户维护多项目看板。用户同时用多个 AI agent 会话推进好几个项目。给你已有项目列表和一条会话的内容，判断这条会话属于哪个项目：
- 属于已有项目：返回那个项目名，一字不改。
- 是一个新的、需要持续推进的项目：起一个简短的中文项目名（4 到 12 个字，人名、模型名、技术名保留英文）。
- 只是零散的一次性问答、闲聊、查个东西、调一下工具，不属于任何持续项目：返回空字符串。
只输出一个 JSON 对象，不要任何别的文字：{"project": "项目名或空字符串"}
"""

/// 英文界面：项目名用英文（追加在 classify 拼的提示末尾）
private let englishClassifyNote = """


LANGUAGE: The user's interface is in English. A new project name must be in English (2 to 6 words), not Chinese; this overrides the instruction above about Chinese names. Keep names of people, models, and technologies as they are. If the session belongs to an existing project, return that project's name exactly as listed, even if it is in Chinese. Example: {"project": "Speech recognition accuracy"}
"""

/// 英文界面：看板文字用英文，但状态、结论、建议类型这些取值仍用中文（程序按原文比对）。追加在 update 拼的提示末尾（含整体刷新）
private let englishBoardNote = """


LANGUAGE: The user's interface is in English. Write all board text you produce in English: goal, status, track titles and goals, now, every entry text, evidence, log and next items, decisions, and suggestion titles, goals, and reasons. This overrides the instruction above to write in Chinese. Keep names of people, models, and technologies as they are. Text that already exists on the board is still output verbatim where the rules above say so (goal, track id/title/goal, entries with "by":"user").
EXCEPTION: the enum fields are read literally by the app and must use exactly these Chinese values, never translated:
- tracks[].state: 进行中 / 卡住 / 等你定 / 已解决 / 搁置
- learned[].verdict: 有效 / 无效 / 待验证
- suggestions[].kind: 新大类 / 改目标 / 改大类
Example of the expected mix:
{"goal":"Cut ASR word error rate below 5%","status":"Retraining from scratch; waiting on the eval run","decisions":[{"text":"Pick the eval set: internal or public","session":"…"}],"tracks":[{"id":"…","title":"Named-entity accuracy","goal":"Entity error rate under 2%","state":"进行中","now":"From-scratch run at step 6k, entity errors down to 3.1%","updated":"11-25","learned":[{"text":"Continuing from the old LoRA doesn't remove the entity bias; train from scratch","verdict":"有效","evidence":"Entity errors 7.8% → 3.1%","session":"…"}],"log":[{"date":"11-25","text":"Switched to from-scratch training","session":"…"}],"next":[{"text":"Run the full eval at step 10k"}]}],"suggestions":[{"kind":"新大类","title":"Inference latency","goal":"Under 300 ms per turn","reason":"Latency complaints came up in two sessions"}],"moved":[]}
"""

private let updatePrompt = """
你是项目看板的维护者。用户同时用多个 AI agent 会话推进项目，上下文一长就容易失焦。你根据各会话里新发生的内容增量更新这个项目的看板，让用户和 agent 随时看清：目标是什么、每个大类问题推进到哪了、得出了哪些可复用的结论、什么在等用户拍板。

看板按“大类”组织（tracks）。一个大类是一个要解决的大问题或要达成的子目标，例如“专名识别准确率”“训练数据质量”“评测口径”“推理延迟”，而不是某个具体方法、某次实验或某个参数。

规则：
- 只依据给出的会话内容，不编造。数字和结论要和会话一致，出处写进 session 字段（会话名）。
- goal 和每个大类的 title、goal 是用户确认过的定义，原样输出，不要改写。只有当前看板还没有 goal 或还没有任何大类时（新项目），才由你起草 goal 和 3 到 7 个大类。
- 你觉得总目标该调整、某个大类的名字或完成标准不清楚、或出现了已有大类装不下的新方向时，写进 suggestions，由用户决定是否采纳：
  - {"kind":"改目标","goal":"新的总目标","reason":"为什么"}
  - {"kind":"改大类","id":"大类 id","title":"新名字","goal":"新的完成标准","reason":"为什么"}
  - {"kind":"新大类","title":"…","goal":"…","reason":"会话里出现了什么"}
  建议要少而准，只在确有必要时提；pendingSuggestions 里已有的不要重复提。新方向的进展在用户采纳前先不写进看板，可以在建议的 reason 里简述。
- status：一句话说清项目整体现在在做什么、卡在哪、在等什么。
- decisions：明确在等用户拍板的事项；用户已经定了的移出，并记进相应大类的 log。
- tracks：已有大类全部原样保留（id、title、goal 不变，不能删、不能合并），新内容归进最合适的已有大类，只更新 state、now、updated、learned、log、next。
  - title：大类名，4 到 14 个字，用“要解决的问题”或“要达成的结果”来命名，让人不看细节就知道这类在管什么。goal：这一类做到什么算完成，写成可检验的标准（有数字门槛就写门槛）。
  - state 取 进行中 / 卡住 / 等你定 / 已解决 / 搁置。
  - now：一句话说清这一类现在走到哪、离 goal 还差什么，这是用户看进度的主要依据。updated：这一类最近一次进展的日期 MM-DD。
  - learned：从实验和讨论里归纳出的可复用结论，写到原则层面（例如“在旧 LoRA 上续训洗不掉专名偏置，要从零训”），不要写成操作步骤或参数清单；verdict 取 有效 / 无效 / 待验证；evidence 用一句话给最关键的数据或现象。相近的合并，每个大类不超过 5 条。除非被新证据推翻，不要删；被推翻时改 verdict 和 evidence。
  - log：这一类的关键进展（出结果、做决定、换方向），date 写 MM-DD，从旧到新，每类最多 6 条，细碎的合并。
  - next：这一类接下来 1 到 3 件事。
- by 为 user 的条目是用户手写或改过的，原文保留、不能删（可以改它的 verdict）。
- ignored 里是用户删掉、不想追踪的大类和条目，不要再加回来，意思相同的也不要。
- 如果某条会话这次新增的内容明显是另一个项目的事、和本项目目标无关，把它的会话名放进 moved，这部分内容不要写进本看板。
- 每条都要短，中文；人名、模型名、技术名保留英文。没变化的部分原样保留。

只输出一个 JSON 对象，不要任何别的文字：
{"goal":"…","status":"…","decisions":[{"text":"…","session":"…"}],"tracks":[{"id":"…","title":"…","goal":"…","state":"进行中","now":"…","updated":"11-25","learned":[{"text":"…","verdict":"有效","evidence":"…","session":"…"}],"log":[{"date":"11-25","text":"…","session":"…"}],"next":[{"text":"…"}]}],"suggestions":[],"moved":[]}
"""

private func jsonSlice(_ s: String) -> String? {
    guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
    return String(s[a...b])
}
private func parseJSON(_ s: String) -> [String: Any]? {
    jsonSlice(s).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

/// 可选的汇总 agent，界面上列出来
struct BoardAgentChoice: Identifiable, Hashable {
    let agent: String, model: String, label: String
    var id: String { agent + ":" + model }
    static var all: [BoardAgentChoice] {
        var a: [BoardAgentChoice] = []
        if claudeCLI() != nil {
            a += [("opus", tr("Opus 5.5（推荐，最准）", "Opus 5.5 (recommended, most accurate)")), ("sonnet", tr("Sonnet 5.5（省一些）", "Sonnet 5.5 (cheaper)")),
                  ("haiku", tr("Haiku 5.5（最快最省）", "Haiku 5.5 (fastest, cheapest)"))]
                .map { BoardAgentChoice(agent: "claude", model: $0.0, label: "Claude " + $0.1) }
        }
        if codexCLI() != nil {
            a += [("low", tr("低强度", "low effort")), ("medium", tr("中强度", "medium effort")), ("high", tr("高强度", "high effort"))]
                .map { BoardAgentChoice(agent: "codex", model: $0.0, label: tr("Codex 默认模型 · ", "Codex default model · ") + $0.1) }
        }
        if FileManager.default.isExecutableFile(atPath: agyServer) {
            a += [("gemini-4-neon-high", tr("Gemini 4 Neon 高强度", "Gemini 4 Neon high")), ("gemini-4-neon-medium", tr("Gemini 4 Neon 中强度", "Gemini 4 Neon medium")),
                  ("gemini-3.8-flash-medium", tr("Gemini 3.8 Flash（快）", "Gemini 3.8 Flash (fast)"))]
                .map { BoardAgentChoice(agent: "gemini", model: $0.0, label: $0.1 + tr("（要开着 Antigravity）", " (requires Antigravity running)")) }
        }
        return a
    }
}

func claudeCLI() -> (path: String, pre: [String])? {
    let h = NSHomeDirectory()
    if let c = configClaudeCLI, let p = c.first, FileManager.default.isExecutableFile(atPath: p) { return (p, Array(c.dropFirst())) }
    for p in [h + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", h + "/.claude/local/claude"]
    where FileManager.default.isExecutableFile(atPath: p) { return (p, []) }
    // 只装了 Claude 桌面版：用它自带的 Claude Code（取最新版本）
    let bundled = h + "/Library/Application Support/Claude/claude-code"
    let vers = ((try? FileManager.default.contentsOfDirectory(atPath: bundled)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for v in vers {
        for sub in (try? FileManager.default.contentsOfDirectory(atPath: bundled + "/" + v)) ?? [] {
            let p = bundled + "/\(v)/\(sub)/claude.app/Contents/MacOS/claude"
            if FileManager.default.isExecutableFile(atPath: p) { return (p, []) }
        }
    }
    return nil
}

func codexCLI() -> String? {
    for p in [codexAppPath + "/Contents/Resources/codex-cli/bin/codex", codexAppPath + "/Contents/Resources/codex",
              "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
              "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return nil
}

/// 起一个无界面的 agent 跑一次，不给工具、不留会话记录、不跑你配的钩子；5 分钟超时
func runBoardAgent(system: String, prompt: String, settings: BoardSettings) async throws -> String {
    if settings.agent == "gemini" { return try await runGemini(system + "\n\n---\n\n" + prompt, model: settings.geminiModel) }
    try? FileManager.default.createDirectory(at: boardWork, withIntermediateDirectories: true)
    let p = Process()
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    p.currentDirectoryURL = boardWork
    var outFile: URL?
    if settings.agent == "codex" {
        guard let c = codexCLI() else { throw BoardError(tr("没找到 Codex 命令行", "Codex CLI not found")) }
        let f = boardWork.appendingPathComponent("codex-out-\(UUID().uuidString).txt")
        outFile = f
        p.executableURL = URL(fileURLWithPath: c)
        p.arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "-C", boardWork.path,
                       "-c", "model_reasoning_effort=\"\(settings.codexEffort)\"", "-o", f.path, "-"]
    } else {
        guard let c = claudeCLI() else { throw BoardError(tr("没找到 Claude Code 命令行", "Claude Code CLI not found")) }
        p.executableURL = URL(fileURLWithPath: c.path)
        p.arguments = c.pre + ["-p", "--model", settings.claudeModel, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                               "--disable-slash-commands", "--settings", "{\"disableAllHooks\":true}", "--output-format", "json",
                               "--system-prompt", system]
    }
    let input = Pipe(), output = Pipe(), errPipe = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = errPipe
    let full = settings.agent == "codex" ? system + "\n\n---\n\n" + prompt : prompt
    let result: (Int32, Data, Data) = try await withCheckedThrowingContinuation { cont in
        let q = DispatchQueue(label: "agentdock.board.agent")
        q.async {
            do { try p.run() } catch { cont.resume(throwing: BoardError(tr("启动汇总 agent 失败：", "Couldn't start the summarizer: ") + error.localizedDescription)); return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            q.asyncAfter(deadline: .now() + 300, execute: killer)
            DispatchQueue.global().async {
                input.fileHandleForWriting.write(Data(full.utf8))
                try? input.fileHandleForWriting.close()
            }
            var errData = Data()
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let out = output.fileHandleForReading.readDataToEndOfFile()
            g.wait()
            p.waitUntilExit()
            killer.cancel()
            cont.resume(returning: (p.terminationStatus, out, errData))
        }
    }
    let (code, out, err) = result
    if settings.agent == "codex" {
        defer { if let f = outFile { try? FileManager.default.removeItem(at: f) } }
        guard code == 0, let f = outFile, let s = try? String(contentsOf: f, encoding: .utf8), !s.isEmpty else {
            throw BoardError(tr("Codex 汇总失败（退出码 \(code)）：", "Codex summarizer failed (exit code \(code)): ") + String(decoding: err.suffix(300), as: UTF8.self))
        }
        return s
    }
    guard let o = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
        throw BoardError(tr("Claude 汇总失败（退出码 \(code)）：", "Claude summarizer failed (exit code \(code)): ") + String(decoding: (out + err).suffix(300), as: UTF8.self))
    }
    if (o["is_error"] as? Bool) == true { throw BoardError(tr("Claude 汇总失败：", "Claude summarizer failed: ") + (o["result"] as? String ?? "")) }
    return o["result"] as? String ?? ""
}


// MARK: Gemini：借开着的 Antigravity 临时开一个对话，拿到回复就删掉

let boardScratchTitle = "Convoy 看板汇总"
/// 改名前（AgentDock）留下的临时对话标题，列表里同样不显示
let boardScratchTitles: Set<String> = [boardScratchTitle, "AgentDock 看板汇总"]
private let agyServer = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"

/// Antigravity 的对话带工具、权限按你的全局预设，没法关掉，只能在提示里要求它不用工具。
/// 回复看对话记录：最后一步是模型的回复、已完成，且 2 秒内没有新步骤，就算答完。5 分钟超时。
/// 不论成败都删掉这个对话（官方接口 DeleteCascadeTrajectory，对话记录和会话库里的条目一起删）
func runGemini(_ prompt: String, model: String) async throws -> String {
    guard runningApp("/Applications/Antigravity.app") != nil else { throw BoardError(tr("Antigravity 没开，Gemini 用不了", "Antigravity isn't running, so Gemini is unavailable")) }
    let full = prompt + "\n\n（不要调用任何工具，不要读写文件、不要运行命令，直接按要求输出。）"
    let out: String
    do {
        out = try await Task.detached { try runAgentapi(["new-conversation", "--model=\(model)", "--title=\(boardScratchTitle)", full]) }.value
    } catch let e as SendError { throw BoardError(tr("Gemini 新建对话失败：", "Couldn't start a Gemini conversation: ") + e.message) }
    guard let o = jsonSlice(out).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
          let cid = ((o["response"] as? [String: Any])?["newConversation"] as? [String: Any])?["conversationId"] as? String
    else { throw BoardError(tr("Gemini 新建对话没返回对话 id：", "Gemini didn't return a conversation ID: ") + out.prefix(200)) }
    func cleanup() async {
        _ = try? await agyRPC("CancelCascadeInvocation", ["cascadeId": cid])
        _ = try? await agyRPC("DeleteCascadeTrajectory", ["cascadeId": cid])
        log("board: gemini scratch \(cid.prefix(8)) deleted")
    }
    do {
        let r = try await waitGemini(cid)
        await cleanup()
        return r
    } catch {
        await cleanup()
        throw error
    }
}

private func waitGemini(_ cid: String) async throws -> String {
    let f = URL(fileURLWithPath: NSHomeDirectory() + "/.gemini/antigravity/brain/\(cid)/.system_generated/logs/transcript_full.jsonl")
    var lastCount = -1, stable = 0
    let start = Date()
    while Date().timeIntervalSince(start) < 300 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
        let lines = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let last = lines.last else { continue }
        if (last["type"] as? String)?.contains("ERROR") == true || (last["status"] as? String) == "ERROR" {
            throw BoardError(tr("Gemini 出错：", "Gemini error: ") + String(describing: last["content"] ?? last).prefix(200))
        }
        let done = last["source"] as? String == "MODEL" && last["type"] as? String == "PLANNER_RESPONSE"
            && last["status"] as? String == "DONE" && !((last["content"] as? String) ?? "").isEmpty
        if done && lines.count == lastCount { stable += 1 } else { stable = 0 }
        lastCount = lines.count
        if stable >= 2 { return last["content"] as? String ?? "" }
    }
    throw BoardError(tr("Gemini 5 分钟没答完", "Gemini didn't finish within 5 minutes"))
}

// MARK: 让会话读到项目看板
// Convoy 为每个项目写一份精简上下文（~/.agentdock/boards/.ctx/<项目 id>.txt），并记下每条会话属于哪个项目（sessions.json）。
// Claude Code 和 Codex 的钩子（你发消息时、会话开始或压缩后）调用 `Convoy --board-hook`：
// 认出这条会话的项目，看板自上次注入后有变化（或会话刚开始、刚压缩）就把精简上下文附进这一轮，没变化什么都不加

let boardCtxDir = boardDir.appendingPathComponent(".ctx")
private let boardSessionsURL = boardDir.appendingPathComponent("sessions.json")
private let boardSeenURL = boardDir.appendingPathComponent(".ctx/seen.json")
let boardHookCommand = "'/Applications/Convoy.app/Contents/MacOS/Convoy' --board-hook"

extension Project {
    /// 注入到会话里的精简版
    var contextText: String {
        var m = tr("【项目看板：\(name)】由 Convoy 根据这个项目的各个 agent 会话自动维护，目标和大类由用户确认。动手前先对齐；完整内容（含进展记录）见 \(fileURL.path)\n",
                   "[Project board: \(name)] Maintained automatically by Convoy from this project's agent sessions; the goal and workstreams are confirmed by the user. Align with it before you start. Full board (including the progress log): \(fileURL.path)\n")
        if !goal.isEmpty { m += "\n" + tr("总目标：", "Overall goal: ") + goal + "\n" }
        if !status.isEmpty { m += tr("现状：", "Status: ") + status + "\n" }
        if !decisions.isEmpty { m += "\n" + tr("等用户拍板：", "Waiting on the user's decision:") + "\n" + decisions.map { "- " + $0.text }.joined(separator: "\n") + "\n" }
        if !tracks.isEmpty {
            m += "\n" + tr("各大类：", "Workstreams:") + "\n"
            for t in tracks {
                m += "- [\(stateLabel(t.state))] \(t.title)" + (t.goal.isEmpty ? "" : tr("（完成标准：\(t.goal)）", " (done when: \(t.goal))"))
                    + (t.now.isEmpty ? "" : tr("：", ": ") + t.now) + "\n"
            }
        }
        for (v, title) in [("有效", tr("验证有效的做法", "Approaches verified to work")), ("无效", tr("验证无效的做法（别再试）", "Approaches verified not to work (don't retry)"))] {
            let xs = tracks.flatMap { t in t.learned.filter { $0.state == v }.map { (t.title, $0) } }
            if !xs.isEmpty {
                m += "\n\(title)\(tr("：", ":"))\n" + xs.prefix(10).map {
                    "- \($0.1.text)" + ($0.1.evidence.isEmpty ? "" : tr("（\($0.1.evidence)）", " (\($0.1.evidence))")) + tr("〔\($0.0)〕", " [\($0.0)]")
                }.joined(separator: "\n") + "\n"
            }
        }
        return m
    }
}

extension BoardStore {
    /// 会话 → 项目的对照表。键是钩子能拿到的会话 id：Claude 是底层会话 id（记录文件名），Codex 是线程 id
    func writeContextFiles() {
        try? FileManager.default.createDirectory(at: boardCtxDir, withIntermediateDirectories: true)
        var map: [String: String] = [:]
        for p in projects {
            try? p.contextText.write(to: boardCtxDir.appendingPathComponent(p.id + ".txt"), atomically: true, encoding: .utf8)
            for sid in p.sessions {
                guard let s = lookup(sid) else { continue }
                map[s.rawId] = p.id
                if s.kind != .antigravity, let f = s.transcript { map[f.deletingPathExtension().lastPathComponent] = p.id }
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted]) { try? d.write(to: boardSessionsURL, options: .atomic) }
    }
}

/// 钩子入口：从标准输入读钩子事件，必要时在标准输出给出要附加的上下文。出任何错都安静退出，不影响会话
func boardHook() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let o = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
    let event = o["hook_event_name"] as? String ?? ""
    var keys = [o["session_id"] as? String ?? ""]
    if let t = o["transcript_path"] as? String { keys.append(((t as NSString).lastPathComponent as NSString).deletingPathExtension) }
    guard let d = try? Data(contentsOf: boardSessionsURL), let map = try? JSONSerialization.jsonObject(with: d) as? [String: String],
          let key = keys.first(where: { !$0.isEmpty && map[$0] != nil }), let pid = map[key],
          let text = try? String(contentsOf: boardCtxDir.appendingPathComponent(pid + ".txt"), encoding: .utf8), !text.isEmpty
    else { return }
    // 看板没变就不重复加；会话刚开始、刚压缩（之前的上下文没了）时照加
    var seen = (try? JSONSerialization.jsonObject(with: Data(contentsOf: boardSeenURL)) as? [String: Int]) ?? [:]
    // 稳定的指纹（Swift 自带的 hashValue 每个进程都不同，不能用）
    var h: UInt64 = 0xcbf29ce484222325
    for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    let ver = Int(h & 0x7fffffffffff)
    let source = o["source"] as? String ?? ""
    if event == "UserPromptSubmit" && seen[key] == ver { return }
    if event == "SessionStart" && source == "startup" && seen[key] == ver { return }
    seen[key] = ver
    if let d = try? JSONSerialization.data(withJSONObject: seen) { try? d.write(to: boardSeenURL, options: .atomic) }
    let note = text + tr("\n（以上由 Convoy 自动附加；看板有更新时才会再次出现。）", "\n(Added automatically by Convoy; it shows up again only when the board changes.)")
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": note]]
    if let d = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(d) }
}

/// 一份配置文件装上 / 摘掉钩子之后的结果
enum HookFileOutcome: Equatable {
    case changed            // 改了，并且重新读出来核对过
    case unchanged          // 本来就是想要的状态，没动文件
    case skipped            // 文件读不懂（不是 JSON 对象），没动
    case failed(String)     // 写不进去或核对不上，已经恢复成改之前的样子
}

private let backupStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

/// 带时间的备份最多留这么多份，多了删最旧的
private let backupKeep = 10

/// 在解析好的配置里装上 / 摘掉看板钩子，返回有没有改动
func applyBoardHooks(_ root: inout JSONValue, on: Bool, command: String) -> Bool {
    var hooks = JSONValue.object(root["hooks"]?.objectPairs ?? [])   // hooks 不是对象（null 之类）就当没有
    var dirty = false
    for ev in ["UserPromptSubmit", "SessionStart"] {
        let old = hooks[ev]?.items ?? []
        var groups = old.filter { !isBoardHookGroup($0) }
        if on { groups.append(boardHookGroup(command)) }
        if groups != old { dirty = true }
        hooks.set(ev, groups.isEmpty ? nil : .array(groups))
    }
    if dirty { root.set("hooks", (hooks.objectPairs ?? []).isEmpty ? nil : hooks) }
    return dirty
}

/// 这一组钩子里有没有看板钩子：命令带 --board-hook 的，包括改名前指向旧应用路径的
private func isBoardHookGroup(_ g: JSONValue) -> Bool {
    g["hooks"]?.items.contains { ($0["command"]?.string ?? "").contains("--board-hook") } == true
}

private func boardHookGroup(_ command: String) -> JSONValue {
    .object([("hooks", .array([.object([("type", .string("command")), ("command", .string(command)), ("timeout", .number("5"))])]))])
}

/// 在一份配置文件里装上 / 摘掉看板钩子：只动带 --board-hook 的条目，别的钩子和其余的键按原样写回。
/// 改之前先备份，写完重新读一遍核对，不对就恢复。
/// createIfMissing：文件不存在时要不要新建；now：备份文件名里的时间（测试时传固定的）
func updateBoardHooks(file f: String, on: Bool, command: String, createIfMissing: Bool, now: Date = Date()) -> HookFileOutcome {
    let fm = FileManager.default
    // 配置文件可能是个链接（dotfiles 之类）：读写都对着链接指向的那个文件，权限也取它的
    let url = URL(fileURLWithPath: f).resolvingSymlinksInPath()
    let exists = fm.fileExists(atPath: f)
    guard exists || createIfMissing else { return .unchanged }
    let data: Data
    if exists {
        guard let d = try? Data(contentsOf: url) else { return .skipped }
        data = d
    } else {
        data = Data()
    }
    // 解不成 UTF-8 的文件不动，不然写回去时坏字节会被换成乱码；空文件当成还没有任何设置
    guard let original = String(data: data, encoding: .utf8) else { return .skipped }
    guard let root = try? JSONValue.parse(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : original),
          root.objectPairs != nil else { return .skipped }
    var newRoot = root
    guard applyBoardHooks(&newRoot, on: on, command: command) else { return .unchanged }

    // 改之前备份：第一次的那份 .agentdock-backup 一直留着，之后每次改动再留一份带时间的。
    // 同一秒里改了好几次就在后面加两位序号，不覆盖上一次改动前的那份
    let stamp = f + ".agentdock-backup-" + backupStamp.string(from: now)
    var latest = stamp
    var n = 2
    while fm.fileExists(atPath: latest) {
        latest = stamp + "-" + String(format: "%02d", n)
        n += 1
    }
    let mode = exists ? (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int : nil
    if exists {
        // 备份里写的是改动前读到的内容。不复制文件本身：配置是个链接时复制出来的是链接，会跟着变
        let first = f + ".agentdock-backup"
        // 备份写不进去就不改配置：改了却没有能恢复的那一份
        if !fm.fileExists(atPath: first) && !writeBackup(data, to: first, mode: mode) {
            return .failed(tr("备份写不进去，没有改动配置", "could not write the backup; the configuration was not changed"))
        }
        guard writeBackup(data, to: latest, mode: mode) else {
            return .failed(tr("备份写不进去，没有改动配置", "could not write the backup; the configuration was not changed"))
        }
        pruneBackups(of: f)
    }
    func restore() {
        if exists {
            try? data.write(to: url, options: .atomic)
            if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: f) }
        } else {
            try? fm.removeItem(at: url)
        }
    }
    do {
        try Data((newRoot.text + (original.hasSuffix("\n") ? "\n" : "")).utf8).write(to: url, options: .atomic)
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: f) }
    } catch {
        restore()
        return .failed(error.localizedDescription)
    }
    // 核对：重新读一遍，和要写的内容一致才算数
    guard let back = try? Data(contentsOf: url), let text = String(data: back, encoding: .utf8),
          (try? JSONValue.parse(text)) == newRoot else {
        restore()
        return .failed(tr("写进去的内容核对不上", "the file didn't read back as written"))
    }
    return .changed
}

/// 把改动前的内容写成一份备份，权限和原文件一样
private func writeBackup(_ data: Data, to path: String, mode: Int?) -> Bool {
    let fm = FileManager.default
    guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: mode ?? 0o644]) else { return false }
    if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    return true
}

/// 带时间的备份只留最近 backupKeep 份，按创建时间的先后删最旧的。
/// 只认这里自己生成的：普通文件，名字是“前缀 + 时间戳”，同一秒的再加两位序号。用户放在旁边的 settings.json.agentdock-backup-manual/ 这类目录不碰
private func pruneBackups(of f: String) {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: (f as NSString).deletingLastPathComponent)
    let prefix = (f as NSString).lastPathComponent + ".agentdock-backup-"
    let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
    var dated: [(url: URL, created: Date)] = []
    for url in entries where isGeneratedBackup(url, prefix: prefix) {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        dated.append((url, created))
    }
    dated.sort { $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created }
    for (url, _) in dated.dropLast(backupKeep) {
        try? fm.removeItem(at: url)
    }
}

/// 这里自己生成的备份：普通文件，名字是“前缀 + 时间戳”，同一秒的再加两位序号
private func isGeneratedBackup(_ url: URL, prefix: String) -> Bool {
    let name = url.lastPathComponent
    guard name.hasPrefix(prefix),
          String(name.dropFirst(prefix.count)).range(of: "^\\d{8}-\\d{6}(-\\d{2})?$", options: .regularExpression) != nil else { return false }
    return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

/// 装上 / 摘掉钩子：Claude Code（~/.claude/settings.json，以及本机配置里额外 Claude 各账号的 settings.json）、Codex（~/.codex/hooks.json）。
/// 每个文件怎么改见 updateBoardHooks；返回真的改了的文件
@discardableResult
func setBoardHooks(_ on: Bool) -> [String] {
    let home = NSHomeDirectory()
    let files = [home + "/.claude/settings.json", home + "/.codex/hooks.json"] + extraClaudeSettings
    var changed: [String] = []
    for f in files where FileManager.default.fileExists(atPath: f) || (on && f.hasSuffix(".claude/settings.json") && FileManager.default.fileExists(atPath: home + "/.claude")) {
        let create = !FileManager.default.fileExists(atPath: f)
        switch updateBoardHooks(file: f, on: on, command: boardHookCommand, createIfMissing: create) {
        case .changed: changed.append(f)
        case .unchanged: break
        case .skipped: log("board hooks: \(f) 读不懂（不是 JSON 对象），没动")
        case .failed(let why): log("board hooks: \(f) 没改成（\(why)），已恢复")
        }
    }
    log("board hooks \(on ? "on" : "off"): \(changed)")
    return changed
}

/// 改名后（AgentDock → Convoy）已装的钩子还指着旧应用的路径：发现带 --board-hook 却不是现在这条命令，就换成新的
func migrateBoardHooks() {
    let home = NSHomeDirectory()
    let files = [home + "/.claude/settings.json", home + "/.codex/hooks.json"] + extraClaudeSettings
    let stale = files.contains {
        let t = (try? String(contentsOfFile: $0, encoding: .utf8)) ?? ""
        return t.contains("--board-hook") && !t.contains(boardHookCommand)
    }
    if stale { setBoardHooks(true) }
}

/// 钩子现在装着没有（看 Claude Code 的设置）
func boardHooksInstalled() -> Bool {
    let home = NSHomeDirectory()
    let files = [home + "/.claude/settings.json", home + "/.codex/hooks.json"] + extraClaudeSettings
    return files.contains { ((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "").contains("--board-hook") }
}
