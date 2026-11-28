import SwiftUI

// 项目看板界面：总览（每个项目一张卡）和单个项目的看板。
// 单个项目按“大类”组织：每个大类一行，看状态和现在走到哪；点开看归纳的结论、进展、下一步。
// 每处都能手动改：铅笔改字、垃圾桶删掉（删掉的 agent 不再加回来）、＋ 追加（你加的 agent 保留原文）

/// 看板页不跟着会话列表刷新整页重画（会话在跑时列表一秒变一次）：只引用 Model，不订阅它；
/// 要跟着会话状态变的小块（在跑的转圈、关联会话列表）各自订阅
struct BoardView: View {
    let model: Model
    @ObservedObject var store: BoardStore
    let pid: String

    var body: some View {
        if let p = store.projects.first(where: { $0.id == pid }) {
            ProjectBoard(model: model, store: store, p: p)
        } else {
            BoardOverview(model: model, store: store)
        }
    }
}

private let warn = Color(red: 0.85, green: 0.25, blue: 0.2)
private let good = Color(red: 0.2, green: 0.6, blue: 0.35)

func stateColor(_ s: String) -> Color {
    switch s {
    case "卡住": return warn
    case "等你定": return .orange
    case "已解决": return good
    case "搁置": return .gray
    default: return .accentColor
    }
}
private func verdictColor(_ s: String) -> Color { s == "有效" ? good : s == "无效" ? warn : .gray }
private let stateOrder = ["等你定", "卡住", "进行中", "已解决", "搁置"]

private func ago(_ d: Date?) -> String {
    guard let d else { return tr("还没汇总", "Not summarized yet") }
    let s = Date().timeIntervalSince(d)
    if s < 60 { return tr("刚刚更新", "Updated just now") }
    if s < 3600 { return tr("\(Int(s / 60)) 分钟前更新", "Updated \(Int(s / 60)) min ago") }
    if s < 86400 { return tr("\(Int(s / 3600)) 小时前更新", "Updated \(Int(s / 3600)) hr ago") }
    let n = Int(s / 86400)
    return tr("\(n) 天前更新", "Updated \(n) day\(n == 1 ? "" : "s") ago")
}

private func today() -> String { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: Date()) }

/// 点一下弹出的小菜单。SwiftUI 的 Menu 每个都要建一个系统弹出按钮，几十个时展开详情页很卡；
/// 这里平时只是个普通按钮，点了才临时建菜单
private final class MenuPick: NSObject {
    let f: (String) -> Void
    init(_ f: @escaping (String) -> Void) { self.f = f }
    @objc func fire(_ i: NSMenuItem) { f(i.representedObject as? String ?? "") }
}
/// items 是内部取值（中文枚举），label 把它转成显示文字；选中后回传内部取值
func popMenu(_ items: [String], current: String, label: (String) -> String = { $0 }, _ pick: @escaping (String) -> Void) {
    let m = NSMenu()
    let h = MenuPick(pick)
    for it in items {
        let mi = NSMenuItem(title: label(it), action: #selector(MenuPick.fire(_:)), keyEquivalent: "")
        mi.target = h; mi.representedObject = it; mi.state = it == current ? .on : .off
        m.addItem(mi)
    }
    withExtendedLifetime(h) { _ = m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
}

func tagPill(_ t: String, _ c: Color) -> some View {
    Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(c)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.12)))
}

/// 顶部一条：汇总 agent 选择、自动更新开关、现在在做什么
struct BoardHeader: View {
    @ObservedObject var store: BoardStore
    @State private var hooksOn = boardHooksInstalled()

    private func setHooks(_ on: Bool) {
        let a = NSAlert()
        if on {
            a.messageText = tr("让会话自动读到项目看板？", "Share the project board with your sessions?")
            a.informativeText = tr("""
            会在这些配置里加一个钩子（其他钩子不动，改之前各备份一份 .agentdock-backup-时间）：
            · Claude Code：~/.claude/settings.json（以及本机配置里其他 Claude 账号的 settings.json）
            · Codex：~/.codex/hooks.json（Codex 下次用到时会请你确认信任这个钩子）

            之后你在某条会话里发消息时，如果它所属项目的看板自上次以来有更新（或会话刚开始、刚压缩），就把看板精简版（总目标、各大类进度、等你定、有效 / 无效做法）附进这一轮；没更新什么都不加。随时可以在这里关掉。
            """, """
            This adds a hook to these config files (other hooks are left alone, and each file is backed up before every change as .agentdock-backup-<time>):
            · Claude Code: ~/.claude/settings.json (plus the settings.json of any other Claude accounts in your local config)
            · Codex: ~/.codex/hooks.json (Codex will ask you to trust this hook the next time it runs)

            After that, when you send a message in a session, if its project board has changed since last time (or the session just started or was just compacted), a condensed board (overall goal, workstream progress, decisions waiting on you, approaches that do and don't work) is attached to that turn. If nothing changed, nothing is added. You can turn this off here anytime.
            """)
            a.addButton(withTitle: tr("装上", "Install"))
        } else {
            a.messageText = tr("关掉会话自动读看板？", "Stop sharing the board with sessions?")
            a.informativeText = tr("会把 Claude Code 和 Codex 配置里 Convoy 加的钩子摘掉，其他钩子不动。",
                                   "Removes the hooks Convoy added to your Claude Code and Codex configs. Other hooks are left alone.")
            a.addButton(withTitle: tr("关掉", "Turn off"))
        }
        a.addButton(withTitle: tr("取消", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.writeContextFiles()
        setBoardHooks(on)
        hooksOn = boardHooksInstalled()
    }
    var body: some View {
        HStack(spacing: 10) {
            Picker(tr("汇总 agent", "Summarizer"), selection: Binding(
                get: { store.settings.agent + ":" + store.settings.model },
                set: { v in
                    let p = v.split(separator: ":", maxSplits: 1).map(String.init)
                    guard p.count == 2 else { return }
                    store.settings.agent = p[0]
                    switch p[0] {
                    case "codex": store.settings.codexEffort = p[1]
                    case "gemini": store.settings.geminiModel = p[1]
                    default: store.settings.claudeModel = p[1]
                    }
                })) {
                ForEach(BoardAgentChoice.all) { Text($0.label).tag($0.id) }
            }
            .frame(maxWidth: 360)
            Toggle(tr("每轮回复结束后自动更新", "Auto-update after each reply"), isOn: $store.settings.auto).toggleStyle(.checkbox)
            Toggle(tr("会话自动读到看板", "Share board with sessions"), isOn: Binding(get: { hooksOn }, set: { setHooks($0) })).toggleStyle(.checkbox)
                .help(tr("在 Claude Code 和 Codex 里装一个钩子：你在某条会话里发消息时，如果它所属项目的看板有更新，就把精简版附进这一轮",
                         "Installs a hook in Claude Code and Codex: when you send a message in a session whose project board has changed, a condensed board is attached to that turn"))
            Spacer()
            if let b = store.busy {
                ProgressView().controlSize(.small)
                Text(b + (store.queued > 0 ? tr("，还有 \(store.queued) 条排队", ", \(store.queued) more queued") : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if store.queued > 0 {
                Text(tr("\(store.queued) 条会话等这轮结束后汇总", "\(store.queued) session\(store.queued == 1 ? "" : "s") queued for the next summary")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 可编辑的小部件

/// 一段文字：悬停出现铅笔（改）和垃圾桶（删）；回车保存、Esc 取消
struct EditableText: View {
    let text: String
    var placeholder = tr("（空）", "(empty)")
    var font: Font = .body
    var selectable = false   // 可选中复制；条目多时开销大，只给总目标、现状这种单条的开
    let onSave: (String) -> Void
    var onDelete: (() -> Void)? = nil
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false

    var body: some View {
        if editing {
            HStack(alignment: .top, spacing: 6) {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(font).lineLimit(1...10)
                    .onSubmit(save).onExitCommand { editing = false }
                Button(tr("保存", "Save"), action: save).controlSize(.small)
                Button(tr("取消", "Cancel")) { editing = false }.controlSize(.small)
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Text(text.isEmpty ? placeholder : text).font(font)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(Selectable(on: selectable))
                HStack(spacing: 4) {
                    Button { draft = text; editing = true } label: { Image(systemName: "pencil") }.help(tr("修改", "Edit"))
                        .opacity(hover ? 1 : 0.35)
                    if let onDelete { Button(action: onDelete) { Image(systemName: "trash") }.help(tr("删掉，不再追踪", "Delete and stop tracking")).opacity(hover ? 1 : 0) }
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            .onHover { hover = $0 }
        }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !t.isEmpty, t != text { onSave(t) }
    }
}

private struct Selectable: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.textSelection(.enabled) } else { content } }
}

/// “＋ 追加”：点一下变输入框
struct AddLine: View {
    let label: String
    let onAdd: (String) -> Void
    @State private var adding = false
    @State private var draft = ""
    var body: some View {
        if adding {
            HStack(spacing: 6) {
                TextField(label, text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...6)
                    .onSubmit(add).onExitCommand { adding = false }
                Button(tr("添加", "Add"), action: add).controlSize(.small)
                Button(tr("取消", "Cancel")) { adding = false }.controlSize(.small)
            }
        } else {
            Button { draft = ""; adding = true } label: { Label(label, systemImage: "plus") }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        adding = false
        if !t.isEmpty { onAdd(t) }
    }
}

/// 一组条目（等你定、结论、进展、下一步）：每条能改能删，末尾能追加
struct EntryList: View {
    let entries: [BoardEntry]
    var tint: Color = .secondary
    var dated = false
    var verdict = false
    let kind: String                         // 记修改时用：等你定 / 结论 / 下一步 / 进展（英文界面不带冠词，如 "pending decision"）
    let addLabel: String
    let set: ([BoardEntry], String) -> Void  // 新的列表、改了什么
    let remove: (BoardEntry) -> Void
    let sessionLink: (String) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 8) {
                    if verdict {
                        Button {
                            popMenu(["有效", "无效", "待验证"], current: e.state, label: stateLabel) { v in
                                change(e, tr("把\(kind)「\(e.text)」标成\(v)", "Marked the \(kind) \"\(e.text)\" as \(stateLabel(v))")) { $0.state = v }
                            }
                        } label: { tagPill(e.state == "无效" ? tr("无效·别再试", "Doesn't work · don't retry") : stateLabel(e.state.isEmpty ? "待验证" : e.state), verdictColor(e.state)) }
                        .buttonStyle(.plain).help(tr("改成有效 / 无效 / 待验证", "Mark as works / doesn't work / unverified"))
                    } else {
                        Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 6)
                    }
                    if dated && !e.date.isEmpty { Text(e.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 2) {
                        EditableText(text: e.text, onSave: { t in change(e, tr("把\(kind)「\(e.text)」改成「\(t)」", "Changed the \(kind) \"\(e.text)\" to \"\(t)\"")) { $0.text = t } }, onDelete: { remove(e) })
                        if !e.evidence.isEmpty { Text(tr("依据：", "Evidence: ") + e.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        HStack(spacing: 6) {
                            if e.by == "user" { Text(tr("你写的", "Yours")).font(.caption2).foregroundStyle(.tertiary) }
                            if !e.session.isEmpty { sessionLink(e.session) }
                        }
                    }
                }
            }
            AddLine(label: addLabel) { t in
                set(entries + [BoardEntry(text: t, date: dated ? today() : "", state: verdict ? "待验证" : "", by: "user")], tr("追加\(kind)：\(t)", "Added a \(kind): \(t)"))
            }
        }
    }

    private func change(_ e: BoardEntry, _ note: String, _ f: (inout BoardEntry) -> Void) {
        var xs = entries
        guard let i = xs.firstIndex(where: { $0.id == e.id }) else { return }
        f(&xs[i]); xs[i].by = "user"
        set(xs, note)
    }
}

// MARK: 总览

struct BoardOverview: View {
    let model: Model
    @ObservedObject var store: BoardStore

    var body: some View {
        ScrollView { content }.background(Color(nsColor: .textBackgroundColor))
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("项目看板", "Project board")).font(.title2.bold())
                Text(tr("\(store.projects.count) 个项目", "\(store.projects.count) project\(store.projects.count == 1 ? "" : "s")")).foregroundStyle(.secondary)
                Spacer()
                Button(tr("新建项目", "New project")) { if let n = askName(tr("新项目名", "New project name"), "") { model.board = store.newProject(n).id } }.controlSize(.small)
                Button(tr("打开项目文件夹", "Open project folder")) { NSWorkspace.shared.open(boardDir) }.controlSize(.small)
            }
            BoardHeader(store: store)
            if let e = store.lastError {
                Text(tr("上次汇总出错：", "Last summary failed: ") + e).font(.caption).foregroundStyle(warn).textSelection(.enabled)
            }
            let n7 = store.backfillCount(days: 7)
            if store.projects.isEmpty || n7 > 0 {
                HStack(spacing: 10) {
                    Text(store.projects.isEmpty
                         ? tr("还没有项目。可以先把最近 7 天的 \(n7) 条会话汇总一遍建起看板；之后每轮回复结束会自动更新。",
                              "No projects yet. Summarize the \(n7) sessions from the last 7 days to build the board; after that it updates automatically after each reply.")
                         : tr("最近 7 天还有 \(n7) 条会话没进过看板。", "\(n7) session\(n7 == 1 ? "" : "s") from the last 7 days \(n7 == 1 ? "hasn't" : "haven't") been added to the board yet."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(store.projects.isEmpty ? tr("从最近 7 天的会话建看板", "Build board from the last 7 days") : tr("汇总这些会话", "Summarize these sessions")) { store.backfill(days: 7) }
                        .disabled(n7 == 0 || store.busy != nil)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(store.sorted) { p in
                    Button { model.board = p.id } label: { ProjectCard(p: p, model: model) }
                        .buttonStyle(.plain).accessibilityLabel(tr("项目 ", "Project ") + p.name)
                }
            }
        }
        .padding(24)
    }
}

struct ProjectCard: View {
    let p: Project
    let model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.headline).lineLimit(1)
                Spacer()
                RunningBadge(model: model, ids: p.sessions, label: false)
                Text(ago(p.updated)).font(.caption2).foregroundStyle(.tertiary)
            }
            if !p.goal.isEmpty { Text(p.goal).font(.callout).lineLimit(3) }
            HStack(spacing: 6) {
                if !p.decisions.isEmpty { tagPill("\(stateLabel("等你定")) \(p.decisions.count)", warn) }
                if !p.suggestions.isEmpty { tagPill(tr("建议 \(p.suggestions.count)", "Suggestions \(p.suggestions.count)"), .purple) }
                let stuck = p.tracks.filter { $0.state == "卡住" }.count
                if stuck > 0 { tagPill("\(stateLabel("卡住")) \(stuck)", warn) }
                Text(tr("\(p.tracks.count) 个大类 · \(p.sessions.count) 条会话",
                        "\(p.tracks.count) workstream\(p.tracks.count == 1 ? "" : "s") · \(p.sessions.count) session\(p.sessions.count == 1 ? "" : "s")")).font(.caption2).foregroundStyle(.secondary)
            }
            // 每个大类一行：状态点、名字、现在走到哪
            VStack(alignment: .leading, spacing: 4) {
                ForEach(p.tracks.sorted { (stateOrder.firstIndex(of: $0.state) ?? 9) < (stateOrder.firstIndex(of: $1.state) ?? 9) }.prefix(5)) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(stateColor(t.state)).frame(width: 6, height: 6)
                        Text(t.title).font(.caption.weight(.medium)).lineLimit(1).layoutPriority(1)
                        Text(t.now).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

// MARK: 单个项目
// 版式：顶栏（返回、项目名、刷新、更多）→ 目标卡（总目标、现状、各状态计数）→ “需要你处理”（等你定、模型建议）
// → 大类卡片（左边一条状态色，收起时看名字、完成标准、现在走到哪；展开后左结论、右下一步和进展）→ 关联会话 → 汇总设置

let card = Color.primary.opacity(0.035)
private let cardLine = Color.primary.opacity(0.07)

private extension View {
    func cardBox(_ tint: Color? = nil) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint?.opacity(0.07) ?? card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint?.opacity(0.25) ?? cardLine))
    }
}

func sectionTitle(_ t: String, _ icon: String, note: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon).foregroundStyle(.secondary).font(.callout)
        Text(t).font(.headline)
        if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
    }
}

/// 项目里有会话在跑时转圈
struct RunningBadge: View {
    @ObservedObject var model: Model
    let ids: [String]
    var label = true
    var body: some View {
        if model.sessions.contains(where: { ids.contains($0.id) && $0.running }) {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); if label { Text(tr("有会话在跑", "Session running")).font(.caption) } }.foregroundStyle(.secondary)
        }
    }
}

struct ProjectBoard: View {
    let model: Model
    @ObservedObject var store: BoardStore
    let p: Project
    @State private var renaming = false
    @State private var newName = ""
    @State var open = Set<String>()     // 展开的大类
    @State private var width: CGFloat = 980   // 详情页宽度：展开后的两栏按它定死栏宽，免得排版时反复试宽度（很慢）

    /// 展开后左右两栏各自的宽度：内容区（最宽 1000，减左右边距 56）减卡片左色条和内边距，再减栏间距，对半分
    private var colWidth: CGFloat { max(200, (min(width, 1000) - 56 - 4 - 28 - 24) / 2) }

    var body: some View {
        GeometryReader { g in
            ScrollView { content }
                .onAppear { if demoMode, open.isEmpty, let t = p.tracks.first { open = [t.id] } }
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = $0 }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func edit(_ note: String? = nil, _ f: @escaping (inout Project) -> Void) { store.edit(p.id, note: note, f) }

    /// 删项目：弹窗确认（会话本身不受影响，之后也不再自动归进看板）
    private func confirmDeleteProject() {
        let a = NSAlert()
        a.messageText = tr("删除项目「\(p.name)」？", "Delete project \"\(p.name)\"?")
        a.informativeText = tr("看板内容和项目文件会删掉，会话本身不受影响。这个项目的会话之后不再自动归进看板；想让某条会话回来，右键它 →「归到项目」。",
                               "The board content and project file will be deleted; the sessions themselves aren't affected. This project's sessions won't be added to the board automatically anymore. To bring a session back, right-click it → \"Move to project\".")
        a.alertStyle = .warning
        a.addButton(withTitle: tr("删除", "Delete"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.delete(p.id)
        model.board = ""
    }

    private var sessions: [Session] {
        p.sessions.compactMap { id in model.sessions.first { $0.id == id } }.sorted { $0.updated > $1.updated }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar
            if !p.edits.isEmpty { editsBar }
            if let e = store.lastError { Text(tr("上次汇总出错：", "Last summary failed: ") + e).font(.caption).foregroundStyle(warn).textSelection(.enabled) }
            goalCard
            attention
            tracksBlock
            sessionsBlock
            footer
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(maxWidth: 1000, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: 顶栏

    var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.board = "" } label: { Label(tr("全部项目", "All projects"), systemImage: "chevron.left").font(.callout) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                if renaming {
                    TextField(tr("项目名", "Project name"), text: $newName).textFieldStyle(.roundedBorder).font(.title2).frame(maxWidth: 360)
                        .onSubmit { store.rename(p.id, newName.trimmingCharacters(in: .whitespaces)); renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    Text(p.name).font(.system(size: 24, weight: .bold))
                        .onTapGesture(count: 2) { newName = p.name; renaming = true }
                        .help(tr("双击改名", "Double-click to rename"))
                }
                RunningBadge(model: model, ids: p.sessions)
                Spacer()
                Text(ago(p.updated)).font(.caption).foregroundStyle(.tertiary)
                refreshButton
                Menu {
                    Button(tr("改名…", "Rename…")) { newName = p.name; renaming = true }
                    Menu(tr("合并到", "Merge into")) {
                        ForEach(store.sorted.filter { $0.id != p.id }) { t in Button(t.name) { store.merge(p.id, into: t.id); model.board = t.id } }
                    }
                    Button(tr("只汇总还没汇总的新内容", "Summarize new content only")) { store.updateNow(p) }
                    Button(tr("清空后从头汇总", "Rebuild from scratch")) { store.rebuild(p) }
                        .help(tr("目标和大类的定义、你加的条目、删掉的记录都保留，只清掉模型汇总的内容",
                                 "Keeps the goal and workstream definitions, items you added, and what you deleted; clears only what the model summarized"))
                    Divider()
                    Button(tr("复制给 agent 的提示", "Copy prompt for agent")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tr("开始之前先读 \(p.fileURL.path)，这是这个项目的看板（目标、各大类进度、已验证的结论、等我定的事），按它对齐后再动手。",
                                                          "Before you start, read \(p.fileURL.path). It's this project's board (goal, workstream progress, verified findings, decisions waiting on me). Align with it before making changes."), forType: .string)
                        model.say(tr("已复制，粘贴到会话里即可", "Copied. Paste it into a session."))
                    }
                    Button(tr("在访达中显示项目文件", "Show project file in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([p.fileURL]) }
                    Divider()
                    Button(tr("删除项目…", "Delete project…"), role: .destructive) { confirmDeleteProject() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("更多", "More"))
            }
        }
    }

    @ViewBuilder var refreshButton: some View {
        if store.refreshing.contains(p.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(store.busy?.contains(p.name) == true ? tr("正在刷新…", "Refreshing…") : tr("排队刷新…", "Queued to refresh…")).font(.callout).foregroundStyle(.secondary)
            }
        } else if p.edits.isEmpty {
            Button { store.refresh(p.id) } label: { Label(tr("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                .controlSize(.large)
                .help(tr("重读各会话最近的内容，让模型按现在的目标和大类把进度、结论重新整理一遍",
                         "Re-reads recent content from each session and has the model reorganize progress and findings under the current goal and workstreams"))
        } else {
            Button { store.refresh(p.id) } label: {
                Label(tr("按我的 \(p.edits.count) 处修改刷新", "Refresh with my \(p.edits.count) edit\(p.edits.count == 1 ? "" : "s")"), systemImage: "arrow.clockwise")
            }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help(tr("把你的修改和各会话最近的内容交给模型，按你的修改重新整理",
                         "Sends your edits and recent session content to the model to reorganize the board around your edits"))
        }
    }

    var editsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
                Text(tr("你改了 \(p.edits.count) 处，点右上角按钮让模型按你的修改重新整理进度和结论。",
                        "You made \(p.edits.count) edit\(p.edits.count == 1 ? "" : "s"). Click the button at the top right to have the model reorganize progress and findings around them.")).font(.callout)
                Spacer()
                Button(tr("不用刷新", "Don't refresh")) { store.edit(p.id) { $0.edits = [] } }.buttonStyle(.borderless).font(.caption)
                    .help(tr("修改本身保留，只是不再提示刷新", "Your edits stay; this only hides the refresh prompt"))
            }
            DisclosureGroup(tr("改了什么", "What changed")) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(p.edits.enumerated()), id: \.offset) { _, e in Text("· " + e).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .cardBox(.accentColor)
    }

    // MARK: 目标卡

    var goalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tr("总目标", "Overall goal")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if p.goalByUser { Text(tr("你定的", "Set by you")).font(.caption2).foregroundStyle(.tertiary) }
                }
                EditableText(text: p.goal, placeholder: tr("还没有目标，点铅笔写一个", "No goal yet. Click the pencil to write one."), font: .title3.weight(.medium), selectable: true) { t in
                    edit(tr("把项目总目标改成：", "Changed the overall goal to: ") + t) { $0.goal = t; $0.goalByUser = true }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("现状", "Status")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                EditableText(text: p.status, placeholder: store.busy != nil ? tr("正在汇总…", "Summarizing…") : tr("还没汇总，点“刷新”", "Not summarized yet. Click Refresh."),
                             font: .callout, selectable: true) { t in
                    edit(tr("把现状改成：", "Changed the status to: ") + t) { $0.status = t }
                }
            }
            Divider()
            // 各状态计数：一眼看全局进度
            HStack(spacing: 14) {
                ForEach(stateOrder, id: \.self) { st in
                    let n = p.tracks.filter { $0.state == st }.count
                    if n > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(stateColor(st)).frame(width: 8, height: 8)
                            Text(stateLabel(st)).font(.caption).foregroundStyle(.secondary)
                            Text("\(n)").font(.caption.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                Spacer()
                let ok = p.tracks.reduce(0) { $0 + $1.learned.filter { $0.state == "有效" }.count }
                let bad = p.tracks.reduce(0) { $0 + $1.learned.filter { $0.state == "无效" }.count }
                if ok + bad > 0 {
                    Text(tr("沉淀结论：有效 \(ok) · 无效 \(bad)", "Findings: \(ok) work · \(bad) don't work")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .cardBox()
    }

    // MARK: 需要你处理：等你定 + 模型建议

    @ViewBuilder var attention: some View {
        if !p.decisions.isEmpty || !p.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(tr("需要你处理", "Needs your attention"), "exclamationmark.bubble",
                             note: p.suggestions.isEmpty ? nil : tr("模型的建议不会自动生效，采纳了才改", "Model suggestions don't take effect until you accept them"))
                if !p.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("等你定（\(p.decisions.count)）", "Needs your decision (\(p.decisions.count))")).font(.caption.weight(.semibold)).foregroundStyle(warn)
                        EntryList(entries: p.decisions, tint: warn, kind: tr("等你定的事", "pending decision"), addLabel: tr("追加一件等你定的事", "Add a decision"),
                                  set: { xs, n in edit(n) { $0.decisions = xs } },
                                  remove: { e in edit(tr("删掉等你定的事：", "Deleted pending decision: ") + e.text) { $0.decisions.removeAll { $0.id == e.id }; $0.ignore(e.text) } },
                                  sessionLink: link)
                    }
                }
                if !p.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("模型的建议（\(p.suggestions.count)）", "Model suggestions (\(p.suggestions.count))")).font(.caption.weight(.semibold)).foregroundStyle(.purple)
                        ForEach(p.suggestions) { suggestionRow($0) }
                    }
                }
            }
            .cardBox(warn)
        }
    }

    func suggestionRow(_ x: BoardSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            tagPill(stateLabel(x.kind), .purple)
            VStack(alignment: .leading, spacing: 3) {
                switch x.kind {
                case "改目标":
                    Text(tr("总目标改成：", "Change overall goal to: ") + x.goal).textSelection(.enabled)
                case "改大类":
                    let old = p.tracks.first { $0.id == x.trackId }
                    Text(tr("「\(old?.title ?? "?")」→「\(x.title)」", "\"\(old?.title ?? "?")\" → \"\(x.title)\"")).textSelection(.enabled)
                    if !x.goal.isEmpty { Text(tr("完成标准：", "Done when: ") + x.goal).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                default:
                    Text(x.title).font(.body.weight(.semibold))
                    if !x.goal.isEmpty { Text(tr("完成标准：", "Done when: ") + x.goal).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if !x.reason.isEmpty { Text(tr("理由：", "Reason: ") + x.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            Button(tr("采纳", "Accept")) {
                edit(tr("采纳建议（\(x.kind)）：", "Accepted suggestion (\(stateLabel(x.kind))): ") + (x.kind == "改目标" ? x.goal : x.title)) { $0.adopt(x) }
            }
                .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
            Button(tr("忽略", "Dismiss")) { store.edit(p.id) { $0.ignore(x.key); $0.suggestions.removeAll { $0.uid == x.uid } } }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.06)))
    }

    /// 出处会话名：点一下打开那条会话
    func link(_ title: String) -> AnyView {
        let s = sessions.first { $0.title == title }
        if let s { return AnyView(Button("— " + title) { model.selectedId = s.id }.buttonStyle(.link).font(.caption2)) }
        return AnyView(Text("— " + title).font(.caption2).foregroundStyle(.tertiary))
    }

    // MARK: 大类

    @ViewBuilder var tracksBlock: some View {
        let ts = p.tracks.sorted { (stateOrder.firstIndex(of: $0.state) ?? 9) < (stateOrder.firstIndex(of: $1.state) ?? 9) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(tr("各大类进度", "Workstreams"), "square.stack.3d.up", note: tr("点卡片展开结论、下一步和进展", "Click a card to see findings, next steps, and progress"))
                Spacer()
                if !ts.isEmpty {
                    Button(open.count == ts.count ? tr("全部收起", "Collapse all") : tr("全部展开", "Expand all")) {
                        open = open.count == ts.count ? [] : Set(ts.map(\.id))
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
            ForEach(ts) { trackCard($0) }
            AddLine(label: tr("新增大类", "New workstream")) { title in
                edit(tr("新建大类「\(title)」", "Created workstream \"\(title)\"")) { $0.tracks.append(Track(title: title, manual: true)) }
            }
            if !p.ignored.isEmpty {
                DisclosureGroup(tr("不追踪的（\(p.ignored.count)）", "Not tracked (\(p.ignored.count))")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("这些是你删掉或忽略的，模型不会再加回来。点“恢复”撤销。", "You deleted or dismissed these, so the model won't add them back. Click Restore to undo.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(p.ignored, id: \.self) { t in
                            HStack {
                                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Button(tr("恢复", "Restore")) { edit(tr("恢复追踪：", "Resumed tracking: ") + t) { $0.ignored.removeAll { $0 == t } } }.buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func trackCard(_ t: Track) -> some View {
        let expanded = open.contains(t.id)
        let ok = t.learned.filter { $0.state == "有效" }.count, bad = t.learned.filter { $0.state == "无效" }.count
        return HStack(spacing: 0) {
            Rectangle().fill(stateColor(t.state)).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                // 收起时也看得到的：状态、名字、完成标准、现在走到哪
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        popMenu(Track.states, current: t.state, label: stateLabel) { s in
                            edit(tr("把大类「\(t.title)」的状态改成\(s)", "Changed workstream \"\(t.title)\" state to \(stateLabel(s))")) { $0.track(t.id) { $0.state = s } }
                        }
                    } label: { tagPill(stateLabel(t.state), stateColor(t.state)) }
                    .buttonStyle(.plain).help(tr("改状态", "Change state"))
                    Text(t.title).font(.system(size: 15, weight: .semibold))
                    if t.manual { Text(tr("你定的", "Set by you")).font(.caption2).foregroundStyle(.tertiary) }
                    Spacer(minLength: 8)
                    if ok > 0 { tagPill("\(stateLabel("有效")) \(ok)", good) }
                    if bad > 0 { tagPill("\(stateLabel("无效")) \(bad)", warn) }
                    if !t.next.isEmpty { Text(tr("下一步 \(t.next.count)", "Next \(t.next.count)")).font(.caption2).foregroundStyle(.secondary) }
                    Text(t.updated).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary).frame(width: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture { if expanded { open.remove(t.id) } else { open.insert(t.id) } }
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        field(tr("大类名", "Name"), t.title, "") { s in
                            edit(tr("把大类「\(t.title)」改名为「\(s)」", "Renamed workstream \"\(t.title)\" to \"\(s)\"")) { $0.track(t.id) { $0.title = s; $0.manual = true } }
                        } onDelete: {
                            edit(tr("删掉大类「\(t.title)」，不再追踪", "Deleted workstream \"\(t.title)\" and stopped tracking it")) { $0.ignore(t.title); $0.tracks.removeAll { $0.id == t.id } }
                        }
                        field(tr("完成标准", "Done when"), t.goal, tr("做到什么算完成", "What counts as done")) { s in
                            edit(tr("把大类「\(t.title)」的完成标准改成：", "Changed what counts as done for workstream \"\(t.title)\" to: ") + s) { $0.track(t.id) { $0.goal = s; $0.manual = true } }
                        }
                        field(tr("现在走到哪", "Where it stands"), t.now, tr("（空）", "(empty)")) { s in
                            edit(tr("把大类「\(t.title)」的进度改成：", "Changed where workstream \"\(t.title)\" stands to: ") + s) { $0.track(t.id) { $0.now = s } }
                        }
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        learnedCol(t).frame(width: colWidth, alignment: .leading)
                        sideCol(t).frame(width: colWidth, alignment: .leading)
                    }
                } else {
                    if !t.goal.isEmpty {
                        Text(tr("完成标准：", "Done when: ") + t.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(t.now.isEmpty ? tr("（还没有进度）", "(no progress yet)") : t.now).font(.callout).lineLimit(3)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardLine))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 展开后的一行可改字段：左边小标签，右边内容
    func field(_ label: String, _ text: String, _ placeholder: String, onSave: @escaping (String) -> Void, onDelete: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: isEnglish ? 100 : 64, alignment: .leading)
            EditableText(text: text, placeholder: placeholder, font: .callout, onSave: onSave, onDelete: onDelete)
        }
    }

    func learnedCol(_ t: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("结论", "Findings"), systemImage: "lightbulb").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            EntryList(entries: t.learned, verdict: true, kind: tr("大类「\(t.title)」的结论", "\"\(t.title)\" finding"), addLabel: tr("追加结论", "Add finding"),
                      set: { xs, n in edit(n) { $0.track(t.id) { $0.learned = xs } } },
                      remove: { e in edit(tr("删掉大类「\(t.title)」的结论：", "Deleted \"\(t.title)\" finding: ") + e.text) { $0.track(t.id) { $0.learned.removeAll { $0.id == e.id } }; $0.ignore(e.text) } },
                      sessionLink: link)
        }
    }

    func sideCol(_ t: Track) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("下一步", "Next steps"), systemImage: "arrow.forward.circle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                EntryList(entries: t.next, tint: .accentColor, kind: tr("大类「\(t.title)」的下一步", "\"\(t.title)\" next step"), addLabel: tr("追加下一步", "Add next step"),
                          set: { xs, n in edit(n) { $0.track(t.id) { $0.next = xs } } },
                          remove: { e in edit(tr("删掉大类「\(t.title)」的下一步：", "Deleted \"\(t.title)\" next step: ") + e.text) { $0.track(t.id) { $0.next.removeAll { $0.id == e.id } }; $0.ignore(e.text) } },
                          sessionLink: link)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("进展", "Progress"), systemImage: "clock").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                EntryList(entries: t.log.reversed(), dated: true, kind: tr("大类「\(t.title)」的进展", "\"\(t.title)\" progress entry"), addLabel: tr("追加进展", "Add progress"),
                          set: { xs, n in edit(n) { $0.track(t.id) { $0.log = xs.reversed() } } },
                          remove: { e in edit(tr("删掉大类「\(t.title)」的进展：", "Deleted \"\(t.title)\" progress entry: ") + e.text) { $0.track(t.id) { $0.log.removeAll { $0.id == e.id } }; $0.ignore(e.text) } },
                          sessionLink: link)
            }
        }
    }

    // MARK: 关联会话、设置

    var sessionsBlock: some View { BoardSessionList(model: model, store: store, p: p) }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            BoardHeader(store: store)
            Text(tr("项目文件：", "Project file: ") + p.fileURL.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(.top, 8)
    }
}


/// 关联会话：单独订阅会话列表，会话状态变时只重画这一块
struct BoardSessionList: View {
    @ObservedObject var model: Model
    let store: BoardStore
    let p: Project
    var body: some View {
        let sessions = p.sessions.compactMap { id in model.sessions.first { $0.id == id } }.sorted { $0.updated > $1.updated }
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(tr("关联会话", "Linked sessions"), "bubble.left.and.bubble.right",
                         note: tr("\(sessions.count) 条 · 右键挪到别的项目或移出看板", "\(sessions.count) · right-click to move to another project or remove from the board"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(sessions) { s in
                    SessionRow(s: s, showProject: false, unread: model.isUnread(s))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(card))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedId = s.id }
                        .contextMenu {
                            Menu(tr("挪到", "Move to")) {
                                ForEach(store.sorted.filter { $0.id != p.id }) { t in Button(t.name) { store.move(s.id, to: t.id) } }
                            }
                            Button(tr("移出看板（零散会话）", "Remove from board (loose session)")) { store.move(s.id, to: nil) }
                        }
                }
            }
        }
    }
}
