import Foundation

func testZoneIdentifier() {
    expectEq(zoneIdentifier(fromLocaltimeTarget: "/var/db/timezone/zoneinfo/Asia/Shanghai"), "Asia/Shanghai", "macOS 的链接目标")
    expectEq(zoneIdentifier(fromLocaltimeTarget: "../../usr/share/zoneinfo/America/Argentina/Buenos_Aires"), "America/Argentina/Buenos_Aires", "相对路径、多一级")
    expectEq(zoneIdentifier(fromLocaltimeTarget: "/usr/share/zoneinfo/UTC"), "UTC", "UTC")
    expect(zoneIdentifier(fromLocaltimeTarget: "/etc/localtime") == nil, "没有 zoneinfo 就取不出来")
    expect(zoneIdentifier(fromLocaltimeTarget: "/var/db/timezone/zoneinfo/") == nil, "空的")
    expect(TimeZone(identifier: appZone.identifier) != nil, "appZone 是一个认得的时区")
}

func testAppZoneSurvivesTimeZoneChangeNotification() {
    let before = appZone.identifier
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    expectEq(appZone.identifier, before, "收到通知后重新读一遍，读到的还是同一个")
}

func testSystemTimeZoneDidChangeKeepsZoneUsable() {
    let before = appZone.identifier
    systemTimeZoneDidChange()
    expectEq(appZone.identifier, before, "放掉缓存后重新读，还是同一个")
}
