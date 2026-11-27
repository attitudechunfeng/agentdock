import Foundation

func testModelNameWithoutVersion() {
    expectEq(modelName("gpt-"), "gpt-", "只有前缀时原样显示")
}

func testReadingUnreadableFiles() {
    let d = tempDir()
    // 目录、不存在的文件：读不到就当空的
    expectEq(tailLines(d, 100), [], "把目录当文件读")
    let missing = d.appendingPathComponent("nope.jsonl")
    expectEq(tailLines(missing, 100), [], "文件不存在")
    expectEq(historyItems(.claude, d), [], "历史骨架：目录")
    expectEq(historyItems(.claude, missing), [], "历史骨架：文件不存在")
    let s = Session(id: "x", kind: .claude, rawId: "x", transcript: d, app: "Claude", title: "t", project: "p",
                    running: false, updated: Date(), link: nil, appPath: "/Applications/Claude.app")
    expectEq(searchSessions([s], "anything"), [], "搜索：记录读不到")
    expectEq(readDetail(s).items.count, 0, "详情：记录读不到")
}
