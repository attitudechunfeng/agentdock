import Cocoa
import WebKit

// 演示模式：Convoy --demo-shots <输出目录>
// 用编出来的会话和项目把界面跑起来，截几张图给 README 用（不碰真实会话，也不写任何数据文件）。
// 主窗口截图：SwiftUI 部分用窗口自己画，聊天页（网页）用网页视图自己的截图，再拼起来

let demoMode = CommandLine.arguments.contains("--demo-shots")
var demoModelRef: Model?
/// 再加 --demo-gif：录 README 顶上那段动图（按分镜截一串画面，拼成 demo.gif）
let demoGif = CommandLine.arguments.contains("--demo-gif")
/// 动图里“发出去”的消息和 agent 接着做的事：追加到对应会话的详情后面
var demoExtra: [String: [Item]] = [:]

private let demoDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentdock-demo")
private func ago(_ min: Double) -> Date { Date().addingTimeInterval(-min * 60) }
private func iso(_ min: Double) -> String { ISO8601DateFormatter().string(from: ago(min)) }

private func demoFile(_ id: String) -> URL {
    try? FileManager.default.createDirectory(at: demoDir, withIntermediateDirectories: true)
    let f = demoDir.appendingPathComponent(id + ".jsonl")
    if !FileManager.default.fileExists(atPath: f.path) { try? "".write(to: f, atomically: true, encoding: .utf8) }
    return f
}

private let claudeApp = claudeAppPath, codexApp = codexAppPath, agyApp = antigravityAppPath

func demoSessions() -> [Session] {
    func s(_ id: String, _ kind: Kind, _ app: String, _ path: String, _ title: String, _ project: String, _ min: Double,
           running: Bool = false, unread: Bool = false, waiting: Bool = false, asking: Bool = false, model: String, perm: String) -> Session {
        var x = Session(id: id, kind: kind, rawId: id, transcript: demoFile(id), app: app, title: title, project: project,
                        running: running, updated: ago(min), link: nil, appPath: path)
        x.cwd = "/Users/demo/code/" + project
        x.model = model; x.perm = perm; x.waiting = waiting; x.asking = asking; x.nativeUnread = unread
        return x
    }
    return [
        s("demo-checkout", .claude, "Claude", claudeApp, tr("结账页改成单页流程", "Make checkout a single page"), "shop-web", 1, running: true, model: tr("Opus 5.5 高", "Opus 5.5 High"), perm: tr("接受编辑", "Accept edits")),
        s("demo-cache", .codex, "Codex", codexApp, tr("订单接口加缓存", "Cache the order API"), "shop-api", 3, running: true, model: tr("GPT-6.2 高", "GPT-6.2 High"), perm: tr("自动", "Auto")),
        s("demo-stock", .claude, "Claude", claudeApp, tr("修复购物车并发扣库存", "Fix concurrent stock deduction"), "shop-api", 12, unread: true, waiting: true, asking: true, model: tr("Opus 5.5 高", "Opus 5.5 High"), perm: tr("手动", "Ask")),
        s("demo-push", .antigravity, "Antigravity", agyApp, tr("iOS 推送集成", "iOS push notifications"), "shop-ios", 25, waiting: true, model: "Gemini 4 Neon", perm: "Default"),
        s("demo-report", .codex, "Codex", codexApp, tr("周报数据看板", "Weekly metrics dashboard"), "analytics", 48, unread: true, model: tr("GPT-6.2 中", "GPT-6.2 Medium"), perm: tr("自动", "Auto")),
        s("demo-a11y", .claude, "Claude", claudeApp, tr("登录页无障碍改进", "Login page accessibility"), "shop-web", 95, model: "Sonnet 5.5", perm: tr("接受编辑", "Accept edits")),
        s("demo-vector", .antigravity, "Antigravity", agyApp, tr("评估向量数据库选型", "Pick a vector database"), "search", 180, model: "Gemini 4 Neon", perm: "Default"),
        s("demo-docs", .codex, "Codex", codexApp, tr("整理 API 文档", "Clean up API docs"), "shop-api", 60 * 26, model: tr("GPT-6.2 中", "GPT-6.2 Medium"), perm: tr("自动", "Auto")),
        s("demo-ab", .claude, "Claude", claudeApp, tr("首页 A/B 实验分析", "Homepage A/B test analysis"), "analytics", 60 * 30, model: tr("Opus 5.5 高", "Opus 5.5 High"), perm: tr("手动", "Ask")),
    ]
}

func demoTool(_ id: String, _ name: String, _ verb: String, _ target: String, _ out: String, _ min: Double, cat: String = "cmd", done: Bool = true) -> Item {
    var t = Item(id: id, kind: "tool", name: name, verb: verb, summary: target, input: target, output: out, done: done, ts: iso(min))
    t.cat = cat
    return t
}

func demoDetail(_ s: Session) -> Detail {
    if s.id == "demo-stock" {
        var d = Detail(items: [Item(id: "s-u", kind: "user", text: tr("大促时偶尔超卖，查一下购物车扣库存。", "We occasionally oversell during sales. Look into how the cart deducts stock."), ts: iso(20)),
                               demoTool("s1", "Grep", tr("搜索", "Search"), "deductStock", "src/services/stock.ts", 19, cat: "search"),
                               Item(id: "s-a", kind: "assistant", text: tr("找到原因了：先查库存再扣减是两步，两笔订单同时进来会都查到“有货”。压测 200 并发复现了 3 次超卖。修法有两种，需要你选一下。", "Found it: checking stock and deducting it are two separate steps, so two orders arriving together both see “in stock”. A 200-concurrency load test reproduced 3 oversells. There are two ways to fix it; please pick one."), ts: iso(13))],
                       tasks: [], suggestion: nil, plan: [])
        d.ask = PendingAsk(id: "demo-ask", questions: [AskQ(question: tr("库存扣减用哪种方案？", "How should stock be deducted?"), header: tr("修复方案", "Fix"), multiSelect: false, options: [
            AskOption(label: tr("数据库行锁", "Database row lock"), description: tr("改动小，大促高峰可能排队", "Small change; may queue up at peak")),
            AskOption(label: tr("Redis 原子扣减", "Atomic Redis decrement"), description: tr("扛得住大促，需要和数据库对账", "Handles peak traffic; needs reconciliation with the database"))])])
        return d
    }
    guard s.id == "demo-checkout" else {
        return Detail(items: [Item(id: s.id + "-u", kind: "user", text: s.title, ts: iso(30)),
                              Item(id: s.id + "-a", kind: "assistant", text: tr("好的，我先看一下相关代码。", "Sure, let me look at the relevant code first."), ts: iso(29))],
                      tasks: [], suggestion: nil, plan: [])
    }
    var items: [Item] = [
        Item(id: "u1", kind: "user", text: tr("结账现在要走 3 个页面，流失很多。改成单页：地址、配送、支付放在一页，地址填完自动算运费。", "Checkout takes 3 pages and we lose a lot of people. Make it one page: address, shipping and payment together, and calculate shipping as soon as the address is filled in."), ts: iso(42)),
        Item(id: "t1", kind: "thinking", text: tr("先找到现有的三个结账页面和它们之间传的数据，再决定合并后的组件结构。", "First find the three checkout pages and the data passed between them, then decide the merged component structure."), ts: iso(41)),
    ]
    let tool = { (id: String, name: String, verb: String, target: String, out: String, min: Double, cat: String) in demoTool(id, name, verb, target, out, min, cat: cat) }
    items += [
        tool("c1", "Grep", tr("搜索", "Search"), "checkout", "src/pages/checkout/Address.tsx\nsrc/pages/checkout/Shipping.tsx\nsrc/pages/checkout/Payment.tsx", 41, "search"),
        tool("c2", "Read", tr("读取", "Read"), "Shipping.tsx", tr("（212 行）", "(212 lines)"), 40, "read"),
        Item(id: "n1", kind: "note", text: tr("三个页面之间靠 URL 参数传地址 id，运费在第二页才请求。合并后改成一个表单状态，地址变化时防抖请求运费。", "The pages pass the address id through URL parameters, and shipping is only requested on page two. After merging, one form state; shipping is requested (debounced) whenever the address changes."), ts: iso(39)),
        tool("c3", "Edit", tr("编辑文件", "Edit file"), "src/pages/checkout/Checkout.tsx", "", 30, "edit"),
        tool("c4", "Edit", tr("编辑文件", "Edit file"), "src/api/shipping.ts", "", 26, "edit"),
        tool("c5", "Bash", tr("运行命令", "Run command"), "npm test -- checkout", "PASS  checkout/Checkout.test.tsx (14 tests)\nTests: 14 passed, 14 total", 20, "cmd"),
    ]
    var end = Item(id: "e1", kind: "turnend", text: "x", ts: iso(19), took: 23 * 60 * 1000)
    end.files = [FileStat(path: "src/pages/checkout/Checkout.tsx", kind: "add", add: 186, del: 0),
                 FileStat(path: "src/api/shipping.ts", kind: "edit", add: 24, del: 9),
                 FileStat(path: "src/pages/checkout/Shipping.tsx", kind: "delete", add: 0, del: 212)]
    items += [
        Item(id: "a1", kind: "assistant", text: tr("""
        结账已改成单页，测试 14 个全部通过。

        - **一页填完**：地址、配送方式、支付方式在同一页，从上到下填。
        - **运费自动算**：地址填完 0.4 秒后自动请求运费，不用再点“下一步”。
        - **旧页面**：原来三个页面删掉了，旧链接会跳到新页面。

        还没做：手机上的布局只在模拟器里看过。
        """, """
        Checkout is now a single page, and all 14 tests pass.

        - **One page**: address, shipping method and payment on one page, filled top to bottom.
        - **Shipping calculated automatically**: requested 0.4 s after the address is complete, no more "Next" button.
        - **Old pages**: the three old pages are gone; old links redirect to the new one.

        Not done yet: the mobile layout has only been checked in the simulator.
        """), ts: iso(19)),
        end,
        Item(id: "u2", kind: "user", text: tr("可以，再把优惠券输入也放进来，放在支付上面。", "Looks good. Add the coupon field too, above payment."), ts: iso(3)),
        tool("c6", "Read", tr("读取", "Read"), "Coupon.tsx", tr("（88 行）", "(88 lines)"), 2, "read"),
    ]
    items += demoExtra[s.id] ?? []
    var d = Detail(items: items, tasks: [], suggestion: nil,
                   plan: [PlanItem(content: tr("找到优惠券组件和校验接口", "Find the coupon component and validation API"), status: "completed"),
                          PlanItem(content: tr("放进结账页、接上金额重算", "Add it to checkout and recalculate totals"), status: "in_progress"),
                          PlanItem(content: tr("补测试", "Add tests"), status: "pending")])
    d.model = s.model
    return d
}

func demoProjects() -> [Project] {
    func e(_ t: String, _ state: String = "", ev: String = "", date: String = "", s: String = "") -> BoardEntry {
        BoardEntry(text: t, date: date, session: s, state: state, evidence: ev)
    }
    var shop = Project(name: tr("电商网站改版", "Store redesign"))
    shop.goal = tr("下单转化率从 2.1% 提到 3% 以上，结账页首屏加载 1 秒内，上线前不出现超卖。", "Raise checkout conversion from 2.1% to 3%+, load checkout in under 1 s, and never oversell before launch.")
    shop.status = tr("单页结账已完成、正在加优惠券；库存并发问题定位到扣减不是原子操作，修复方案等你定。", "Single-page checkout is done and coupons are in progress. The stock bug is traced to a non-atomic deduction; the fix needs your decision.")
    shop.decisions = [e(tr("库存扣减用数据库行锁还是 Redis 原子扣减？行锁改动小，Redis 扛得住大促", "Deduct stock with a database row lock or an atomic Redis decrement? Row lock is a smaller change; Redis holds up better during sales."), s: tr("修复购物车并发扣库存", "Fix concurrent stock deduction"))]
    shop.sessions = ["demo-checkout", "demo-stock", "demo-cache", "demo-a11y", "demo-docs"]
    shop.updated = ago(2)
    var t1 = Track(title: tr("结账转化率", "Checkout conversion"), goal: tr("下单转化率 ≥ 3%", "Conversion ≥ 3%"))
    t1.state = "进行中"; t1.now = tr("单页结账已上测试环境，正在加优惠券；转化率要上线一周后才有数。", "Single-page checkout is on staging and coupons are being added; conversion numbers come a week after launch."); t1.updated = "11-26"
    t1.learned = [e(tr("把多步表单合成一页，比优化单步文案更有效", "Merging a multi-step form into one page beats polishing each step's copy"), "有效", ev: tr("灰度 10% 用户，结账完成率 41% → 52%", "10% rollout: checkout completion 41% → 52%")),
                  e(tr("进结账前强制注册会显著流失", "Forcing sign-up before checkout drives people away"), "无效", ev: tr("去掉强制注册后完成率 +6%", "Completion +6% after removing forced sign-up")),
                  e(tr("运费在填地址时就算出来，减少中途放弃", "Showing shipping cost while the address is entered reduces drop-off"), "待验证")]
    t1.next = [e(tr("优惠券放到支付上方并重算金额", "Put coupons above payment and recalculate totals")), e(tr("手机端真机走一遍", "Walk through on a real phone"))]
    t1.log = [e(tr("灰度结果：完成率 41% → 52%", "Rollout result: completion 41% → 52%"), date: "11-24"), e(tr("单页结账合入测试环境", "Single-page checkout merged to staging"), date: "11-26")]
    var t2 = Track(title: tr("库存不超卖", "No overselling"), goal: tr("并发 500 下单压测零超卖", "Zero oversells at 500 concurrent orders"))
    t2.state = "等你定"; t2.now = tr("已复现：两笔订单同时扣同一件库存会都成功。修复方案二选一，等你定。", "Reproduced: two orders taking the last item at once both succeed. Two possible fixes; your call."); t2.updated = "11-26"
    t2.learned = [e(tr("先查后扣在并发下必然超卖，扣减要做成一步原子操作", "Check-then-deduct always oversells under concurrency; deduction must be one atomic step"), "有效", ev: tr("压测 200 并发复现 3 次超卖", "3 oversells reproduced at 200 concurrent orders"))]
    t2.next = [e(tr("定方案后补压测脚本", "Add a load-test script once the fix is chosen"))]
    var t3 = Track(title: tr("首屏性能", "Checkout load time"), goal: tr("结账页首屏 ≤ 1 秒（4G）", "Checkout first paint ≤ 1 s on 4G"))
    t3.state = "卡住"; t3.now = tr("首屏 1.6 秒，大头是支付 SDK 同步加载；SDK 方还没给异步版本。", "1.6 s now, mostly the payment SDK loading synchronously; the vendor hasn't shipped an async version yet."); t3.updated = "11-25"
    t3.learned = [e(tr("图片懒加载对结账页帮助很小", "Lazy-loading images barely helps checkout"), "无效", ev: tr("首屏 1.7 → 1.6 秒", "First paint 1.7 → 1.6 s"))]
    var t4 = Track(title: tr("无障碍与文档", "Accessibility & docs"), goal: tr("登录和结账页通过读屏检查；API 文档覆盖全部接口", "Login and checkout pass screen-reader checks; API docs cover every endpoint"))
    t4.state = "已解决"; t4.now = tr("登录页读屏检查全部通过，API 文档已补齐 32 个接口。", "Login passes all screen-reader checks; all 32 endpoints are documented."); t4.updated = "11-25"
    shop.tracks = [t1, t2, t3, t4]
    shop.suggestions = [BoardSuggestion(kind: "新大类", title: tr("订单接口缓存", "Order API caching"), goal: tr("订单查询 P95 ≤ 120 ms", "Order lookup P95 ≤ 120 ms"),
                                        reason: tr("「订单接口加缓存」会话里已经在做，现有大类装不下", "Already underway in “Cache the order API”, and no current workstream covers it"))]

    var data = Project(name: tr("数据周报", "Weekly report"))
    data.goal = tr("每周一 9 点前自动出周报看板，核心指标口径和财务一致。", "Publish the weekly dashboard automatically by 9 am every Monday, with metrics matching finance.")
    data.status = tr("看板已能自动生成，GMV 口径和财务差 0.8%，在查退款时间点。", "The dashboard generates automatically; GMV differs from finance by 0.8%, checking how refunds are dated.")
    data.sessions = ["demo-report", "demo-ab"]; data.updated = ago(48)
    var d1 = Track(title: tr("指标口径对齐", "Match finance's numbers"), goal: tr("GMV 与财务差 ≤ 0.1%", "GMV within 0.1% of finance")); d1.state = "进行中"; d1.now = tr("差 0.8%，怀疑退款按下单日还是退款日算。", "Off by 0.8%; suspect refunds dated by order day vs. refund day.")
    var d2 = Track(title: tr("自动出报表", "Automatic reports"), goal: tr("每周一 9 点前自动生成", "Generated by 9 am every Monday")); d2.state = "已解决"; d2.now = tr("定时任务已上线，连续两周按时生成。", "The scheduled job is live and ran on time two weeks in a row.")
    data.tracks = [d1, d2]

    var app = Project(name: "iOS App")
    app.goal = tr("推送和深链上线，推送打开率 ≥ 8%。", "Ship push notifications and deep links, push open rate ≥ 8%.")
    app.status = tr("推送证书已配好，在等 Antigravity 那边批准修改 Info.plist。", "Push certificates are set up; waiting for approval in Antigravity to edit Info.plist.")
    app.sessions = ["demo-push"]; app.updated = ago(25)
    var a1 = Track(title: tr("推送集成", "Push integration"), goal: tr("测试机收到推送并能跳转", "Test device receives a push and opens the right screen")); a1.state = "进行中"; a1.now = tr("证书配好，等批准修改 Info.plist 后联调。", "Certificates done; testing end to end once the Info.plist edit is approved.")
    app.tracks = [a1]
    return [shop, app, data]
}

// MARK: 截图

@MainActor
func runDemoShots(_ model: Model, out: String) {
    // 用系统截图截这个窗口（要“屏幕录制”权限；SwiftUI 的内容应用自己画不出来）
    func capture(_ name: String, sheet: Bool = false, done: @escaping () -> Void) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 }),
              let w = sheet ? main.attachedSheet : main else { done(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", out + "/" + name + ".png"]
        try? p.run(); p.waitUntilExit()
        log("demo shot \(name) exit=\(p.terminationStatus)")
        done()
    }
    guard CGPreflightScreenCaptureAccess() else {
        _ = CGRequestScreenCaptureAccess()   // 让系统把 Convoy 列进“屏幕录制”，你去打开开关
        log("demo: no screen capture permission")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(2) }
        return
    }
    if let w = NSApp.windows.first(where: { $0.frame.width > 600 }) {
        w.setContentSize(demoGif ? NSSize(width: 1180, height: 740) : NSSize(width: 1320, height: 840))
        w.center()
    }
    if demoGif, let w = NSApp.windows.first(where: { $0.frame.width > 600 }) {
        // 窗口被别的窗口挡住时网页不重画、截出来是空的：录制期间放到最前面
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        runDemoGif(model, out: out); return
    }
    model.mode = .project
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        model.selectedId = "demo-checkout"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            capture("main") {
                model.mode = .time
                model.board = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    capture("board") {
                        model.board = model.boards.projects.first?.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            capture("project") {
                                NotificationCenter.default.post(name: .showGuide, object: nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { capture("guide", sheet: true) { exit(0) } }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: 动图（README 顶上那段）：按分镜截画面，每帧下面加一行说明，拼成 demo.gif

private struct GifFrame { let file: String; let delay: Double; let caption: String }

private func jsString(_ s: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)
}

@MainActor
private func runDemoGif(_ model: Model, out: String) {
    let dir = NSTemporaryDirectory() + "agentdock-gif-frames"
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var frames: [GifFrame] = []
    var scale = 0.5
    func shot(_ delay: Double, _ caption: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 }) else {
            log("demo gif: no window " + NSApp.windows.map { "\($0.isVisible) \(Int($0.frame.width))" }.joined(separator: ", ")); return
        }
        scale = 1 / w.backingScaleFactor
        let f = dir + String(format: "/f%02d.png", frames.count)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", f]
        try? p.run(); p.waitUntilExit()
        frames.append(GifFrame(file: f, delay: delay, caption: caption))
    }
    func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    func js(_ code: String) { model.chat.web.evaluateJavaScript(code) }
    func reselect(_ id: String) { if let s = model.sessions.first(where: { $0.id == id }) { model.chat.select(s) } }
    func type(_ t: String) { js("(()=>{const i=document.getElementById('input');i.value=\(jsString(t));i.dispatchEvent(new Event('input'));i.focus()})()") }

    Task { @MainActor in
        if let w = NSApp.windows.first(where: { $0.frame.width > 700 }) { NSApp.activate(); w.makeKeyAndOrderFront(nil) }
        await wait(0.5)
        log("demo gif: active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
        // 1. 三家的会话在一个列表里
        let c1 = tr("Claude、Codex、Antigravity 的会话，都在一个窗口里", "Claude, Codex and Antigravity sessions, all in one window")
        model.mode = .time
        await wait(1.5)
        model.selectedId = "demo-checkout"
        await wait(2.5)
        shot(2.8, c1)
        // 2. 直接在这里回复
        let c2 = tr("直接在这里回复，不用切换应用", "Reply right here, no app switching")
        let msg = tr("顺便把优惠后的金额显示在订单摘要里", "Also show the discounted total in the order summary")
        let n = 6
        for k in 1...n {
            type(String(msg.prefix(msg.count * k / n)))
            await wait(0.3)
            shot(k == n ? 0.9 : 0.15, c2)
        }
        type("")
        demoExtra["demo-checkout"] = [Item(id: "u3", kind: "user", text: msg, ts: iso(0))]
        reselect("demo-checkout")
        await wait(1.2)
        shot(1.0, c2)
        demoExtra["demo-checkout"]! += [demoTool("c7", "Edit", tr("编辑文件", "Edit file"), "src/pages/checkout/OrderSummary.tsx", "", 0, cat: "edit", done: false)]
        reselect("demo-checkout")
        await wait(1.2)
        shot(1.8, c2)
        // 3. agent 提问，点一下回答
        let c3 = tr("agent 提问时，点一下就能回答", "When an agent asks a question, answer with one click")
        model.selectedId = "demo-stock"
        await wait(2.2)
        shot(1.8, c3)
        js("document.querySelector('[data-ask=\"0:1\"]').click()")
        await wait(0.6)
        shot(2.0, c3)
        // 4. 项目看板
        let c4 = tr("项目看板：每个项目的目标和进度一目了然", "Project board: every project's goal and progress at a glance")
        model.board = ""
        await wait(1.8)
        shot(2.6, c4)
        model.board = model.boards.projects.first?.id
        await wait(1.8)
        shot(3.4, c4)
        writeGif(frames, scale: scale, to: out + "/demo.gif")
        log("demo gif \(frames.count) frames")
        exit(0)
    }
}

private func writeGif(_ frames: [GifFrame], scale: Double, to path: String) {
    func load(_ f: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    guard let first = frames.first.flatMap({ load($0.file) }) else { return }
    let bar = 54
    let W = Int(Double(first.width) * scale), H0 = Int(Double(first.height) * scale), H = H0 + bar
    try? FileManager.default.removeItem(atPath: path)
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for f in frames {
        guard let img = load(f.file),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))   // 窗口圆角外和说明条同色
        ctx.draw(img, in: CGRect(x: 0, y: bar, width: W, height: H0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let str = NSAttributedString(string: f.caption, attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .semibold),
                                                                     .foregroundColor: NSColor.white, .paragraphStyle: para])
        let h = str.size().height
        str.draw(in: CGRect(x: 0, y: (Double(bar) - h) / 2, width: Double(W), height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { continue }
        CGImageDestinationAddImage(dest, out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.delay,
                                                                              kCGImagePropertyGIFUnclampedDelayTime: f.delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
}
