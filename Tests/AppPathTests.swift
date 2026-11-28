import Foundation

func testBoardHookCommandsAreDecoded() {
    // 路径里有单引号：命令为了 shell 转义带着反斜杠，写进 JSON 时又被转义一次
    let tricky = "'/Volumes/O'\\''Brien/Convoy.app/Contents/MacOS/Convoy' --board-hook"
    let dir = tempDir()
    let f = dir.appendingPathComponent("settings.json").path
    let obj: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": tricky]]]]]]
    try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: f))
    expect(!((try! String(contentsOfFile: f, encoding: .utf8)).contains(tricky)), "直接比文件原文对不上")
    expectEq(boardHookCommands(inFile: f), [tricky], "解析之后能对上")
    expectEq(boardHookCommands(inFile: f + ".missing"), nil, "文件不存在")
    let bad = dir.appendingPathComponent("hooks.json").path
    try! Data("{ not json".utf8).write(to: URL(fileURLWithPath: bad))
    expectEq(boardHookCommands(inFile: bad), nil, "读不懂的文件")
}
