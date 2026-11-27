import Foundation

// 把三个应用的对话记录解析成统一的条目列表：用户消息、助手回复、思考、工具调用（含参数和输出）。
// 只读文件末尾一段，够显示最近的对话。条目 id 取自记录本身，刷新时不变，界面靠它保留展开状态。

struct Item: Encodable, Equatable {
    let id: String
    let kind: String          // user / assistant / thinking / tool / note（过程说明）
    var text: String = ""
    var name: String = ""     // 工具原名
    var verb: String = ""     // 给人看的动作：运行命令、读取、编辑…
    var summary: String = ""  // 动作的对象：命令、文件名、搜索词
    var input: String = ""
    var output: String = ""
    var done: Bool = true     // 工具是否已经有结果
    var ts: String = ""       // ISO 时间
    var took: Int = 0         // turnend：这一轮用时（毫秒）
    var cat: String = ""      // Codex 步骤类别：read / search / list / cmd / edit / mcp / wait，用来拼原生那种“已读取文件 运行了命令”摘要
    var files: [FileStat] = [] // turnend：这一轮改了哪些文件
}

/// 一轮里改动的文件：新建 / 修改 / 删除，增删行数
struct FileStat: Encodable, Equatable {
    let path: String
    var kind: String
    var add: Int
    var del: Int
}

private let tailBytes: UInt64 = 6 * 1024 * 1024
private let maxItems = 400
private let maxField = 4000

private func cut(_ s: String) -> String {
    s.count > maxField ? String(s.prefix(maxField)) + tr("\n…（已截断）", "\n…(truncated)") : s
}

private func isNoise(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty || t.hasPrefix("<") || t.hasPrefix("# AGENTS.md") || t.hasPrefix("[Request interrupted")
}

private func pretty(_ v: Any) -> String {
    if let s = v as? String { return s }
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return "\(v)" }
    return String(decoding: d, as: UTF8.self)
}

private func firstLine(_ s: String, _ n: Int = 120) -> String {
    let l = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return l.count > n ? String(l.prefix(n)) + "…" : l
}

private func base(_ p: String) -> String { (p as NSString).lastPathComponent }

private func str(_ args: [String: Any], _ keys: String...) -> String {
    for k in keys {
        if let v = args[k] as? String, !v.isEmpty { return v }
        if let v = args[k] as? [String], !v.isEmpty { return v.joined(separator: " ") }
    }
    return ""
}

/// 几个要在逻辑里比对的动作名（Codex 步骤分类用），统一在这里取，两种语言都对得上
private enum V {
    static let runCommand = tr("运行命令", "Run command")
    static let wait = tr("等待", "Wait")
    static let waitBackground = tr("等待后台任务", "Wait for background task")
    static let editFile = tr("编辑文件", "Edit file")
}

/// 工具名 + 参数 → (动作, 对象)。参照 Claude / Codex 原生界面的说法，原始参数只在展开时显示
private func label(_ name: String, _ args: [String: Any]) -> (String, String) {
    let short = name.hasPrefix("mcp__") ? String(name.split(separator: "_").last ?? "") : name
    switch name {
    // Claude Code
    case "Bash":
        let d = str(args, "description")
        return d.isEmpty ? (V.runCommand, firstLine(str(args, "command"))) : (V.runCommand, d)
    case "Read": return (tr("读取", "Read"), base(str(args, "file_path")))
    case "Edit", "MultiEdit": return (tr("编辑", "Edit"), base(str(args, "file_path")))
    case "Write": return (tr("写入", "Write"), base(str(args, "file_path")))
    case "NotebookEdit": return (tr("编辑", "Edit"), base(str(args, "notebook_path")))
    case "Grep": return (tr("搜索", "Search"), firstLine(str(args, "pattern")))
    case "Glob": return (tr("查找文件", "Find files"), firstLine(str(args, "pattern")))
    case "WebSearch": return (tr("搜索网页", "Search web"), firstLine(str(args, "query")))
    case "WebFetch": return (tr("读取网页", "Fetch page"), URL(string: str(args, "url"))?.host ?? "")
    case "Agent", "Task": return (tr("子任务", "Subtask"), firstLine(str(args, "description")))
    case "Skill": return (tr("使用技能", "Use skill"), str(args, "skill"))
    case "ToolSearch": return (tr("加载工具", "Load tools"), "")
    case "TodoWrite", "mcp__ccd_turn__update_plan": return (tr("更新任务列表", "Update task list"), "")
    case "mcp__ccd_turn__wrap_up": return (tr("整理小结", "Wrap up"), "")
    case "AskUserQuestion": return (tr("向你提问", "Ask you"), "")
    case "Artifact": return (tr("发布页面", "Publish page"), "")
    case "SendUserFile": return (tr("发送文件", "Send file"), "")
    // Codex
    case "wait": return (V.waitBackground, "")
    case "sleep": return (V.wait, "")
    case "exec_command": return (V.runCommand, firstLine(str(args, "cmd")))
    case "apply_patch": return (V.editFile, "")
    // Antigravity
    case "run_command": return (V.runCommand, firstLine(str(args, "CommandLine")))
    case "read_file", "view_file": return (tr("读取", "Read"), base(str(args, "AbsolutePath", "path", "file_path")))
    case "edit_file": return (tr("编辑", "Edit"), base(str(args, "TargetFile", "AbsolutePath", "path")))
    case "write_file": return (tr("写入", "Write"), base(str(args, "TargetFile", "AbsolutePath", "path")))
    case "search_web": return (tr("搜索网页", "Search web"), firstLine(str(args, "query", "Query")))
    case "manage_task": return (tr("管理任务", "Manage tasks"), "")
    case "invoke_subagent": return (tr("子任务", "Subtask"), "")
    default:
        if name.hasPrefix("mcp__Claude_Browser") || name.hasPrefix("mcp__claude-in-chrome") { return (tr("操作浏览器", "Use browser"), short) }
        return (short, "")
    }
}

/// Codex 的 exec / js 是一段脚本，里面调用 tools.xxx(...)；挑出里面的命令来说明这一步
private func codexScriptLabel(_ code: String) -> (String, String) {
    let calls = code.matches(of: #/tools\.([A-Za-z0-9_]+)\(/#).map { String($0.1) }
    let cmds = code.matches(of: #/"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"/#).map { String($0.1).replacingOccurrences(of: "\\\"", with: "\"") }
    if !cmds.isEmpty {
        return cmds.count == 1 ? (V.runCommand, firstLine(cmds[0])) : (tr("运行 \(cmds.count) 条命令", "Run \(cmds.count) commands"), firstLine(cmds[0]))
    }
    if let c = calls.first(where: { $0 != "text" }) {
        if c.contains("imagegen") { return (tr("生成图片", "Generate image"), "") }
        if c.contains("search") { return (tr("搜索网页", "Search web"), "") }
        if c == "write_stdin" { return (tr("向终端输入", "Write to terminal"), "") }
        return label(c, [:])
    }
    return (tr("运行脚本", "Run script"), "")
}

struct BgTask: Encodable {
    let id: String
    var started = ""
    var desc: String
    var status: String     // running / completed / failed / killed
    var summary: String = ""
    var output: String = "" // 输出文件末尾
    let outputFile: String
}

/// Claude 每轮结束时的“下一步”小框（wrap_up）：小结、问题、回复按钮
struct Suggestion: Encodable {
    let recap: String
    let ask: String
    let actions: [String]
}

struct PlanItem: Encodable {
    let content: String
    var status: String     // pending / in_progress / completed
}

/// Claude 的 AskUserQuestion：问了、还没回答的那一组问题
struct AskOption: Encodable { let label: String; let description: String }
struct AskQ: Encodable { let question: String; let header: String; let multiSelect: Bool; let options: [AskOption] }
struct PendingAsk: Encodable { let id: String; let questions: [AskQ] }

struct Detail: Encodable {
    let items: [Item]
    var tasks: [BgTask]
    let suggestion: Suggestion?
    let plan: [PlanItem]   // 最新一轮的任务清单
    var model = ""         // 记录里看到的模型（Antigravity 用它显示下拉上的当前模型）
    var hidden = 0         // 没推给页面的更早条数
    var steps = 0          // Antigravity：记录里最大的步骤号 + 1，实时预览从这附近开始取
    var ask: PendingAsk?   // Claude：在等你回答的问题
}

private struct Builder {
    var ask: PendingAsk?
    var items: [Item] = []
    var index: [String: Int] = [:]
    var tasks: [String: BgTask] = [:]
    var taskOrder: [String] = []
    var suggestion: Suggestion?
    var plan: [PlanItem] = []
    var model = ""
    var steps = 0

    mutating func add(_ it: Item) {
        if it.kind == "tool", uiTools.contains(it.name) { return }
        if it.kind != "tool", isNoise(it.text) && it.kind == "user" { return }
        if it.kind != "tool", it.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // 同一步骤被重写（比如先写“进行中”再写“完成”）：后写的覆盖先写的，不重复显示
        if let i = index[it.id] { items[i] = it; return }
        index[it.id] = items.count
        items.append(it)
    }

    mutating func output(_ id: String, _ out: String) {
        guard let i = index[id] else { return }
        items[i].output = cut(out)
        items[i].done = true
    }

    var result: [Item] { Array(items.suffix(maxItems)) }
}

func readTranscript(_ s: Session) -> [Item] { readDetail(s).items }

// MARK: 历史骨架：整份记录里只挑提问、回复（Codex 再加每轮用时），增量读取并缓存。
// 记录文件可能有几百 MB（大多是工具输出），完整步骤只解析末尾一段，更早的部分靠骨架补齐。

private struct Hist {
    var offset: UInt64 = 0
    var carry = Data()
    var items: [Item] = []
    var lastUser: Int?
    var bgTools = Set<String>()   // Claude：run_in_background 的工具调用 id
    var bgRunning: [String: String] = [:] // Claude：启动了、还没收到完成通知的后台任务 id → 启动时间
    var jobTools: [String: String] = [:]  // Claude：定时任务 / 监听的工具调用 id → 说明
    var jobs: [String: BgJob] = [:]       // Claude：还没取消的定时任务（循环的）和监听
}

/// Claude 的定时任务（CronCreate，循环）和监听（Monitor）：不会有完成通知，到期或被取消才结束
private struct BgJob {
    var ts: String
    var until: Date?
    var desc: String
}
private var hists: [String: Hist] = [:]
private let histLock = NSLock()

private func has(_ line: UnsafeRawBufferPointer, _ needle: String) -> Bool {
    needle.utf8CString.withUnsafeBufferPointer { n in
        memmem(line.baseAddress, line.count, n.baseAddress, n.count - 1) != nil
    }
}

private func histLine(_ kind: Kind, _ line: UnsafeRawBufferPointer, _ h: inout Hist) {
    switch kind {
    case .codex:
        let done = has(line, "\"task_complete\"")
        guard done || (has(line, "\"item_completed\"") && (has(line, "\"UserMessage\"") || has(line, "\"AgentMessage\""))) else { return }
    case .claude:
        // 后台任务：启动（run_in_background 的调用 + 结果里的任务 id）和完成通知
        if has(line, "\"run_in_background\":true") || has(line, "running in background with ID") || has(line, "<task-notification>")
            || has(line, "\"name\":\"CronCreate\"") || has(line, "\"name\":\"CronDelete\"") || has(line, "\"name\":\"Monitor\"")
            || has(line, "\"name\":\"TaskStop\"") || has(line, "Scheduled recurring job") || has(line, "Monitor started") {
            claudeBgLine(line, &h)
        }
        guard has(line, "\"type\":\"assistant\"") || (has(line, "\"type\":\"user\"") && !has(line, "\"tool_result\"")) else { return }
    case .antigravity:
        guard has(line, "USER_INPUT") || has(line, "PLANNER_RESPONSE") || has(line, "[Message]") else { return }
    }
    guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
    func texts(_ c: Any?) -> String { ((c as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined() }
    switch kind {
    case .codex:
        let ts = o["timestamp"] as? String ?? ""
        guard let p = o["payload"] as? [String: Any] else { return }
        if p["type"] as? String == "task_complete" {
            let ms = (p["duration_ms"] as? Int) ?? Int((p["duration_ms"] as? String) ?? "") ?? 0
            if let u = h.lastUser, ms > 0 {
                h.items.insert(Item(id: "worked-\(p["turn_id"] ?? ts)", kind: "worked", ts: h.items[u].ts, took: ms), at: u + 1)
                h.lastUser = nil
            }
            return
        }
        guard let it = p["item"] as? [String: Any], let id = it["id"] as? String else { return }
        if it["type"] as? String == "UserMessage" {
            h.items.append(Item(id: id, kind: "user", text: texts(it["content"]), ts: ts))
            h.lastUser = h.items.count - 1
        } else if it["type"] as? String == "AgentMessage", it["phase"] as? String != "commentary" {
            let t = texts(it["content"]).split(separator: "\n").filter { !$0.hasPrefix("::") }.joined(separator: "\n")
            if !t.isEmpty { h.items.append(Item(id: id, kind: "assistant", text: t, ts: ts)) }
        }
    case .claude:
        guard o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
              let m = o["message"] as? [String: Any], let uuid = o["uuid"] as? String else { return }
        let ts = o["timestamp"] as? String ?? ""
        let role = o["type"] as? String
        if let str = m["content"] as? String {
            if role == "user", !isNoise(str) { h.items.append(Item(id: uuid, kind: "user", text: str, ts: ts)) }
            return
        }
        for (i, c) in ((m["content"] as? [[String: Any]]) ?? []).enumerated() where c["type"] as? String == "text" {
            let t = c["text"] as? String ?? ""
            if role == "user", isNoise(t) { continue }
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                h.items.append(Item(id: "\(uuid)#\(i)", kind: role == "user" ? "user" : "assistant", text: t, ts: ts))
            }
        }
    case .antigravity:
        let step = "\(o["step_index"] ?? "")"
        let ts = o["created_at"] as? String ?? ""
        let content = o["content"] as? String ?? ""
        if o["type"] as? String == "USER_INPUT" {
            var t = content
            if let r = content.range(of: "<USER_REQUEST>"), let e = content.range(of: "</USER_REQUEST>") { t = String(content[r.upperBound..<e.lowerBound]) }
            h.items.append(Item(id: step, kind: "user", text: t, ts: ts))
        } else if o["type"] as? String == "SYSTEM_MESSAGE" {
            for (i, t) in agyPushedMessages(content).enumerated() { h.items.append(Item(id: "\(step)#msg\(i)", kind: "user", text: t, ts: ts)) }
        } else if o["type"] as? String == "PLANNER_RESPONSE", !content.isEmpty {
            h.items.append(Item(id: step, kind: "assistant", text: content, ts: ts))
        }
    }
}

/// 给正文搜索用：整份记录里的提问和回复
func historyItems(_ kind: Kind, _ f: URL) -> [Item] { history(kind, f) }

private func claudeBgLine(_ line: UnsafeRawBufferPointer, _ h: inout Hist) {
    guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
    // 只认对话行和排队行；api-request-blob 这类行会原样带着旧的工具结果、却没有时间戳，会把启动时间覆盖掉
    guard ["user", "assistant", "queue-operation"].contains(o["type"] as? String ?? "") else { return }
    func notify(_ t: String) {
        guard t.contains("<task-notification>"), let a = t.range(of: "<task-id>"), let e = t.range(of: "</task-id>") else { return }
        let id = String(t[a.upperBound..<e.lowerBound])
        h.bgRunning[id] = nil
        h.jobs[id] = nil
    }
    let ts = o["timestamp"] as? String ?? ""
    if let c = o["content"] as? String { notify(c) }   // queue-operation
    guard let m = o["message"] as? [String: Any] else { return }
    if let c = m["content"] as? String { notify(c); return }
    for c in (m["content"] as? [[String: Any]]) ?? [] {
        switch c["type"] as? String {
        case "tool_use":
            let inp = c["input"] as? [String: Any] ?? [:]
            let id = c["id"] as? String ?? ""
            if inp["run_in_background"] as? Bool == true { h.bgTools.insert(id) }
            switch c["name"] as? String {
            case "CronCreate":
                let p = (inp["prompt"] as? String ?? "").split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""
                h.jobTools[id] = tr("定时 \(inp["cron"] as? String ?? "")：\(p)", "Scheduled \(inp["cron"] as? String ?? ""): \(p)")
            case "Monitor":
                let d = (inp["description"] as? String) ?? String((inp["command"] as? String ?? "").prefix(60))
                h.jobTools[id] = tr("监听：\(d)", "Monitor: \(d)")
            case "CronDelete":
                for case let v as String in inp.values { h.jobs[v] = nil }
            case "TaskStop":
                for case let v as String in inp.values { h.jobs[v] = nil; h.bgRunning[v] = nil }
            default: break
            }
        case "tool_result":
            guard let tid = c["tool_use_id"] as? String else { break }
            let out = (c["content"] as? String) ?? ((c["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            if h.bgTools.contains(tid), let r = out.firstMatch(of: #/running in background with ID: ([A-Za-z0-9_-]+)/#), h.bgRunning[String(r.1)] == nil {
                h.bgRunning[String(r.1)] = ts
            }
            guard let desc = h.jobTools[tid], let start = isoDate(ts) else { break }
            // “Scheduled recurring job 2c8ef1b9 (…). … Auto-expires after 7 days.”（一次性的不算，到点跑一次就没了）
            if let r = out.firstMatch(of: #/Scheduled recurring job ([A-Za-z0-9_-]+)/#) {
                let days = out.firstMatch(of: #/expires after (\d+) day/#).flatMap { Double($0.1) } ?? 7
                h.jobs[String(r.1)] = BgJob(ts: ts, until: start.addingTimeInterval(days * 86400), desc: desc)
            }
            // “Monitor started (task bmhlyto42, expires in 30m …”
            if let r = out.firstMatch(of: #/Monitor started \(task ([A-Za-z0-9_-]+)/#) {
                var until: Date?
                if let e = out.firstMatch(of: #/expires in (\d+)([smhd])/#), let n = Double(e.1) {
                    until = start.addingTimeInterval(n * ["s": 1, "m": 60, "h": 3600, "d": 86400][String(e.2)]!)
                }
                h.jobs[String(r.1)] = BgJob(ts: ts, until: until, desc: desc)
            }
        case "text":
            notify(c["text"] as? String ?? "")
        default: break
        }
    }
}

/// Claude 会话里还在跑的后台任务数（增量读取，和历史骨架共用缓存）。
/// 进程重启后旧任务就没了、也不会有完成通知，所以只算当前进程启动之后开的
func claudeBgRunning(_ f: URL, since: Date) -> Int {
    _ = history(.claude, f)
    histLock.lock(); defer { histLock.unlock() }
    guard let h = hists[f.path] else { return 0 }
    let now = Date()
    let tasks = h.bgRunning.values.filter { (isoDate($0) ?? .distantPast) >= since }.count
    // 定时任务和监听只活在当前进程里，到期自动结束
    let jobs = h.jobs.values.filter { (isoDate($0.ts) ?? .distantPast) >= since && ($0.until ?? .distantFuture) > now }.count
    return tasks + jobs
}

/// 任务面板用：定时任务和监听，新的在前；到期的标成“已到期”
func claudeJobs(_ f: URL) -> [BgTask] {
    _ = history(.claude, f)
    histLock.lock(); defer { histLock.unlock() }
    let now = Date()
    return (hists[f.path]?.jobs ?? [:]).sorted { $0.value.ts > $1.value.ts }.prefix(5).map { id, j in
        BgTask(id: id, started: j.ts, desc: j.desc, status: (j.until ?? .distantFuture) > now ? "running" : "expired", outputFile: "")
    }
}

/// 从上次读到的位置接着读到文件末尾，只解析新加的行
private func history(_ kind: Kind, _ f: URL) -> [Item] {
    histLock.lock(); defer { histLock.unlock() }
    var h = hists[f.path] ?? Hist()
    guard let fh = try? FileHandle(forReadingFrom: f) else { return h.items }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return h.items }
    if size < h.offset { h = Hist() }   // 文件被重写过，从头来
    guard (try? fh.seek(toOffset: h.offset)) != nil else { return h.items }
    while true {
        let chunk = fh.readData(ofLength: 8 << 20)
        if chunk.isEmpty { break }
        h.offset += UInt64(chunk.count)
        var data = h.carry
        data.append(chunk)
        var consumed = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var start = 0
            while start < buf.count, let nl = memchr(buf.baseAddress! + start, 10, buf.count - start) {
                let end = buf.baseAddress!.distance(to: nl)
                histLine(kind, UnsafeRawBufferPointer(rebasing: buf[start..<end]), &h)
                start = end + 1
            }
            consumed = start
        }
        h.carry = data.subdata(in: consumed..<data.count)
    }
    hists[f.path] = h
    return h.items
}

func readDetail(_ s: Session) -> Detail {
    if demoMode { return demoDetail(s) }
    var d = readDetailRaw(s)
    if let since = s.procStart {
        for i in d.tasks.indices where d.tasks[i].status == "running" && (isoDate(d.tasks[i].started) ?? .distantPast) < since {
            d.tasks[i].status = "killed"
        }
    } else if s.kind == .claude {
        // 进程已经不在了：在跑的任务都算中断，没回答的问题也作废
        for i in d.tasks.indices where d.tasks[i].status == "running" { d.tasks[i].status = "killed" }
        d.ask = nil
    }
    return d
}

private func readDetailRaw(_ s: Session) -> Detail {
    guard let f = s.transcript else { return Detail(items: [], tasks: [], suggestion: nil, plan: []) }
    let lines = tailLines(f, tailBytes)
    var b = Builder()
    switch s.kind {
    case .codex: if !parseCodexItems(lines, &b) { parseCodex(lines, &b) }
    case .claude: parseClaude(lines, &b)
    case .antigravity: parseAntigravity(lines, &b)
    }
    // 后台任务：最近 10 个，在跑的读一下输出文件末尾
    var tasks = b.taskOrder.suffix(10).compactMap { b.tasks[$0] }
    for i in tasks.indices {
        let lines = tailLines(URL(fileURLWithPath: tasks[i].outputFile), 3000)
        tasks[i].output = lines.suffix(12).joined(separator: "\n")
    }
    var items = b.result
    let size = ((try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    if size > tailBytes, let earliest = items.first(where: { !$0.ts.isEmpty })?.ts {
        let ids = Set(items.map(\.id))
        var seen = Set<String>()
        let older = history(s.kind, f).reversed().filter { !$0.ts.isEmpty && $0.ts < earliest && !ids.contains($0.id) && seen.insert($0.id).inserted }
        items = older.reversed() + items
    }
    var all = Array(tasks.reversed())
    if s.kind == .claude {
        let jobs = claudeJobs(f).filter { j in !all.contains { $0.id == j.id } }
        all = jobs.filter { $0.status == "running" } + all + jobs.filter { $0.status != "running" }
    }
    var d = Detail(items: items, tasks: all, suggestion: b.suggestion, plan: b.plan, model: b.model)
    d.steps = b.steps
    d.ask = b.ask
    return d
}

/// 界面专用的工具：用卡片显示，不当普通步骤
private let uiTools: Set<String> = ["mcp__ccd_turn__update_plan", "mcp__ccd_turn__wrap_up", "TodoWrite"]

private func applyPlan(_ name: String, _ args: [String: Any], _ b: inout Builder) {
    if name == "TodoWrite" {
        b.plan = ((args["todos"] as? [[String: Any]]) ?? []).map { PlanItem(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending") }
        return
    }
    if let items = args["items"] as? [[String: Any]] {
        b.plan = items.map { PlanItem(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending") }
    }
    // advance：当前这步完成，下一个待办开始
    if args["advance"] as? Bool == true, let i = b.plan.firstIndex(where: { $0.status == "in_progress" }) {
        b.plan[i].status = "completed"
        if let j = b.plan[(i + 1)...].firstIndex(where: { $0.status == "pending" }) { b.plan[j].status = "in_progress" }
    }
    for n in (args["done"] as? [Int]) ?? [] where n >= 1 && n <= b.plan.count { b.plan[n - 1].status = "completed" }
    if let n = args["start"] as? Int, n >= 1, n <= b.plan.count {
        for i in b.plan.indices where b.plan[i].status == "in_progress" { b.plan[i].status = "pending" }
        b.plan[n - 1].status = "in_progress"
    }
}

private func tag(_ s: String, _ name: String) -> String {
    guard let a = s.range(of: "<\(name)>"), let e = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.upperBound..<e.lowerBound])
}

private func noteTaskNotification(_ text: String, _ b: inout Builder) {
    guard text.contains("<task-notification>") else { return }
    let id = tag(text, "task-id")
    guard !id.isEmpty else { return }
    if b.tasks[id] == nil {
        b.tasks[id] = BgTask(id: id, desc: tag(text, "summary"), status: "", outputFile: tag(text, "output-file"))
        b.taskOrder.append(id)
    }
    b.tasks[id]!.status = tag(text, "status")
    b.tasks[id]!.summary = tag(text, "summary")
}

// MARK: Codex

/// Codex 桌面端自己显示用的事件：event_msg/item_completed（用户消息、回复、思考、命令、改文件、MCP 调用）
/// 加 task_started / task_complete（这一轮用时）。还没完成的那一步只在 response_item 里，单独补上
private func parseCodexItems(_ lines: [Substring], _ b: inout Builder) -> Bool {
    var any = false
    var turnFiles: [String: FileStat] = [:]
    var fileOrder: [String] = []
    var pending: [String: Item] = [:]   // 已经发起、还没有结果的调用
    var pendingOrder: [String] = []
    var lastTs = ""
    func text(_ c: Any?) -> String {
        ((c as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }
    for l in lines {
        guard let o = json(l), let p = o["payload"] as? [String: Any] else { continue }
        let ts = o["timestamp"] as? String ?? ""
        let type = o["type"] as? String
        if type == "response_item" {
            switch p["type"] as? String {
            case "function_call", "custom_tool_call":
                guard let cid = p["call_id"] as? String else { break }
                let name = p["name"] as? String ?? "tool"
                let input = p["input"] as? String ?? p["arguments"] as? String ?? ""
                let args = (try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]) ?? [:]
                let (verb, target) = name == "exec" || name == "js" ? codexScriptLabel(name == "js" ? str(args, "code") : input) : label(name, args)
                var item = Item(id: cid, kind: "tool", name: name, verb: verb, summary: target, input: cut(input), done: false, ts: ts)
                item.cat = verb == V.wait || verb == V.waitBackground ? "wait" : verb == V.editFile ? "edit" : "cmd"
                pending[cid] = item
                pendingOrder.append(cid)
            case "function_call_output", "custom_tool_call_output":
                if let cid = p["call_id"] as? String { pending[cid] = nil }
            default: break
            }
            continue
        }
        guard type == "event_msg" else { continue }
        switch p["type"] as? String {
        case "task_started":
            turnFiles = [:]; fileOrder = []
        case "task_complete":
            any = true
            let ms = (p["duration_ms"] as? Int) ?? Int((p["duration_ms"] as? String) ?? "") ?? 0
            b.add(Item(id: "end-\(p["turn_id"] ?? ts)", kind: "turnend", text: "x", ts: ts, took: ms,
                       files: fileOrder.compactMap { turnFiles[$0] }))
            turnFiles = [:]; fileOrder = []
        case "item_completed":
            any = true
            lastTs = ts
            guard let it = p["item"] as? [String: Any] else { break }
            let id = it["id"] as? String ?? ts
            switch it["type"] as? String {
            case "UserMessage":
                b.add(Item(id: id, kind: "user", text: text(it["content"]), ts: ts))
            case "AgentMessage":
                // ::browser-complete{…} 这类是给 Codex 界面的指令，不显示
                let t = text(it["content"]).split(separator: "\n").filter { !$0.hasPrefix("::") }.joined(separator: "\n")
                b.add(Item(id: id, kind: it["phase"] as? String == "commentary" ? "note" : "assistant", text: t, ts: ts))
            case "Reasoning":
                b.add(Item(id: id, kind: "thinking", text: ((it["summary_text"] as? [String]) ?? []).joined(separator: "\n"), ts: ts))
            case "CommandExecution":
                let cmd = (it["command"] as? [String])?.last ?? ""
                let out = it["aggregated_output"] as? String ?? it["output"] as? String ?? ""
                // parsed_cmd 是 Codex 自己对命令的分类：read 读文件 / search 搜索 / list_files 列目录 / unknown 其他命令
                let acts = (it["parsed_cmd"] as? [[String: Any]]) ?? []
                let types = acts.compactMap { $0["type"] as? String }
                let cat = types.isEmpty || types.contains("unknown") ? "cmd"
                    : types.allSatisfy { $0 == "read" } ? "read" : types.contains("search") ? "search" : types.contains("list_files") ? "list" : "cmd"
                let verb = ["read": tr("读取", "Read"), "search": tr("搜索", "Search"), "list": tr("浏览文件", "Browse files"), "cmd": V.runCommand][cat]!
                let target = cat == "read" ? acts.compactMap { $0["name"] as? String }.joined(separator: tr("、", ", ")) : firstLine(cmd)
                var item = Item(id: id, kind: "tool", name: "exec_command", verb: verb, summary: target,
                                input: cut(cmd), output: cut(out), ts: ts)
                item.cat = cat
                b.add(item)
            case "FileChange":
                var diffs: [String] = []
                var names: [String] = []
                for (path, raw) in (it["changes"] as? [String: Any]) ?? [:] {
                    let ch = raw as? [String: Any] ?? [:]
                    let kind = ch["type"] as? String ?? "update"
                    var add = 0, del = 0
                    if kind == "add" {
                        add = (ch["content"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                    } else if let d = ch["unified_diff"] as? String {
                        for line in d.split(separator: "\n") {
                            if line.hasPrefix("+") && !line.hasPrefix("+++") { add += 1 }
                            if line.hasPrefix("-") && !line.hasPrefix("---") { del += 1 }
                        }
                        diffs.append("--- \(path)\n" + d)
                    }
                    if turnFiles[path] == nil { fileOrder.append(path); turnFiles[path] = FileStat(path: path, kind: kind, add: 0, del: 0) }
                    turnFiles[path]!.add += add
                    turnFiles[path]!.del += del
                    if kind == "delete" { turnFiles[path]!.kind = "delete" }
                    names.append(base(path))
                }
                var item = Item(id: id, kind: "tool", name: "apply_patch", verb: V.editFile,
                                summary: names.count > 1 ? tr("\(names[0]) 等 \(names.count) 个", "\(names[0]) and \(names.count - 1) more") : names.first ?? "",
                                input: cut(diffs.joined(separator: "\n\n")), ts: ts)
                item.cat = "edit"
                b.add(item)
            case "McpToolCall":
                let args = it["arguments"] as? [String: Any] ?? [:]
                let result = text((it["result"] as? [String: Any])?["content"])
                let tool = it["tool"] as? String ?? "mcp"
                let fallback = tool.contains("search") ? tr("搜索网页", "Search web") : tool.contains("image") ? tr("生成图片", "Generate image") : tool
                var item = Item(id: id, kind: "tool", name: tool,
                                verb: str(args, "title").isEmpty ? fallback : str(args, "title"),
                                // 集成的名字：电脑操作类插件写“电脑操作”，其他用 MCP 服务名
                                summary: (it["pluginId"] as? String ?? "").contains("computer-use") ? tr("电脑操作", "Computer use") : (it["server"] as? String ?? tr("集成", "Integration")),
                                input: cut(pretty(args)), output: cut(result), ts: ts)
                item.cat = "mcp"
                b.add(item)
            case "Extension":
                if it["kind"] as? String == "clock.sleep" {
                    let ms = (it["durationMs"] as? Int) ?? 0
                    var item = Item(id: id, kind: "tool", name: "sleep", verb: V.wait, summary: tr("\(ms / 1000) 秒", "\(ms / 1000)s"), ts: ts)
                    item.cat = "wait"
                    b.add(item)
                }
            case "ContextCompaction":
                b.add(Item(id: id, kind: "compact", text: tr("上下文已自动压缩", "Context auto-compacted"), ts: ts))
            default: break
            }
        default: break
        }
    }
    // 还在跑的那一步：已发起、没结果、比最后完成的一步新
    for cid in pendingOrder {
        if let it = pending[cid], it.ts >= lastTs { b.add(it) }
    }
    return any
}

private func parseCodex(_ lines: [Substring], _ b: inout Builder) {
    var seen: [String: Int] = [:] // 同一时间戳下的序号，用来造稳定 id
    for l in lines {
        guard let o = json(l), o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any] else { continue }
        let ts = o["timestamp"] as? String ?? ""
        let n = seen[ts, default: 0]
        seen[ts] = n + 1
        let id = "\(ts)#\(n)"
        switch p["type"] as? String {
        case "message":
            let text = ((p["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            switch p["role"] as? String {
            case "user": b.add(Item(id: id, kind: "user", text: text, ts: ts))
            // 过程说明（commentary）和工具调用一起收进步骤组，只把最终回复露在外面，跟 Codex 原生界面一致
            case "assistant": b.add(Item(id: id, kind: p["phase"] as? String == "commentary" ? "note" : "assistant", text: text, ts: ts))
            default: break
            }
        case "reasoning":
            let text = ((p["summary"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            b.add(Item(id: id, kind: "thinking", text: text, ts: ts))
        case "function_call":
            let raw = p["arguments"] as? String ?? ""
            let args = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
            let name = p["name"] as? String ?? "tool"
            let (verb, target) = name == "js" ? codexScriptLabel(str(args, "code", "source", "input")) : label(name, args)
            b.add(Item(id: p["call_id"] as? String ?? id, kind: "tool", name: name, verb: verb,
                       summary: target, input: cut(pretty(args)), done: false, ts: ts))
        case "custom_tool_call":
            let input = p["input"] as? String ?? ""
            let name = p["name"] as? String ?? "tool"
            let (verb, target) = name == "exec" ? codexScriptLabel(input) : label(name, [:])
            b.add(Item(id: p["call_id"] as? String ?? id, kind: "tool", name: name, verb: verb,
                       summary: target, input: cut(input), done: false, ts: ts))
        case "function_call_output", "custom_tool_call_output":
            if let cid = p["call_id"] as? String { b.output(cid, pretty(p["output"] ?? "")) }
        default: break
        }
    }
}

// MARK: Claude Code

private func toolResultText(_ c: [String: Any]) -> String {
    if let s = c["content"] as? String { return s }
    return ((c["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
}

private func parseClaude(_ lines: [Substring], _ b: inout Builder) {
    var toolDesc: [String: String] = [:]
    var bgTools = Set<String>() // run_in_background 的工具调用，只有它们的结果里才会登记后台任务
    for l in lines {
        // 后台任务完成通知可能只出现在排队记录里
        if let o = json(l), o["type"] as? String == "queue-operation", let c = o["content"] as? String {
            noteTaskNotification(c, &b)
        }
        guard let o = json(l), o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
              let m = o["message"] as? [String: Any], let uuid = o["uuid"] as? String else { continue }
        let ts = o["timestamp"] as? String ?? ""
        switch o["type"] as? String {
        case "user":
            if let s = m["content"] as? String {
                noteTaskNotification(s, &b)
                // 用户真的说了话，上一轮的建议就作废
                if !s.hasPrefix("<") { b.suggestion = nil; b.plan = [] }
                b.add(Item(id: uuid, kind: "user", text: s, ts: ts))
                continue
            }
            for (i, c) in ((m["content"] as? [[String: Any]]) ?? []).enumerated() {
                switch c["type"] as? String {
                case "text":
                    let t = c["text"] as? String ?? ""
                    noteTaskNotification(t, &b)
                    if !isNoise(t) { b.suggestion = nil; b.plan = [] }
                    b.add(Item(id: "\(uuid)#\(i)", kind: "user", text: t, ts: ts))
                case "tool_result":
                    guard let tid = c["tool_use_id"] as? String else { break }
                    let out = toolResultText(c)
                    b.output(tid, out)
                    if b.ask?.id == tid { b.ask = nil }
                    // “Command running in background with ID: xxx. Output is being written to: yyy”
                    if bgTools.contains(tid), let m = out.firstMatch(of: #/running in background with ID: ([A-Za-z0-9_-]+)/#) {
                        let id = String(m.1)
                        let file = out.firstMatch(of: #/written to: (\S+?\.output)/#).map { String($0.1) } ?? ""
                        if b.tasks[id] == nil {
                            b.tasks[id] = BgTask(id: id, started: ts, desc: toolDesc[tid] ?? tr("后台任务", "Background task"), status: "running", outputFile: file)
                            b.taskOrder.append(id)
                        }
                    }
                default: break
                }
            }
        case "assistant":
            for (i, c) in ((m["content"] as? [[String: Any]]) ?? []).enumerated() {
                switch c["type"] as? String {
                case "text": b.add(Item(id: "\(uuid)#\(i)", kind: "assistant", text: c["text"] as? String ?? "", ts: ts))
                case "thinking": b.add(Item(id: "\(uuid)#\(i)", kind: "thinking", text: c["thinking"] as? String ?? "", ts: ts))
                case "tool_use":
                    let args = c["input"] as? [String: Any] ?? [:]
                    let name = c["name"] as? String ?? "tool"
                    let (verb, target) = label(name, args)
                    if let tid = c["id"] as? String {
                        toolDesc[tid] = target.isEmpty ? verb : target
                        if args["run_in_background"] as? Bool == true { bgTools.insert(tid) }
                    }
                    if name == "mcp__ccd_turn__update_plan" || name == "TodoWrite" { applyPlan(name, args, &b) }
                    if name == "AskUserQuestion", let tid = c["id"] as? String {
                        b.ask = PendingAsk(id: tid, questions: ((args["questions"] as? [[String: Any]]) ?? []).map { q in
                            AskQ(question: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                                 multiSelect: q["multiSelect"] as? Bool ?? false,
                                 options: ((q["options"] as? [[String: Any]]) ?? []).map {
                                     AskOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                                 })
                        })
                    }
                    // wrap_up 收尾：清单全部算完成
                    if name == "mcp__ccd_turn__wrap_up" { for i in b.plan.indices { b.plan[i].status = "completed" } }
                    if name == "mcp__ccd_turn__wrap_up", args["ask"] != nil || args["actions"] != nil {
                        b.suggestion = Suggestion(recap: args["recap"] as? String ?? "", ask: args["ask"] as? String ?? "",
                                                  actions: ((args["actions"] as? [[String: Any]]) ?? []).compactMap { a in
                                                      a["action"] == nil ? a["label"] as? String : nil
                                                  })
                    }
                    b.add(Item(id: c["id"] as? String ?? "\(uuid)#\(i)", kind: "tool", name: name, verb: verb,
                               summary: target, input: cut(pretty(args)), done: false, ts: ts))
                default: break
                }
            }
        default: break
        }
    }
}

/// 通过本地接口（agentapi send-message）发给 Antigravity 的消息，在它记录里是系统消息：
/// “The following is a <SYSTEM_MESSAGE> … [Message] timestamp=… sender=… content=正文 </SYSTEM_MESSAGE>”。取出正文
func agyPushedMessages(_ content: String) -> [String] {
    guard content.contains("[Message]") else { return [] }
    var body = content
    if let a = content.range(of: "<SYSTEM_MESSAGE>"), let e = content.range(of: "</SYSTEM_MESSAGE>", options: .backwards), a.upperBound <= e.lowerBound {
        body = String(content[a.upperBound..<e.lowerBound])
    }
    return body.components(separatedBy: "[Message]").dropFirst().compactMap { part in
        guard let r = part.range(of: "content=") else { return nil }
        let t = part[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: Antigravity：每一步一行；模型那步带 tool_calls，后面的 GENERIC 步骤依次是这些调用的结果

private func parseAntigravity(_ lines: [Substring], _ b: inout Builder) {
    var pending: [String] = []
    for l in lines {
        guard let o = json(l) else { continue }
        let step = "\(o["step_index"] ?? "")"
        if let n = Int(step) { b.steps = max(b.steps, n + 1) }
        let ts = o["created_at"] as? String ?? ""
        let content = o["content"] as? String ?? ""
        switch o["type"] as? String {
        case "USER_INPUT":
            // 正文包在 <USER_REQUEST> 里，后面跟着系统附加的元数据
            var text = content
            if let r = content.range(of: "<USER_REQUEST>"), let e = content.range(of: "</USER_REQUEST>") {
                text = String(content[r.upperBound..<e.lowerBound])
            }
            b.add(Item(id: step, kind: "user", text: text, ts: ts))
        case "PLANNER_RESPONSE":
            // gemini-4-neon-high → Gemini 4 Neon High
            if let m = o["model"] as? String {
                b.model = m.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
            if let t = o["thinking"] as? String { b.add(Item(id: step + "#think", kind: "thinking", text: t, ts: ts)) }
            b.add(Item(id: step, kind: "assistant", text: content, ts: ts))
            for (i, t) in ((o["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                let args = t["args"] as? [String: Any] ?? [:]
                let id = "\(step)#tool\(i)"
                let name = t["name"] as? String ?? "tool"
                let (verb, target) = label(name, args)
                b.add(Item(id: id, kind: "tool", name: name, verb: verb,
                           summary: target, input: cut(pretty(args)), done: false, ts: ts))
                pending.append(id)
            }
        case "GENERIC":
            guard !pending.isEmpty, o["status"] as? String != "RUNNING" else { continue }
            b.output(pending.removeFirst(), content)
        case "SYSTEM_MESSAGE":
            // 别的会话或 Convoy 通过接口发来的消息：当提问显示
            for (i, t) in agyPushedMessages(content).enumerated() {
                b.add(Item(id: "\(step)#msg\(i)", kind: "user", text: t, ts: ts))
            }
        default: break
        }
    }
}
