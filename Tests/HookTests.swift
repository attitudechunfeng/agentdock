import Foundation

private let hookCommand = "'/Applications/Convoy.app/Contents/MacOS/Convoy' --board-hook"

/// 一份 Claude Code 风格的 settings.json：两格缩进，数字、中文、空数组都有
private let sampleSettings = """
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(npm run lint)"
    ],
    "deny": []
  },
  "env": {
    "ANTHROPIC_API_KEY": "sk-ant-"
  },
  "num": 1.0,
  "中文键": "值"
}
"""

private func hookFile(_ name: String, _ body: String) -> String {
    let f = tempDir().appendingPathComponent(name).path
    try! Data(body.utf8).write(to: URL(fileURLWithPath: f))
    return f
}

private func read(_ f: String) -> String { try! String(contentsOfFile: f, encoding: .utf8) }
private func parse(_ f: String) -> JSONValue { try! JSONValue.parse(read(f)) }
private func failed(_ r: HookFileOutcome) -> Bool { if case .failed = r { return true }; return false }
/// 某个事件下各组里的命令
private func commands(_ v: JSONValue, _ ev: String) -> [String] {
    (v["hooks"]?[ev]?.items ?? []).flatMap { $0["hooks"]?.items.compactMap { $0["command"]?.string } ?? [] }
}
/// 某个文件的全部备份文件名（第一次的那份和带时间的）
private func backups(of f: String) -> [String] {
    let dir = (f as NSString).deletingLastPathComponent, prefix = (f as NSString).lastPathComponent + ".agentdock-backup"
    return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) }
}

func testJSONValueRoundTrip() {
    let v = try! JSONValue.parse(sampleSettings)
    expectEq(v.text, sampleSettings, "按原来的样子写回来")
    expectEq(v["num"]?.text, "1.0", "数字按原文")
    expectEq(v["permissions"]?["allow"]?.items.map { $0.string ?? "" }, ["Bash(npm run lint)"], "数组")
    expectEq(v["permissions"]?["deny"]?.text, "[]", "空数组")
    expectEq(v.objectPairs?.map { $0.0 }, ["model", "permissions", "env", "num", "中文键"], "键的顺序不变")
}

func testJSONValueEscapes() {
    let v = try! JSONValue.parse(#""a\"b \\ \/ \t \n \u4e2d\u6587 \ud83d\ude00 end""#)
    expectEq(v.string, "a\"b \\ / \t \n 中文 😀 end", "转义都解开")
    expectEq(JSONValue.string("a\"b \\ / \t \n 中文 😀 \u{1}").text, #""a\"b \\ / \t \n 中文 😀 \u0001""#, "写出去的转义")
}

func testJSONValueRejectsInvalid() {
    for bad in ["", "{", "{\"a\":}", "{\"a\":1} x", "[1,]", "'a'", "nul", "{\"a\":\\ud800}", "{\"a\" 1}", "[\"\\u12",
                "{\"n\":1e+}", "{\"n\":01}", "{\"n\":-01}", "{\"n\":-}", "{\"n\":.5}", "{\"n\":+1}", "{\"n\":1.}", "{\"n\":1e}", "{\"n\":1.5.3}",
                "{\"a\":\"\t\"}", "{\"a\":\"\n\"}", "{\"a\":\"\u{0}\"}"] {
        expect(!((try? JSONValue.parse(bad)) != nil), "不该当成合法 JSON：\(bad)")
    }
}

func testJSONValueNumbers() {
    let v = try! JSONValue.parse(#"{"a": 1e+5, "b": -0, "c": 0.5, "d": 1E-9, "e": 123456789012345678901234567890}"#)
    expectEq(v.objectPairs?.map { $0.1.text }, ["1e+5", "-0", "0.5", "1E-9", "123456789012345678901234567890"], "合法的数字按原文保留")
}

func testJSONValueDuplicateKeys() {
    // 重复的键以最后一个为准，位置留在第一次出现的地方，和 JSONSerialization、Claude Code 的读法一致
    let v = try! JSONValue.parse(#"{"a": 1, "b": 2, "a": 3}"#)
    expectEq(v["a"]?.text, "3", "取最后一个")
    expectEq(v.objectPairs?.map { $0.0 }, ["a", "b"], "位置不变")
    expectEq(v.text, "{\n  \"a\": 3,\n  \"b\": 2\n}", "写回去只剩一个")
}

func testJSONValueSet() {
    var v = try! JSONValue.parse(#"{"a": 1, "b": 2}"#)
    v.set("b", .number("3"))
    v.set("c", .bool(true))
    v.set("a", nil)
    expectEq(v.text, "{\n  \"b\": 3,\n  \"c\": true\n}", "原位改、加在最后、删掉")
    var notObject = JSONValue.number("1")
    notObject.set("a", nil)
    expectEq(notObject, .number("1"), "不是对象就不动")
}

func testBoardHooksInstallKeepsRest() {
    let f = hookFile("settings.json", sampleSettings + "\n")
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f)
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "装上了")
    let group = """
      {
        "hooks": [
          {
            "type": "command",
            "command": "\(hookCommand)",
            "timeout": 5
          }
        ]
      }
"""
    let want = sampleSettings.dropLast(2) + ",\n  \"hooks\": {\n    \"UserPromptSubmit\": [\n" + group
        + "\n    ],\n    \"SessionStart\": [\n" + group + "\n    ]\n  }\n}\n"
    expectEq(read(f), want, "原有的内容一字不改，hooks 加在最后，末尾的换行也留着")
    expectEq(try! FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int, 0o600, "文件权限保留")
    expect(FileManager.default.fileExists(atPath: f + ".agentdock-backup"), "第一次的备份")
    expectEq(backups(of: f).count, 2, "第一次的备份，加一份带时间的")
}

func testBoardHooksInstallIsIdempotent() {
    let f = hookFile("settings.json", "{}")
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "第一次装")
    let after = read(f)
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .unchanged, "已经装着就不再动文件")
    expectEq(read(f), after, "内容没变")
    expectEq(backups(of: f).count, 2, "没改动就不多留备份")
}

func testBoardHooksRemoveKeepsOtherHooks() {
    let f = hookFile("hooks.json", """
    {
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "echo hi"
              }
            ]
          }
        ],
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "\(hookCommand)"
              }
            ]
          }
        ]
      },
      "other": true
    }
    """)
    expectEq(updateBoardHooks(file: f, on: false, command: hookCommand, createIfMissing: false), .changed, "摘掉了")
    let v = parse(f)
    expectEq(commands(v, "SessionStart"), ["echo hi"], "别的钩子原样保留")
    expect(v["hooks"]?["UserPromptSubmit"] == nil, "只剩看板钩子的事件整个去掉")
    expectEq(v["other"]?.text, "true", "其余的键不动")
    expectEq(updateBoardHooks(file: f, on: false, command: hookCommand, createIfMissing: false), .unchanged, "已经摘掉了就不再动")
}

func testBoardHooksRemoveDropsEmptyHooks() {
    let f = hookFile("hooks.json", "{\"hooks\": {\"UserPromptSubmit\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"\(hookCommand)\"}]}]}}")
    expectEq(updateBoardHooks(file: f, on: false, command: hookCommand, createIfMissing: false), .changed, "摘掉")
    expectEq(parse(f).text, "{}", "没有别的钩子时 hooks 这个键也去掉")
}

func testBoardHooksMigratesOldCommand() {
    let old = "'/Applications/AgentDock.app/Contents/MacOS/AgentDock' --board-hook"
    let f = hookFile("settings.json", "{\"hooks\": {\"UserPromptSubmit\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"\(old)\"}]}]}}")
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "换成现在的命令")
    let v = parse(f)
    expectEq(commands(v, "UserPromptSubmit"), [hookCommand], "旧路径的钩子被换掉")
    expectEq(commands(v, "SessionStart"), [hookCommand], "补上另一个事件")
}

func testBoardHooksSkipsUnreadableFile() {
    for bad in ["{ not json", "[]", "\"text\""] {
        let f = hookFile("settings.json", bad)
        expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .skipped, "读不懂就不动：\(bad)")
        expectEq(read(f), bad, "原样")
        expect(!FileManager.default.fileExists(atPath: f + ".agentdock-backup"), "没动文件就不留备份")
    }
}

func testBoardHooksEmptyFile() {
    let f = hookFile("hooks.json", "")
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "空文件当成还没有设置")
    expectEq(commands(parse(f), "SessionStart"), [hookCommand], "装上了")
}

func testBoardHooksMissingFile() {
    let f = tempDir().appendingPathComponent("settings.json").path
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .unchanged, "不让新建就什么都不做")
    expect(!FileManager.default.fileExists(atPath: f), "文件没建出来")
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: true), .changed, "新建")
    expectEq(commands(parse(f), "UserPromptSubmit"), [hookCommand], "装上了")
    expect(!FileManager.default.fileExists(atPath: f + ".agentdock-backup"), "原来没有文件就没有备份")
    expectEq(updateBoardHooks(file: f, on: false, command: hookCommand, createIfMissing: true), .changed, "摘掉")
    expectEq(parse(f).text, "{}", "只剩空对象")
}

func testBoardHooksRestoresOnWriteFailure() {
    let dir = tempDir()
    let f = dir.appendingPathComponent("settings.json").path
    try! Data("{\"a\": 1}".utf8).write(to: URL(fileURLWithPath: f))
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    expect(failed(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false)), "写不进去要报失败")
    expectEq(read(f), "{\"a\": 1}", "原样")
}

func testBoardHooksPrunesBackups() {
    let f = hookFile("settings.json", "{}")
    for d in 1...12 {
        try! Data("x".utf8).write(to: URL(fileURLWithPath: f + ".agentdock-backup-202001" + String(format: "%02d", d) + "-000000"))
    }
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "装上")
    let names = backups(of: f).sorted()
    expectEq(names.count, 11, "带时间的留 10 份，加上第一次的那份")
    expect(!names.contains("settings.json.agentdock-backup-20200101-000000"), "最旧的删掉")
}

func testBoardHooksBackupsUniqueWithinASecond() {
    let f = hookFile("settings.json", "{}")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for on in [true, false, true] {
        expectEq(updateBoardHooks(file: f, on: on, command: hookCommand, createIfMissing: false, now: now), .changed, "每次都改了")
    }
    // 同一秒里改了三次：三份改动前的备份都要在
    expectEq(backups(of: f).count, 4, "第一次的那份，加三份带时间的")
}

func testBoardHooksDuplicateHooksKey() {
    // 配置里有两个 hooks 时，Claude Code 读的是后一个，钩子要装到后一个上
    let f = hookFile("settings.json", #"{"hooks": {}, "hooks": {}}"#)
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .changed, "装到生效的那个上")
    let v = parse(f)
    expectEq(v.objectPairs?.count, 1, "只剩一个 hooks")
    expectEq(commands(v, "SessionStart"), [hookCommand], "钩子在")
}

func testBoardHooksSkipInvalidUTF8() {
    // 值里有一个坏字节：不动这个文件，不然写回去时会被换成乱码
    let f = tempDir().appendingPathComponent("settings.json").path
    let bytes = Data([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d])
    try! bytes.write(to: URL(fileURLWithPath: f))
    expectEq(updateBoardHooks(file: f, on: true, command: hookCommand, createIfMissing: false), .skipped, "解不成 UTF-8 就不动")
    expectEq(try! Data(contentsOf: URL(fileURLWithPath: f)), bytes, "原样")
}

func testBoardHooksFollowSymlinks() {
    let dir = tempDir()
    let real = dir.appendingPathComponent("real-settings.json").path
    try! Data("{\"a\": 1}".utf8).write(to: URL(fileURLWithPath: real))
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real)
    let link = dir.appendingPathComponent("settings.json").path
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    lchmod(link, 0o777)
    expectEq(updateBoardHooks(file: link, on: true, command: hookCommand, createIfMissing: false), .changed, "装上了")
    expectEq(try! FileManager.default.destinationOfSymbolicLink(atPath: link), real, "链接还是链接，没被换成普通文件")
    expectEq(try! FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? Int, 0o600, "权限取的是真正那个文件的")
    let v = try! JSONValue.parse(try! String(contentsOfFile: real, encoding: .utf8))
    expectEq(commands(v, "SessionStart"), [hookCommand], "内容写进了真正的文件")
    // 备份里是改动前的内容，不是指向它的链接
    let first = try! JSONValue.parse(try! String(contentsOfFile: link + ".agentdock-backup", encoding: .utf8))
    expectEq(first["hooks"], nil, "第一次的备份里还没有钩子")
    expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link + ".agentdock-backup")) == nil, "备份不是链接")
}

func testBoardHooksPrunesOldestRevisionsFirst() {
    let f = hookFile("settings.json", "{}")
    let dir = (f as NSString).deletingLastPathComponent
    // 用户自己放在旁边的恢复目录：名字也带着这个前缀，清理时不能碰
    let manual = dir + "/settings.json.agentdock-backup-manual"
    try! FileManager.default.createDirectory(atPath: manual, withIntermediateDirectories: true)
    try! Data("keep".utf8).write(to: URL(fileURLWithPath: manual + "/recovery.json"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0...11 {
        // 每次改动前文件里带着自己的序号，备份里就能看出是第几版
        var v = try! JSONValue.parse(read(f))
        v.set("rev", .number(String(i)))
        try! Data(v.text.utf8).write(to: URL(fileURLWithPath: f))
        expectEq(updateBoardHooks(file: f, on: i % 2 == 0, command: hookCommand, createIfMissing: false, now: now), .changed, "第 \(i) 次改动")
    }
    let stamped = backups(of: f).filter { $0.hasPrefix("settings.json.agentdock-backup-") && $0 != "settings.json.agentdock-backup-manual" }
    let revs = stamped.map { Int(try! JSONValue.parse(try! String(contentsOfFile: dir + "/" + $0, encoding: .utf8))["rev"]?.text ?? "") ?? -1 }.sorted()
    expectEq(revs, Array(2...11), "同一秒里改了 12 次，留的是最近 10 版改动前的内容")
    expectEq(read(manual + "/recovery.json"), "keep", "用户自己的恢复目录原样留着")
}

func testBoardHooksStopsWhenBackupCannotBeWritten() {
    // 配置是个链接，链接所在的目录不可写（备份写不进去），链接指向的文件可写
    let realDir = tempDir().appendingPathComponent("real").path
    let linkDir = tempDir().appendingPathComponent("links").path
    try! FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
    let real = realDir + "/settings.json"
    try! Data("{}".utf8).write(to: URL(fileURLWithPath: real))
    let link = linkDir + "/settings.json"
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: linkDir)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkDir) }
    expectEq(updateBoardHooks(file: link, on: true, command: hookCommand, createIfMissing: false),
             .failed(tr("备份写不进去，没有改动配置", "could not write the backup; the configuration was not changed")), "备份写不进去就停")
    expectEq(read(real), "{}", "指向的文件没被改")
    expectEq(backups(of: link), [], "也没有留下半份备份")
}
