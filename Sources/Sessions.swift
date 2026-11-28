import Foundation
import AppKit
import SQLite3

// 只读三个应用在本机留下的会话信息：标题、工作目录、在跑还是空闲、对话记录在哪、怎么直达。

enum Kind: String { case codex, claude, antigravity }

/// 应用按 bundle id 找，找不到再用常见安装位置。Codex 桌面版在有的机器上叫 ChatGPT.app、有的叫 Codex.app
private func appPath(_ bundle: String, _ fallback: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path ?? fallback
}
let codexAppPath = appPath("com.openai.codex", FileManager.default.fileExists(atPath: "/Applications/Codex.app") ? "/Applications/Codex.app" : "/Applications/ChatGPT.app")
let claudeAppPath = appPath("com.anthropic.claudefordesktop", "/Applications/Claude.app")
/// Antigravity 同样按 bundle id 找；找不到再用常见安装位置（/Applications，其次 ~/Applications）
let antigravityAppPath = appPath("com.google.antigravity",
    ["/Applications/Antigravity.app", NSHomeDirectory() + "/Applications/Antigravity.app"].first { FileManager.default.fileExists(atPath: $0) } ?? "/Applications/Antigravity.app")
/// Antigravity 自带的命令行（agentapi 在这里）
let agyServer = antigravityAppPath + "/Contents/Resources/bin/language_server"

// MARK: 本机配置：额外的 Claude 桌面应用（多账号启动器之类）
// ~/.agentdock/config.json，只在本机、不随应用分发。例：
// {
//   "claudeExtra": [{ "label": "Claude", "appPath": "~/xxx/Claude.app", "accountsRoot": "~/xxx/accounts" }],
//   "claudeCLI": ["~/.local/bin/xxx", "cli"]
// }
// accountsRoot 下每个账号一个目录：<账号>/app/claude-code-sessions（会话表）、<账号>/config/sessions（进程状态）、
// <账号>/config/projects（对话记录）、<账号>/config/settings.json（Claude Code 设置）。
// claudeCLI：看板汇总用的 Claude Code 命令行，第一个是程序，后面是固定放在最前的参数

struct ExtraClaude { let label: String; let appPath: String; let accountsRoot: String }

private func expandHome(_ p: String) -> String { p.hasPrefix("~/") ? NSHomeDirectory() + String(p.dropFirst(1)) : p }

let localConfig: [String: Any] = {
    let f = NSHomeDirectory() + "/.agentdock/config.json"
    guard let d = FileManager.default.contents(atPath: f) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
}()

let extraClaudes: [ExtraClaude] = ((localConfig["claudeExtra"] as? [[String: Any]]) ?? []).compactMap { o in
    guard let app = o["appPath"] as? String else { return nil }
    return ExtraClaude(label: o["label"] as? String ?? "Claude", appPath: expandHome(app), accountsRoot: expandHome(o["accountsRoot"] as? String ?? ""))
}

/// 配置里的 Claude 命令行（程序 + 固定参数）
let configClaudeCLI: [String]? = (localConfig["claudeCLI"] as? [String]).map { $0.enumerated().map { $0.offset == 0 ? expandHome($0.element) : $0.element } }

/// 官方 Claude 桌面版的显示名：额外实例也叫“Claude”时加个后缀区分（名字要唯一）
let claudeStdLabel = extraClaudes.contains { $0.label == "Claude" } ? tr("Claude（官方）", "Claude (official)") : "Claude"

/// 所有 Claude 桌面应用：额外实例在前，官方版在后
let claudeApps: [(label: String, path: String)] = extraClaudes.map { ($0.label, $0.appPath) } + [(claudeStdLabel, claudeAppPath)]

/// 各额外实例下每个账号的 Claude Code 设置文件（装看板钩子用）
var extraClaudeSettings: [String] {
    extraClaudes.flatMap { e -> [String] in
        guard !e.accountsRoot.isEmpty else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: e.accountsRoot)) ?? []).map { e.accountsRoot + "/\($0)/config/settings.json" }
    }
}


struct Session: Identifiable, Equatable {
    let id: String
    let kind: Kind
    let rawId: String       // 应用自己的会话 id：Codex 线程 id / Claude 的 local_… / Antigravity 对话 id
    var transcript: URL?    // 对话记录文件
    let app: String         // 显示用的应用名
    var title: String
    let project: String     // 工作目录最后一级
    var running: Bool
    var updated: Date
    let link: URL?          // 直达这条会话；Antigravity 没有这种链接
    let appPath: String     // 用哪个应用打开链接（两个 Claude 都注册了 claude://，必须指定）
    var cwd = ""            // 完整工作目录，侧栏按它分组
    var model = ""          // 显示用：模型 + 强度，例如“Opus 5.5 高强度”
    var perm = ""           // 显示用：权限模式，例如“跳过权限确认”
    var bg = 0              // 还在跑的后台任务数（Claude）
    var procStart: Date?    // Claude：当前进程启动时间（判断后台任务是不是进程重启前开的）
    var outputAt: Date?     // 最近一次有新输出的时间（判断未读）；没有单独记录时用 updated
    var waiting = false     // 在等你批准或回答（Claude 进程状态是 waiting）
    var asking = false      // 在等的是回答问题（waitingFor 是 “input needed”），不是批准
    var nativeUnread = false // 原应用自己认为这条会话有未读（以原应用为准，和 Convoy 双向同步）
    var pid: Int32?          // Claude：正在服务这条会话的进程（它退出时马上刷新）
}

/// claude-opus-5-5 → Opus 5.5；gpt-6.2-sol → GPT-6.2 Sol
func modelName(_ id: String) -> String {
    if id.hasPrefix("claude-") {
        let p = id.dropFirst(7).split(separator: "-").map(String.init)
        guard let fam = p.first else { return id }
        let ver = p.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return fam.prefix(1).uppercased() + fam.dropFirst() + (ver.isEmpty ? "" : " " + ver)
    }
    if id.hasPrefix("gpt-") {
        let p = id.split(separator: "-").map(String.init)
        return "GPT-" + p[1] + p.dropFirst(2).map { " " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
    return id
}

/// 只用于显示，不和原应用菜单比对
private let effortZh = isEnglish
    ? ["minimal": "minimal", "low": "low", "medium": "medium", "high": "high", "xhigh": "extra high", "max": "max"]
    : ["minimal": "最低", "low": "低", "medium": "中", "high": "高", "xhigh": "超高", "max": "最高"]
private let claudePerm = isEnglish
    ? ["default": "Ask before edits", "acceptEdits": "Accept edits", "plan": "Plan", "bypassPermissions": "Bypass permissions", "auto": "Auto"]
    : ["default": "手动", "acceptEdits": "接受编辑", "plan": "计划", "bypassPermissions": "跳过权限确认", "auto": "自动"]

let listWindow: TimeInterval = 365 * 24 * 3600

private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser

func json(_ s: Substring) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
}

private func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
}

private func mtime(_ f: URL) -> Date? {
    try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

/// root 下 maxDepth 层以内、最近 7 天改过、满足 match 的文件
private func recentFiles(_ root: URL, maxDepth: Int, now: Date, _ match: (URL) -> Bool) -> [(URL, Date)] {
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                options: [.skipsHiddenFiles]) else { return [] }
    var out: [(URL, Date)] = []
    for case let f as URL in e {
        if e.level > maxDepth { e.skipDescendants(); continue }
        guard match(f), let m = mtime(f), now.timeIntervalSince(m) < listWindow else { continue }
        out.append((f, m))
    }
    return out
}

/// 读文件末尾 bytes 字节，按行切开，丢掉被截断的第一行
func tailLines(_ url: URL, _ bytes: UInt64) -> [Substring] {
    guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? h.close() }
    let size = try! h.seekToEnd()
    let start = size > bytes ? size - bytes : 0
    try! h.seek(toOffset: start)
    var lines = String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
}

/// 扫描都在一个串行队列里跑，缓存不用加锁。文件没变就直接用上次的结果
private var cache: [String: (Date, Session?)] = [:]

private func cached(_ f: URL, _ m: Date, _ make: () -> Session?) -> Session? {
    if let (cm, s) = cache[f.path], cm == m { return s }
    let s = make()
    cache[f.path] = (m, s)
    return s
}

// MARK: Codex：~/.codex/sessions/年/月/日/rollout-*-<id>.jsonl，标题在 session_index.jsonl

private func firstLine(_ url: URL) -> Substring {
    let h = try! FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var data = Data()
    while !data.contains(UInt8(ascii: "\n")) {
        let chunk = h.readData(ofLength: 256 * 1024)
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first ?? ""
}

/// Codex 线程最近一次的 turn_context（模型、强度、权限）。一轮很长时末尾读不到，就整份文件找一次并记住
private var codexCtx: [String: [String: Any]] = [:]

/// 从文件末尾一段段往前找最后一条 turn_context（Codex 长会话的记录文件可能有几百 MB，不整份读）
private func lastTurnContext(_ f: URL) -> [String: Any]? {
    guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
    defer { try? h.close() }
    let size = try! h.seekToEnd()
    let chunk: UInt64 = 4 * 1024 * 1024
    var end = size
    let marker = Data("\"type\":\"turn_context\"".utf8)
    while end > 0 {
        let start = end > chunk ? end - chunk : 0
        try! h.seek(toOffset: start)
        let d = h.readData(ofLength: Int(end - start))
        if let r = d.range(of: marker, options: .backwards) {
            // 取出这一行：往前到上一个换行，往后到下一个换行（行可能跨出这一段，就多读一点）
            let lineStart = d[..<r.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? d.startIndex
            try! h.seek(toOffset: start + UInt64(lineStart - d.startIndex))
            var line = Data()
            while true {
                let c = h.readData(ofLength: 256 * 1024)
                if c.isEmpty { break }
                if let nl = c.firstIndex(of: UInt8(ascii: "\n")) { line.append(c[..<nl]); break }
                line.append(c)
            }
            return (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["payload"] as? [String: Any]
        }
        // 往前挪，留一点重叠防止标记被切断
        end = start == 0 ? 0 : start + UInt64(marker.count)
        if start == 0 { break }
    }
    return nil
}

private let isoFull: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlain = ISO8601DateFormatter()
func isoDate(_ s: String) -> Date? { isoFull.date(from: s) ?? isoPlain.date(from: s) }

/// 标着在跑、但超过这么久没写过记录的，按已中断算
private let staleAfter: TimeInterval = 15 * 60

/// Codex 的已读回执：first_unread_turn 有值就是有未读轮次。库是 WAL 模式，普通只读打开（Codex 开着时 -wal/-shm 都在）
private func codexUnread() -> [String: Bool] {
    var out: [String: Bool] = [:]
    var db: OpaquePointer?
    let path = home.appendingPathComponent(".codex/state_5.sqlite").path
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return out }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "select thread_id, coalesce(first_unread_turn, '') from thread_read_receipts", -1, &st, nil) == SQLITE_OK else { return out }
    defer { sqlite3_finalize(st) }
    while sqlite3_step(st) == SQLITE_ROW {
        let id = String(cString: sqlite3_column_text(st, 0))
        out[id] = !String(cString: sqlite3_column_text(st, 1)).isEmpty
    }
    return out
}

func scanCodex(now: Date) -> [Session] {
    let unread = codexUnread()
    var titles: [String: String] = [:]
    if let s = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) {
        for l in s.split(separator: "\n") {
            if let o = json(l), let id = o["id"] as? String, let n = o["thread_name"] as? String { titles[id] = n }
        }
    }
    let files = recentFiles(home.appendingPathComponent(".codex/sessions"), maxDepth: 4, now: now) { $0.pathExtension == "jsonl" }
    return files.compactMap { f, m in
        let id = String(f.deletingPathExtension().lastPathComponent.suffix(36))
        let base = cached(f, m) {
            let p = json(firstLine(f))?["payload"] as? [String: Any]
            // codex exec 这类命令行任务没有窗口，不列
            guard p?["originator"] as? String == "Codex Desktop" else { return nil }
            // 末尾 256KB 里找不到开始/结束标记，说明这一轮已经跑了很长，按在跑算
            var running: Bool?
            var ctx: [String: Any]?
            var edge: Date?   // 最后一次开始或结束一轮的时间：列表按它排序，跑的过程中位置不动
            for l in tailLines(f, 256 * 1024).reversed() {
                guard let o = json(l), let pl = o["payload"] as? [String: Any] else { continue }
                if ctx == nil, o["type"] as? String == "turn_context" { ctx = pl }
                if running == nil, o["type"] as? String == "event_msg", let t = pl["type"] as? String,
                   ["task_started", "task_complete", "turn_aborted"].contains(t) {
                    running = t == "task_started"
                    edge = (o["timestamp"] as? String).flatMap(isoDate)
                }
                if running != nil, ctx != nil { break }
            }
            if let c = ctx { codexCtx[f.path] = c } else { ctx = codexCtx[f.path] ?? lastTurnContext(f); codexCtx[f.path] = ctx }
            let cwd = p?["cwd"] as? String ?? ""
            let effort = (ctx?["effort"] as? String).map { effortZh[$0] ?? $0 } ?? ""
            let sandbox = ((ctx?["sandbox_policy"] as? [String: Any])?["type"] as? String) ?? ""
            let approval = ctx?["approval_policy"] as? String ?? ""
            let perm = sandbox == "danger-full-access" ? tr("完全访问", "Full access") : approval == "on-request" ? tr("请求批准", "Ask for approval") : approval
            return Session(id: "codex-" + id, kind: .codex, rawId: id, transcript: f, app: "Codex", title: "",
                           project: (cwd as NSString).lastPathComponent,
                           running: running ?? true, updated: edge ?? m,
                           link: URL(string: "codex://threads/" + id), appPath: codexAppPath,
                           cwd: cwd, model: [(ctx?["model"] as? String).map(modelName) ?? "", effort].filter { !$0.isEmpty }.joined(separator: " "),
                           perm: perm)
        }
        guard var s = base else { return nil }
        // 标题会被改名，不进缓存
        s.title = clean(titles[id] ?? tr("未命名 ", "Untitled ") + id.prefix(8))
        s.running = s.running && now.timeIntervalSince(m) < staleAfter
        s.nativeUnread = unread[id] ?? false
        return s
    }
}

// MARK: Claude 桌面端：claude-code-sessions/**/local_<id>.json 是会话表，config/sessions/<pid>.json 是活着的进程和忙闲

private struct ClaudeInstance {
    let label: String
    let appPath: String
    let metaDir: URL     // 会话表
    let liveDir: URL     // 每个在跑的 Claude Code 进程一个 <pid>.json
    let projectsDir: URL // 对话记录：projects/<目录>/<cli 会话 id>.jsonl
}

/// 要盯住的目录（文件变动通知用）和每个目录里认哪些文件
func watchRoots() -> [(dir: String, accept: (String) -> Bool)] {
    var out: [(dir: String, accept: (String) -> Bool)] = []
    for i in claudeInstances() {
        out.append((i.metaDir.path, { $0.hasSuffix(".json") }))
        out.append((i.liveDir.path, { $0.hasSuffix(".json") }))
        out.append((i.projectsDir.path, { $0.hasSuffix(".jsonl") }))
    }
    let codex = home.appendingPathComponent(".codex").path
    out.append((codex, { p in
        let r = p.dropFirst(codex.count + 1)
        return r.hasPrefix("sessions/") || r.hasPrefix("session_index.jsonl") || r.hasPrefix("state_5.sqlite")
    }))
    let agy = home.appendingPathComponent(".gemini/antigravity").path
    out.append((agy, { p in
        let r = p.dropFirst(agy.count + 1)
        return r.hasPrefix("conversation_summaries.db") || r.hasPrefix("annotations/") || r.hasSuffix("transcript_full.jsonl")
    }))
    return out
}

private func claudeInstances() -> [ClaudeInstance] {
    var out = [ClaudeInstance(label: claudeStdLabel, appPath: claudeAppPath,
                              metaDir: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
                              liveDir: home.appendingPathComponent(".claude/sessions"),
                              projectsDir: home.appendingPathComponent(".claude/projects"))]
    for e in extraClaudes where !e.accountsRoot.isEmpty {
      let acc = URL(fileURLWithPath: e.accountsRoot)
      for a in (try? fm.contentsOfDirectory(atPath: acc.path)) ?? [] {
        let d = acc.appendingPathComponent(a)
        out.append(ClaudeInstance(label: e.label, appPath: e.appPath,
                                  metaDir: d.appendingPathComponent("app/claude-code-sessions"),
                                  liveDir: d.appendingPathComponent("config/sessions"),
                                  projectsDir: d.appendingPathComponent("config/projects")))
      }
    }
    return out
}

/// 桌面会话 id → (是否正在跑, 进程当前写的会话 id)。只认进程还活着的
private func claudeLive(_ dir: URL) -> [String: (busy: Bool, waiting: Bool, cli: String, start: Date?, why: String, pid: Int32)] {
    var out: [String: (busy: Bool, waiting: Bool, cli: String, start: Date?, why: String, pid: Int32)] = [:]
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
        guard let d = try? Data(contentsOf: f),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = o["pid"] as? Int32, kill(pid, 0) == 0,
              let host = o["hostSessionId"] as? String else { continue }
        out[host] = (o["status"] as? String == "busy", o["status"] as? String == "waiting", o["sessionId"] as? String ?? "",
                     (o["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }, o["waitingFor"] as? String ?? "", pid)
    }
    return out
}

/// 会话表里每条会话的查看时间和最后一轮结束时间（毫秒），用来推算未读
private var claudeTimes: [String: (focused: Double, edge: Double)] = [:]

/// 读不到 Claude 侧栏时，按会话表推算它的未读蓝点。
/// lastFocusedAt 只在切到这条会话时写，离开时不写；离开的时间就是下一条被切到的会话的 lastFocusedAt。
/// 离开之后才结束的那一轮算未读；最后切到的那条就是还开着的，不算
private func claudeFileUnread(_ sessions: [Session]) -> [String: Bool] {
    let focus = sessions.compactMap { claudeTimes[$0.rawId]?.focused }.sorted()
    var out: [String: Bool] = [:]
    for s in sessions {
        guard let t = claudeTimes[s.rawId] else { continue }
        guard let left = focus.first(where: { $0 > t.focused }) else { out[s.rawId] = false; continue }
        out[s.rawId] = t.edge > left + 1000
    }
    return out
}

func scanClaude(now: Date) -> [Session] {
    claudeInstances().flatMap { inst -> [Session] in
        let live = claudeLive(inst.liveDir)
        let projectDirs = (try? fm.contentsOfDirectory(at: inst.projectsDir, includingPropertiesForKeys: nil)) ?? []
        let files = recentFiles(inst.metaDir, maxDepth: 3, now: now) {
            $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json"
        }
        let list: [Session] = files.compactMap { f, m in
            let base = cached(f, m) {
                guard let d = try? Data(contentsOf: f),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["isArchived"] as? Bool != true,
                      let sid = o["sessionId"] as? String else { return nil }
                // 会话表里登记的两个底层会话 id，记在 cwd 字段旁边，扫描时再和运行中进程的比
                let cands = [o["lastAssistantCliSessionId"] as? String, o["cliSessionId"] as? String].compactMap { $0 }
                let transcript = cands.lazy.compactMap { c in
                    projectDirs.lazy.map { $0.appendingPathComponent(c + ".jsonl") }.first { fm.fileExists(atPath: $0.path) }
                }.first
                let last = (o["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? m
                let focused = (o["lastFocusedAt"] as? Double) ?? 0
                claudeTimes[sid] = (focused, (o["lastTurnEdgeAt"] as? Double) ?? (o["lastActivityAt"] as? Double) ?? 0)
                let cwd = o["cwd"] as? String ?? ""
                let effort = (o["effort"] as? String).map { tr((effortZh[$0] ?? $0) + "强度", (effortZh[$0] ?? $0) + " effort") } ?? ""
                return Session(id: "claude-" + sid, kind: .claude, rawId: sid, transcript: transcript, app: inst.label,
                               title: clean(o["title"] as? String ?? tr("未命名", "Untitled")),
                               project: (cwd as NSString).lastPathComponent,
                               running: false, updated: last,
                               link: URL(string: "claude://claude.ai/epitaxy/" + sid), appPath: inst.appPath,
                               cwd: cwd, model: [(o["model"] as? String).map(modelName) ?? "", effort].filter { !$0.isEmpty }.joined(separator: " "),
                               perm: (o["permissionMode"] as? String).map { claudePerm[$0] ?? $0 } ?? "")
            }
            guard var s = base else { return nil }
            let lv = live[s.rawId]
            s.waiting = lv?.waiting ?? false
            s.asking = s.waiting && (lv?.why ?? "").contains("input")
            s.running = (lv?.busy ?? false) || s.waiting
            // Claude 重启或续接会话时会换一个新的底层会话文件，会话表要等新文件里第一条回复写完才更新；
            // 所以运行中的会话以进程实际在写的文件为准，再和登记的文件比，取最近写过的那个
            // 后台任务跟着进程走：进程还活着才统计
            s.procStart = lv?.start
            s.pid = lv?.pid
            if let since = lv?.start, let f = s.transcript { s.bg = claudeBgRunning(f, since: since) }
            if let c = lv?.cli, !c.isEmpty,
               let f = projectDirs.lazy.map({ $0.appendingPathComponent(c + ".jsonl") }).first(where: { fm.fileExists(atPath: $0.path) }),
               f != s.transcript {
                let newer = (mtime(f) ?? .distantPast) >= (s.transcript.flatMap(mtime) ?? .distantPast)
                if newer { s.transcript = f }
            }
            // 会话表文件点开过就会被改写，按最后一次对话活动算时间
            return s.running || now.timeIntervalSince(s.updated) < listWindow ? s : nil
        }
        // 未读以 Claude 侧栏上的蓝点为准（你在 Claude 里看过、手动标未读都跟着变）；侧栏里找不到这一行才按会话表推算
        let side = ClaudeSidebar.shared.snapshot(inst.appPath)
        if let side, list.contains(where: { side[$0.title] == nil && now.timeIntervalSince($0.updated) < 86400 }) {
            ClaudeSidebar.shared.reread(inst.appPath)   // 有最近的会话在侧栏表里找不到：可能是新开的，重读一遍侧栏
        }
        let guess = claudeFileUnread(list)
        return list.map { s in
            var s = s
            s.nativeUnread = side?[s.title] ?? guess[s.rawId] ?? false
            return s
        }
    }
}

// MARK: Antigravity：~/.gemini/antigravity/conversation_summaries.db

/// 全局默认的权限预设（AGENT_PERMISSION_PRESET_TURBO 这类），由 Model 定时从本地服务读来，只在扫描队列里读写
var agyGlobalPreset = ""

/// AGENT_PERMISSION_PRESET_REQUEST_REVIEW → Request Review，和 Antigravity 界面上的叫法一致
private func presetName(_ raw: String) -> String {
    raw.replacingOccurrences(of: "AGENT_PERMISSION_PRESET_", with: "").split(separator: "_")
        .map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: " ")
}

/// Antigravity 自己的未读规则：标了未读，或者最后修改比最后查看新
private func agyUnread(_ cid: String, modified: Double) -> Bool {
    let f = home.appendingPathComponent(".gemini/antigravity/annotations/\(cid).pbtxt")
    guard let t = try? String(contentsOf: f, encoding: .utf8) else { return false }
    if t.contains("marked_as_unread:true") { return true }
    let viewed = t.firstMatch(of: #/last_user_view_time:\{seconds:(\d+)/#).flatMap { Double($0.1) } ?? 0
    return modified > viewed + 1
}

/// 单个会话自己设过的预设写在 annotations/<id>.pbtxt 里；没写就是用全局默认
private func agyPreset(_ cid: String) -> String {
    let f = home.appendingPathComponent(".gemini/antigravity/annotations/\(cid).pbtxt")
    if let t = try? String(contentsOf: f, encoding: .utf8), let m = t.firstMatch(of: #/permission_preset:(AGENT_PERMISSION_PRESET_[A-Z_]+)/#) {
        return presetName(String(m.1))
    }
    return agyGlobalPreset.isEmpty ? "" : presetName(agyGlobalPreset)
}

func scanAntigravity() -> [Session] {
    let path = home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path
    let sql = """
        select conversation_id, title, status, not_fully_idle,
               cast(strftime('%s', substr(case when last_user_input_time > '1971' then last_user_input_time else last_modified_time end, 1, 19)) as integer), workspace_uris,
               cast(strftime('%s', substr(last_modified_time, 1, 19)) as integer)
        from conversation_summaries
        where nesting_depth = 0 and substr(last_modified_time, 1, 19) > datetime('now', '-365 day')
        """
    // 库是 WAL 模式。Antigravity 没在写时 -wal/-shm 会消失，系统自带的 SQLite 只读打开就会报“打不开”；
    // 这时数据已全部在主文件里，改用不可变快照方式打开
    var db: OpaquePointer?
    var st: OpaquePointer?
    for uri in [path, "file:\(path)?immutable=1"] {
        sqlite3_close(db)
        db = nil
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { continue }
        sqlite3_busy_timeout(db, 1000) // Antigravity 正在写库时等一会儿，不然这一轮会读成空列表
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK { break }
        st = nil
    }
    defer { sqlite3_finalize(st); sqlite3_close(db) }
    guard st != nil else { return [] }
    func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    var out: [Session] = []
    while sqlite3_step(st) == SQLITE_ROW {
        let cid = text(0)
        // 看板汇总临时开的对话，用完就删，不进列表
        if boardScratchTitles.contains(text(1)) { continue }
        let ws = (try? JSONSerialization.jsonObject(with: Data(text(5).utf8)) as? [String])?.first
        out.append(Session(id: "agy-" + cid, kind: .antigravity, rawId: cid,
                           transcript: home.appendingPathComponent(".gemini/antigravity/brain/\(cid)/.system_generated/logs/transcript_full.jsonl"),
                           app: "Antigravity", title: clean(text(1).isEmpty ? tr("未命名", "Untitled") : text(1)),
                           project: ws.flatMap { URL(string: $0)?.lastPathComponent } ?? "",
                           running: text(2) != "CASCADE_RUN_STATUS_IDLE" || sqlite3_column_int(st, 3) != 0,
                           updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 4))),
                           link: nil, appPath: antigravityAppPath,
                           cwd: ws.flatMap { URL(string: $0)?.path } ?? "", perm: agyPreset(cid),
                           outputAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 6))),
                           nativeUnread: agyUnread(cid, modified: Double(sqlite3_column_int64(st, 6)))))
    }
    return out
}

func scanSessions() -> [Session] {
    if demoMode { return demoSessions() }
    let now = Date()
    return (scanCodex(now: now) + scanClaude(now: now) + scanAntigravity()).sorted { $0.updated > $1.updated }
}
