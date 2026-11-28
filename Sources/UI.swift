import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

/// 全应用统一用系统时区（appZone，见 Zone.swift），不受环境变量 TZ 影响；每次现取，系统时区变了才跟得上
private var appCal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = appZone; return c }

private func dayLabel(_ d: Date) -> String {
    let cal = appCal
    if cal.isDateInToday(d) { return "今天" }
    if cal.isDateInYesterday(d) { return "昨天" }
    if Date().timeIntervalSince(d) < 7 * 24 * 3600 { return "最近 7 天" }
    return "更早"
}

/// dayLabel 的取值是分组的 key，这里只换显示文字
private func dayTitle(_ day: String) -> String {
    ["今天": tr("今天", "Today"), "昨天": tr("昨天", "Yesterday"), "最近 7 天": tr("最近 7 天", "Previous 7 days"), "更早": tr("更早", "Older")][day] ?? day
}

/// 时区由调用方传进来：系统时区变了，父视图会带着新的时区重新生成这一行
private func timeLabel(_ d: Date, zone: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = zone
    if isEnglish { f.locale = Locale(identifier: "en_US_POSIX") }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
    f.dateFormat = cal.isDateInToday(d) ? "HH:mm" : tr("M月d日", "MMM d")
    return f.string(from: d)
}

private var iconCache: [String: NSImage] = [:]
func appIcon(_ path: String) -> NSImage {
    if let i = iconCache[path] { return i }
    let i = NSWorkspace.shared.icon(forFile: path)
    iconCache[path] = i
    return i
}

struct SessionRow: View {
    let s: Session
    let showProject: Bool
    var unread = false
    let zone: TimeZone
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: appIcon(s.appPath)).resizable().frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if s.waiting {
                        Text(s.asking ? tr("待回答", "Needs answer") : tr("待批准", "Needs approval")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    } else if unread {
                        Text(tr("未读", "Unread")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(claudeOrange))
                    }
                    Text(s.title).lineLimit(1).fontWeight(unread ? .semibold : .regular)
                }
                Text([s.app, showProject ? s.project : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if s.running {
                ProgressView().controlSize(.mini).padding(.top, 2)
            } else if s.bg > 0 {
                // 主任务空闲、但还有后台任务在跑
                Label("\(s.bg)", systemImage: "gearshape.2").font(.caption2).foregroundStyle(.secondary)
                    .help(tr("\(s.bg) 个后台任务在跑", s.bg == 1 ? "1 background task running" : "\(s.bg) background tasks running"))
            } else {
                Text(timeLabel(s.updated, zone: zone)).font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: 配色（参照 Claude：暖白 / 暖灰，强调色橙）

func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    func c(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) })
}
let sidebarBG = dyn(0xF3F1EA, 0x1F1E1D)
let claudeOrange = dyn(0xD97757, 0xD97757)
let appTint: [String: Color] = ["Claude": claudeOrange, "Claude（原版）": claudeOrange, "Codex": dyn(0x3D3D3A, 0xC2C0B6), "Antigravity": dyn(0x4285F4, 0x8AB4F8)]

struct UsageBar: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(value >= 0.8 ? Color.red.opacity(0.8) : tint).frame(width: max(3, g.size.width * min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

struct UsageView: View {
    @ObservedObject var model: Model
    @AppStorage("usageExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(tr("用量", "Usage")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if let t = model.usageTime {
                    Text(tr("更新于 ", "Updated ") + hhmm(t)).font(.caption2).foregroundStyle(.tertiary)
                }
                if model.usageLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.refreshUsage() } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                        .buttonStyle(.borderless).help(tr("刷新用量", "Refresh usage"))
                }
            }
            if expanded {
                if model.usage.isEmpty && !model.usageLoading {
                    Text(tr("还没读到，点右边刷新", "Nothing yet. Click refresh on the right.")).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(model.usage) { a in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(nsImage: appIcon(a.appPath)).resizable().frame(width: 14, height: 14)
                            Text(a.app).font(.caption.weight(.medium))
                        }
                        ForEach(a.items, id: \.self) { it in
                            if let u = it.used {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(it.label).font(.caption2).foregroundStyle(.secondary)
                                            .frame(width: 92, alignment: .leading).lineLimit(1)
                                        UsageBar(value: u, tint: appTint[a.app] ?? .accentColor)
                                        Text("\(Int((u * 100).rounded()))%").font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                                    }
                                    if !it.note.isEmpty {
                                        Text(it.note).font(.system(size: 9.5)).foregroundStyle(.tertiary).padding(.leading, 100)
                                    }
                                }
                            } else {
                                HStack {
                                    Text(it.label).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(it.note).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

func hhmm(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = appZone
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

struct RootView: View {
    @ObservedObject var model: Model
    @ObservedObject private var lang = LangStore.shared   // 语言一变整个窗口重画
    @State private var showGuide = !UserDefaults.standard.bool(forKey: onboardedKey) && !headless
    @State private var editingId: String?     // 正在原地改名的会话
    @State private var editText = ""
    @State private var deletingId: String?    // 正在原地确认删除的会话
    @State private var collapsed = Set<String>()
    @State private var expandedOld = Set<String>()
    @FocusState private var editFocus: Bool

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 440)
        } detail: {
            if let b = model.board {
                BoardView(model: model, store: model.boards, pid: b)
            } else if model.selectedId == nil && model.draft == nil {
                WelcomeView(model: model)
            } else {
                WebView(web: model.chat.web).ignoresSafeArea(edges: .top)
            }
        }
        .id(lang.code)
        .navigationTitle("")
        .background(WindowHook())
        .sheet(isPresented: $showGuide) {
            OnboardingView(model: model) {
                UserDefaults.standard.set(true, forKey: onboardedKey)
                showGuide = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGuide)) { _ in showGuide = true }
    }

    // MARK: 一行会话：平时显示标题；改名时原地变输入框（回车保存、Esc 取消、点别处也保存）；删除时原地确认

    @ViewBuilder func row(_ s: Session, showProject: Bool) -> some View {
        if editingId == s.id {
            HStack(spacing: 8) {
                Image(nsImage: appIcon(s.appPath)).resizable().frame(width: 18, height: 18)
                TextField(tr("会话名", "Session name"), text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .focused($editFocus)
                    .onSubmit { commitRename(s) }
                    .onExitCommand { editingId = nil }
                    .onChange(of: editFocus) { focused in if !focused && editingId == s.id { commitRename(s) } }
            }
            .padding(.vertical, 2)
            .onAppear { DispatchQueue.main.async { editFocus = true } }
        } else if deletingId == s.id {
            HStack(spacing: 6) {
                Text(tr("删除「\(s.title)」？删掉找不回来", "Delete “\(s.title)”? This can’t be undone.")).font(.caption).lineLimit(2)
                Spacer(minLength: 4)
                Button(tr("删除", "Delete"), role: .destructive) { deletingId = nil; model.act(s, .delete) }.controlSize(.small)
                Button(tr("取消", "Cancel")) { deletingId = nil }.controlSize(.small)
            }
            .padding(.vertical, 3)
        } else {
            SessionRow(s: s, showProject: showProject, unread: model.isUnread(s), zone: appZone)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.selectedId == s.id ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedId = s.id }
                .contextMenu { sessionMenu(s) }
        }
    }

    func commitRename(_ s: Session) {
        let name = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingId = nil
        guard !name.isEmpty, name != s.title else { return }
        model.act(s, .rename, newName: name)
    }

    // MARK: 侧栏

    var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $model.filter) {
                    ForEach(AppFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Button { model.selectedId = nil; model.draft = nil; model.board = nil } label: { Image(systemName: "house") }
                    .buttonStyle(.borderless).help(tr("首页：环境检查、自检、切换语言", "Home: setup check, self-check, language"))
                Button { model.board = "" } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.borderless).help(tr("项目看板", "Project board"))
                newMenu(folder: nil)
            }
            .padding(.horizontal, 10)
            Picker("", selection: $model.mode) {
                ForEach(ListMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10)

            // 不用列表自带的选中：会话在分组之间移动（变成未读、开始运行）时，自带的选中会把列表滚到它那里
            List {
                if model.mode == .time { timeSections }
                else if model.mode == .folder { folderSections }
                else { ProjectSections(model: model, store: model.boards, row: { AnyView(row($0, showProject: false)) }) }
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { hitSection }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            footer
        }
        .background(sidebarBG)
        .searchable(text: $model.query, placement: .sidebar, prompt: tr("搜索标题和正文", "Search titles and messages"))
    }

    /// 分组互斥：每条会话只出现在一个组。未读（有新输出、你还没看）→ 运行中（在跑或有后台任务）→ 按时间。
    /// 有后台任务（定时巡检、监听等）的会话会反复出新输出，留在“运行中”、未读只打标记，不然会在两组之间来回跳
    @ViewBuilder var timeSections: some View {
        let items = model.visible
        let unread = items.filter { model.isUnread($0) && $0.bg == 0 }
        let busy = items.filter { $0.running || $0.bg > 0 }
        let active = busy.filter { model.isUnread($0) } + busy.filter { !model.isUnread($0) }
        let taken = Set(unread.map(\.id)).union(active.map(\.id))
        let rest = items.filter { !taken.contains($0.id) }
        if !unread.isEmpty {
            Section {
                ForEach(unread) { row($0, showProject: true) }
            } header: {
                HStack { Text(tr("未读", "Unread")); Text("\(unread.count)").foregroundStyle(.tertiary) }
            }
        }
        if !active.isEmpty {
            Section {
                ForEach(active) { row($0, showProject: true) }
            } header: {
                HStack { Text(tr("运行中", "Running")); Text("\(active.count)").foregroundStyle(.tertiary) }
            }
        }
        ForEach(["今天", "昨天", "最近 7 天", "更早"], id: \.self) { day in
            let rows = rest.filter { dayLabel($0.updated) == day }
            if !rows.isEmpty {
                // “更早”默认折叠；搜索时全部展开
                let key = "time:" + day
                Section(isExpanded: Binding(get: { !model.query.isEmpty || (day == "更早" ? expandedOld.contains(key) : !collapsed.contains(key)) },
                                            set: { open in
                                                if day == "更早" { if open { expandedOld.insert(key) } else { expandedOld.remove(key) } }
                                                else { if open { collapsed.remove(key) } else { collapsed.insert(key) } }
                                            })) {
                    ForEach(rows) { row($0, showProject: true) }
                } header: {
                    HStack { Text(dayTitle(day)); Text("\(rows.count)").foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// 目录树：每个工作目录一组，可折叠；组头的 ＋ 在这个目录里新建会话
    @ViewBuilder var folderSections: some View {
        ForEach(model.folders, id: \.path) { f in
            Section(isExpanded: Binding(get: { !collapsed.contains(f.path) },
                                        set: { if $0 { collapsed.remove(f.path) } else { collapsed.insert(f.path) } })) {
                ForEach(f.sessions.filter { model.isUnread($0) } + f.sessions.filter { !model.isUnread($0) }) { row($0, showProject: false) }
            } header: {
                HStack {
                    Image(systemName: "folder")
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    Text("\(f.sessions.count)").foregroundStyle(.tertiary)
                    Spacer()
                    newMenu(folder: f.path)
                }
                .help(f.path)
            }
        }
    }

    /// 正文匹配：会话名 + 命中那句话，关键词加粗；点一下打开会话并滚到那条消息
    @ViewBuilder var hitSection: some View {
        Section {
            if model.searching && model.hits.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(tr("正在搜索正文…", "Searching messages…")).font(.caption).foregroundStyle(.secondary) }
            } else if model.hits.isEmpty {
                Text(model.query.count < 2 ? tr("至少输入两个字搜索正文", "Type at least 2 characters to search messages") : tr("正文里没有找到", "No matches in messages")).font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(model.hits) { h in
                if let s = model.sessions.first(where: { $0.id == h.sessionId }) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(nsImage: appIcon(s.appPath)).resizable().frame(width: 14, height: 14)
                            Text(s.title).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(h.role == "user" ? tr("你", "You") : tr("回复", "Reply")).font(.caption2).foregroundStyle(.tertiary)
                        }
                        (Text(h.before) + Text(h.match).bold().foregroundColor(claudeOrange) + Text(h.after))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { model.openHit(h) }
                }
            }
        } header: {
            HStack { Text(tr("正文匹配", "Message matches")); if !model.hits.isEmpty { Text("\(model.hits.count)").foregroundStyle(.tertiary) } }
        }
    }

    /// ＋ 菜单：选应用新建会话。folder 为空时用最近一次活动的目录
    func newMenu(folder: String?) -> some View {
        Menu {
            ForEach(newSessionApps, id: \.app) { a in
                Button(tr("新建 \(a.app) 会话", "New \(a.app) session")) {
                    let dir = folder ?? model.sessions.first { $0.kind == a.kind && !$0.cwd.isEmpty }?.cwd ?? NSHomeDirectory()
                    model.draft = Draft(kind: a.kind, app: a.app, appPath: a.path, folder: dir)
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(folder.map { tr("在 \(($0 as NSString).lastPathComponent) 里新建会话", "New session in \(($0 as NSString).lastPathComponent)") } ?? tr("新建会话", "New session"))
    }

    @ViewBuilder func sessionMenu(_ s: Session) -> some View {
        Button(s.link != nil ? tr("在 \(s.app) 中打开", "Open in \(s.app)") : tr("切到 \(s.app)", "Switch to \(s.app)")) { model.openInApp(s) }
        Divider()
        Button(tr("重命名", "Rename")) { deletingId = nil; editText = s.title; editingId = s.id }
        Button(tr("分叉", "Fork")) { model.act(s, .fork) }
        Button(tr("置顶 / 取消置顶", "Pin / unpin")) { model.act(s, .pin) }
        Menu(tr("归到项目", "Move to project")) {
            let cur = model.boards.project(of: s.id)?.id
            ForEach(model.boards.sorted) { p in
                Button((p.id == cur ? "✓ " : "") + p.name) { model.boards.move(s.id, to: p.id) }
            }
            Divider()
            Button(tr("新项目…", "New project…")) { if let n = askName(tr("新项目名", "New project name"), s.title) { model.boards.newProject(n, with: s.id) } }
            Button(tr("不进看板（零散会话）", "Keep off the board (loose sessions)")) { model.boards.move(s.id, to: nil) }
        }
        Button(tr("归档", "Archive")) { model.act(s, .archive) }
        Divider()
        Button(tr("删除…", "Delete…"), role: .destructive) { editingId = nil; deletingId = s.id }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = model.toast {
                Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.trusted {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("给 Codex / Claude 发消息需要“辅助功能”权限", "Sending messages to Codex / Claude requires Accessibility permission")).font(.caption)
                    Button(tr("打开系统设置", "Open System Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }
            UsageView(model: model)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}


// MARK: 首页：环境检查。装了哪些 agent、开没开、找到多少会话，权限有没有给

struct CheckRow: View {
    let ok: Bool
    var icon: NSImage?
    let title: String
    let detail: String
    var actionLabel: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 18)).foregroundStyle(ok ? Color.green : Color.orange).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionLabel { Button(actionLabel, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

struct AgentCheck: View {
    let a: AgentStatus
    var body: some View {
        let detail: String
        if !a.installed {
            detail = tr("没有安装", "Not installed")
        } else {
            detail = tr("找到 \(a.sessions) 条会话 · ", "\(a.sessions) session\(a.sessions == 1 ? "" : "s") found · ") + (a.running ? tr("正在运行", "Running") : tr("没开（用到时会自动在后台启动）", "Not running (starts in the background when needed)"))
        }
        let canStart = a.installed && !a.running
        return CheckRow(ok: a.installed, icon: a.installed ? appIcon(a.path) : nil, title: a.app, detail: detail,
                        actionLabel: canStart ? tr("现在启动", "Start now") : nil,
                        action: { let p = a.path; Task { _ = try? await ensureRunning(p) } })
    }
}

/// 界面语言切换：两个选项始终用各自的语言显示；切换后应用自动重启
struct LanguageSwitcher: View {
    @ObservedObject private var store = LangStore.shared
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Picker("", selection: Binding(get: { store.code }, set: { switchLanguage(to: $0) })) {
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convoy").font(.title2.weight(.semibold))
                    Text(tr("在一个窗口里查看和回复 Claude、Codex、Antigravity 的会话", "View and reply to Claude, Codex, and Antigravity sessions in one window")).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LanguageSwitcher()
            }
            VStack(alignment: .leading, spacing: 0) {
                CheckRow(ok: model.trusted, title: tr("辅助功能权限", "Accessibility permission"),
                         detail: model.trusted ? tr("已开启：可以在后台替你发消息、切模型、管理会话", "On: Convoy can send messages, switch models, and manage sessions for you in the background")
                                               : tr("看会话不需要；发消息、切模型、管理会话需要", "Not needed to view sessions; needed to send messages, switch models, and manage sessions"),
                         actionLabel: model.trusted ? nil : tr("去开启", "Turn on"), action: openAccessibilitySettings)
                ForEach(model.agents) { a in
                    Divider().padding(.leading, 48)
                    AgentCheck(a: a)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            // 自检结果：每个应用的关键操作还能不能用
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("自检", "Self-check")).font(.body.weight(.medium))
                    if let t = model.checkTime { Text(tr("上次 ", "Last run ") + hhmm(t)).font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                    if model.checking { ProgressView().controlSize(.small) } else {
                        Button(tr("重新自检", "Run again")) { model.runSelfCheck() }.controlSize(.small)
                    }
                }
                if model.checks.isEmpty && !model.checking {
                    Text(tr("启动 10 秒后自动检查；原应用升级后也会自动再查。只读，不发送、不改设置。", "Runs 10 seconds after launch and again whenever an original app updates. Read-only: it doesn’t send anything or change settings.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.checks) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Text(c.app + (c.version.isEmpty ? "" : " " + c.version)).font(.caption.weight(.medium)).frame(width: 170, alignment: .leading)
                        FlowChecks(items: c.items)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            HStack {
                Text(tr("会话记录直接从本机读取，不用先打开这些应用。在左边选一个会话开始，或点 ＋ 新建。", "Sessions are read straight from this Mac, so these apps don’t need to be open. Pick a session on the left, or click ＋ to start one."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(tr("使用引导", "Guide")) { NotificationCenter.default.post(name: .showGuide, object: nil) }.controlSize(.small)
            }
        }
        .frame(maxWidth: 560)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: 点关闭（红点或 ⌘W）：像 Claude 一样只把窗口收起来，Convoy 留在后台继续同步；
// 点程序坞图标就把窗口再打开。真正退出用 ⌘Q

/// 包一层窗口代理：只接管“要不要关”，其余消息原样转给 SwiftUI 自己的代理
final class CloseToMinimize: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var window: NSWindow?

    func windowShouldClose(_ w: NSWindow) -> Bool {
        // 不销毁窗口，只是藏起来：里面的会话、输入框内容都留着，再打开时原样恢复
        w.orderOut(nil)
        return false
    }

    /// 点程序坞图标时把窗口再拿出来
    func reopen() {
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func responds(to sel: Selector!) -> Bool {
        super.responds(to: sel) || (original?.responds(to: sel) ?? false)
    }

    override func forwardingTarget(for sel: Selector!) -> Any? {
        original?.responds(to: sel) == true ? original : nil
    }
}

let closeProxy = CloseToMinimize()

struct WindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, !(w.delegate is CloseToMinimize) else { return }
            closeProxy.original = w.delegate
            closeProxy.window = w
            w.delegate = closeProxy
        }
    }
}


struct FlowChecks: View {
    let items: [CheckItem]
    var body: some View {
        // 一行放不下就换行
        let rows = stride(from: 0, to: items.count, by: 4).map { Array(items[$0..<min($0 + 4, items.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r], id: \.self) { it in
                        Label(it.name, systemImage: it.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(it.ok ? Color.green : Color.red)
                    }
                }
            }
        }
    }
}


// MARK: 侧栏“按项目”：每个项目一组，组头点一下打开看板

struct ProjectSections: View {
    @ObservedObject var model: Model
    @ObservedObject var store: BoardStore
    let row: (Session) -> AnyView
    @State private var collapsed = Set<String>(["零散"])

    var body: some View {
        let items = model.visible
        ForEach(store.sorted) { p in
            let rows = items.filter { p.sessions.contains($0.id) }
            if !rows.isEmpty || model.query.isEmpty {
                section(p.id, rows) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text(p.name).lineLimit(1)
                        Text("\(rows.count)").foregroundStyle(.tertiary)
                        if !p.decisions.isEmpty { Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6).help(tr("有 \(p.decisions.count) 件事等你定", p.decisions.count == 1 ? "1 item needs your decision" : "\(p.decisions.count) items need your decision")) }
                        Spacer()
                        Button(tr("看板", "Board")) { model.board = p.id }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
        let rest = items.filter { s in store.project(of: s.id) == nil }
        let loose = rest.filter { store.isLoose($0.id) }
        let todo = rest.filter { !store.isLoose($0.id) }
        if !todo.isEmpty { section("未归类", todo) { HStack { Text(tr("未归类", "Unsorted")); Text("\(todo.count)").foregroundStyle(.tertiary) } } }
        if !loose.isEmpty { section("零散", loose) { HStack { Text(tr("零散会话", "Loose sessions")); Text("\(loose.count)").foregroundStyle(.tertiary) } } }
    }

    @ViewBuilder func section<H: View>(_ key: String, _ rows: [Session], @ViewBuilder header: () -> H) -> some View {
        Section(isExpanded: Binding(get: { !model.query.isEmpty || !collapsed.contains(key) },
                                    set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })) {
            ForEach(rows.filter { model.isUnread($0) } + rows.filter { !model.isUnread($0) }) { row($0) }
        } header: { header() }
    }
}

/// 弹一个输入框要名字
func askName(_ title: String, _ initial: String) -> String? {
    let a = NSAlert()
    a.messageText = title
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    f.stringValue = initial
    a.accessoryView = f
    a.addButton(withTitle: tr("好", "OK"))
    a.addButton(withTitle: tr("取消", "Cancel"))
    a.window.initialFirstResponder = f
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let n = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? nil : n
}


extension Notification.Name { static let showGuide = Notification.Name("agentdock.showGuide") }
