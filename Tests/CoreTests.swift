import Foundation

func testModelName() {
    expectEq(modelName("claude-opus-5-5"), "Opus 5.5", "Claude 模型名")
    expectEq(modelName("claude-haiku-4-5-20251001"), "Haiku 4.5", "日期后缀不算版本号")
    expectEq(modelName("gpt-6.2-sol"), "GPT-6.2 Sol", "Codex 模型名")
    expectEq(modelName("gemini-4-neon-high"), "gemini-4-neon-high", "别的模型原样显示")
    expectEq(modelName("claude-"), "claude-", "只有前缀")
}

func testSafeFileName() {
    expectEq(safeFileName("a/b\\c:d*e?f\"g<h>i|j"), "a-b-c-d-e-f-g-h-i-j", "非法字符换成连字符")
    expectEq(safeFileName("a\nb\tc"), "a-b-c", "换行和制表符")
    expectEq(safeFileName("  "), "未命名", "空名字")
    expectEq(safeFileName(String(repeating: "x", count: 80)).count, 60, "最多 60 个字符")
}

func testLabelMatching() {
    expect(L.item("Pin ⌥⌘P", ["Pin"]), "菜单项可以带快捷键")
    expect(!L.item("Pinned", ["Pin"]), "前缀相同但不是同一个词")
    expect(L.anyPrefix("模型：Opus", L.modelPrefix), "下拉框标题带前缀")
    expectEq(L.stripPrefix("Model: Opus", L.modelPrefix), "Opus", "去掉前缀")
    // 每种应用的每个会话操作都要有菜单路径，点菜单时是直接取的
    for k in [Kind.claude, .codex, .antigravity] {
        for a in [SessionAction.rename, .fork, .pin, .archive, .delete] {
            expect(L.menuPath[k]?[a]?.isEmpty == false, "\(k) 的 \(a) 缺菜单路径")
        }
    }
}

func testJSONHelpers() {
    expectEq(json("{\"a\":1}" as Substring)?["a"] as? Int, 1, "一行 JSON")
    expect(json("not json" as Substring) == nil, "不是 JSON")
    expect(isoDate("2026-01-02T03:04:05.123Z") != nil, "带毫秒的时间")
    expect(isoDate("2026-01-02T03:04:05Z") != nil, "不带毫秒的时间")
    expect(isoDate("yesterday") == nil, "不是时间")
}

func testTailLines() {
    let d = tempDir(), f = d.appendingPathComponent("a.log")
    expectEq(tailLines(f, 100), [], "文件不存在")
    try! Data().write(to: f)
    expectEq(tailLines(f, 100), [], "空文件")
    try! Data("l1\nl2\nl3\n".utf8).write(to: f)
    expectEq(tailLines(f, 100), ["l1", "l2", "l3"], "整个文件都读得到")
    expectEq(tailLines(f, 5), ["l3"], "只读末尾时丢掉被截断的第一行")
}

func testNormalized() {
    expectEq(normalized(" a\tb\nc "), "abc", "去掉所有空白")
}

func testAgyPushedMessages() {
    let content = "The following is a <SYSTEM_MESSAGE>\n[Message] timestamp=1 sender=convoy content=hello there\n[Message] timestamp=2 sender=convoy content=second one </SYSTEM_MESSAGE>"
    expectEq(agyPushedMessages(content), ["hello there", "second one"], "取出每条消息的正文")
    expectEq(agyPushedMessages("[Message] timestamp=1 content=abc"), ["abc"], "没有外层标签")
    expectEq(agyPushedMessages("plain text"), [], "不是系统消息")
}

/// 一份两轮的 Claude 记录：提问、回复、一条不该显示的工具结果
private func claudeFixture() -> (session: Session, file: URL) {
    let f = tempDir().appendingPathComponent("abc.jsonl")
    let lines = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"please fix the Login bug"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T00:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Fixed the login bug."}]}}"#,
        #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"tool output"}]}}"#,
    ]
    try! lines.joined(separator: "\n").write(to: f, atomically: false, encoding: .utf8)
    let s = Session(id: "claude-abc", kind: .claude, rawId: "abc", transcript: f, app: "Claude", title: "Fixture",
                    project: "p", running: false, updated: Date(), link: nil, appPath: "/Applications/Claude.app")
    return (s, f)
}

func testSearchSessions() {
    let (s, _) = claudeFixture()
    let hits = searchSessions([s], "login")
    expectEq(hits.map(\.itemId), ["a1#0", "u1"], "新的在前，工具结果不算")
    expectEq(hits.first?.match, "login", "命中的是原文里那一段")
    expect(hits.first?.before.hasSuffix("Fixed the ") == true, "命中词前面的一小段")
    expectEq(searchSessions([s], "nothing-here"), [], "没命中")
}

func testSessionDelta() {
    let (s, _) = claudeFixture()
    let first = sessionDelta(s, after: nil)
    expect(first.text.contains("please fix the Login bug"), "第一次汇总带上开头的提问")
    expect(first.text.contains("Fixed the login bug."), "带上有内容的回复")
    expect(!first.text.contains("tool output"), "工具结果不进汇总")
    expectEq(first.last?.itemId, "a1#0", "记下读到了哪一条")
    let next = sessionDelta(s, after: first.last)
    expectEq(next.text, "", "没有新内容")
    expectEq(next.last?.itemId, "a1#0", "位置不变")
}

func testProjectApply() {
    var p = Project(name: "Demo")
    let auth: [String: Any] = ["id": "t1", "title": "Auth", "goal": "login works", "state": "进行中", "now": "n1",
                               "learned": [["text": "finding A", "verdict": "有效"]]]
    p.apply(["goal": "Ship it", "tracks": [auth]])
    expectEq(p.goal, "Ship it", "新项目采用模型起草的目标")
    expectEq(p.tracks.map(\.title), ["Auth"], "新项目采用模型起草的大类")
    expectEq(p.tracks[0].learned.map(\.text), ["finding A"], "结论")

    // 你加的条目保留，你删掉的不再加回来；已有项目里新出现的大类只做建议
    p.tracks[0].learned.append(BoardEntry(text: "my note", by: "user"))
    p.ignore("finding A")
    let billing: [String: Any] = ["title": "Billing", "goal": "checkout works", "state": "进行中"]
    p.apply(["goal": "Something else", "tracks": [auth, billing]])
    expectEq(p.goal, "Ship it", "已有目标不被模型改写")
    expectEq(p.tracks.map(\.title), ["Auth"], "大类不自动增加")
    let learned = p.tracks[0].learned
    expect(learned.contains { $0.text == "my note" && $0.by == "user" }, "你写的条目原样保留")
    expect(!learned.contains { $0.text == "finding A" }, "你删掉的条目不加回来")
    expectEq(p.suggestions.map(\.title), ["Billing"], "新方向变成建议")
}

func testBoardSettingsModel() {
    var s = BoardSettings()
    s.agent = "codex"; s.codexEffort = "high"
    expectEq(s.model, "high", "Codex 的当前选项是强度")
    expectEq(s.label, "codex high", "日志里的名字")
    s.agent = "gemini"; s.geminiModel = "gemini-3.8-flash-medium"
    expectEq(s.model, "gemini-3.8-flash-medium", "Gemini 的当前选项是模型")
}
