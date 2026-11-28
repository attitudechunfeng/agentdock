import Foundation

var passed = 0, failed = 0

func expect(_ ok: Bool, _ what: String) {
    if ok { passed += 1 } else { failed += 1; print("FAIL " + what) }
}

func expectEq<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    expect(got == want, "\(what)：得到 \(got)，应为 \(want)")
}

/// 新建的空临时目录，测试之间互不影响
func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("convoy-tests-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
