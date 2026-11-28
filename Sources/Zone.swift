import Foundation

/// 系统时区（“系统设置 → 日期与时间”里选的那个），不受环境变量 TZ 影响：
/// 从终端带着 TZ 启动时 TimeZone.current 会跟着变，显示的时间就和系统时钟对不上。
/// Convoy 常驻在后台，出差或改了设置之后系统时区会变，所以收到通知就重新读一次
private final class SystemZone {
    private let lock = NSLock()
    private var zone: TimeZone?

    init() {
        // 通知到了只把缓存放掉，下次用到时再重新读
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    func invalidate() {
        lock.lock(); zone = nil; lock.unlock()
    }

    func current() -> TimeZone {
        lock.lock(); defer { lock.unlock() }
        if let zone { return zone }
        let z = resolveSystemZone()
        zone = z
        return z
    }
}

private let systemZone = SystemZone()
var appZone: TimeZone { systemZone.current() }

/// 系统时区变了：把缓存放掉，下次用到时重新读。给聊天页换时区之前先调它，不靠两个通知到达的先后顺序
func systemTimeZoneDidChange() {
    systemZone.invalidate()
}

private func resolveSystemZone() -> TimeZone {
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
          let id = zoneIdentifier(fromLocaltimeTarget: target), let zone = TimeZone(identifier: id) else { return .current }
    return zone
}

/// /etc/localtime 指向 /var/db/timezone/zoneinfo/<时区 id>，从链接目标里取出时区 id；取不出来返回 nil
func zoneIdentifier(fromLocaltimeTarget target: String) -> String? {
    guard let r = target.range(of: "zoneinfo/"), r.upperBound < target.endIndex else { return nil }
    return String(target[r.upperBound...])
}
