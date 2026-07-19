import SwiftUI
import UIKit

struct RoomsView: View {
    @Environment(AppState.self) private var appState
    @State private var copiedInvite = false

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                MangaPanel("当前房间") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(hasActiveRoom ? appState.activeRoomName : "尚未进入房间")
                                .font(.title.weight(.black))
                                .accessibilityIdentifier("rooms.current.name")
                            Text(currentRoomSummary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MangaTheme.subtle)
                                .accessibilityIdentifier("rooms.current.summary")
                        }
                        Spacer()
                        StatusChip(
                            text: appState.isReviewExperienceActive ? "本地演示" : (hasActiveRoom ? "活跃" : "未进入"),
                            filled: hasActiveRoom
                        )
                    }

                    HStack(spacing: 10) {
                        if appState.isReviewExperienceActive {
                            Button("退出演示并恢复房间") {
                                appState.stopReviewExperience()
                            }
                            .buttonStyle(InkButtonStyle())
                            .accessibilityIdentifier("rooms.reviewExperience.stop")
                        } else {
                            Button(copiedInvite ? "已复制" : "复制邀请码") {
                                UIPasteboard.general.string = appState.inviteCode
                                copiedInvite = true
                            }
                            .buttonStyle(InkButtonStyle())
                            .disabled(!hasActiveRoom)
                        }
                        Button("加入房间") {
                            state.showJoinRoomSheet = true
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .disabled(!appState.isSignedIn || appState.isReviewExperienceActive)
                        .accessibilityIdentifier("rooms.join.open")
                    }

                    if appState.isReviewExperienceActive {
                        ReviewExperienceSafetyNotice()
                    }

                    if !appState.isSignedIn {
                        Label("请先到“我的”登录账号，再创建或加入房间。", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption.weight(.black))
                            .foregroundStyle(MangaTheme.warning)
                            .accessibilityIdentifier("rooms.signin.required")
                    }

                    if hasActiveRoom {
                        NavigationLink {
                            CurrentRoomDetailView()
                        } label: {
                            CurrentRoomMenuRow()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rooms.current.detail.open")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyRoomPromptRow()
                        ReviewExperienceEntryCard {
                            appState.startReviewExperience()
                        }
                    }
                }
                }

                MangaPanel("房间列表") {
                    if appState.isReviewExperienceActive {
                        Text("本地演示不会加入房间列表；退出后将恢复进入前的服务器房间状态。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                    } else if appState.rooms.isEmpty {
                        Text(appState.isSignedIn ? "服务端暂无房间，先创建或输入邀请码加入。" : "登录后会从服务端同步你的房间列表。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.rooms) { room in
                                RoomSwitchRow(
                                    room: room,
                                    isActive: room.id == appState.activeRoomID
                                ) {
                                    appState.switchRoom(to: room.id)
                                }
                            }
                        }
                    }

                    Divider()
                        .overlay(MangaTheme.ink.opacity(0.35))
                        .padding(.vertical, 4)

                    Button {
                        state.showCreateRoomSheet = true
                    } label: {
                        Label("创建新房间", systemImage: "plus")
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(!appState.isSignedIn || appState.isReviewExperienceActive)
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("房间")
        .accessibilityIdentifier("rooms.screen")
        .onChange(of: appState.inviteCode) { _, _ in
            copiedInvite = false
        }
        .sheet(isPresented: $state.showJoinRoomSheet) {
            JoinRoomSheet()
        }
        .sheet(isPresented: $state.showCreateRoomSheet) {
            CreateRoomSheet()
        }
    }

    private var hasActiveRoom: Bool {
        appState.isReviewExperienceActive
            || !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentRoomSummary: String {
        guard hasActiveRoom else {
            return "创建或加入房间后，雷达会进入对应房间。"
        }
        if appState.isReviewExperienceActive {
            return "本地体验 · \(visibleOnlineMembers)/\(appState.roomCapacity) · 不访问服务器"
        }
        return "邀请码 \(appState.inviteCode) · \(visibleOnlineMembers)/\(appState.roomCapacity)"
    }

    private var visibleOnlineMembers: Int {
        appState.members.filter { ($0.role == "app" || $0.isLocal) && $0.isOnline }.count
    }
}

struct RoomSwitchRow: View {
    var room: RadarRoom
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.black))
                    .foregroundStyle(MangaTheme.ink)
                    .frame(width: 34, height: 34)
                    .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(room.name)
                        .font(.headline.weight(.black))
                    Text("\(room.inviteCode) · \(room.onlineMembers)/\(room.capacity) · \(room.latency)ms")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }

                Spacer()
                StatusChip(text: isActive ? "当前" : "切换", filled: isActive)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .accessibilityIdentifier("rooms.switch.\(room.inviteCode)")
    }
}

struct CurrentRoomMenuRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "door.left.hand.open")
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.6))

            VStack(alignment: .leading, spacing: 3) {
                Text("当前房间详情")
                    .font(.headline.weight(.black))
                Text("查看房间状态、成员位置和在线情况。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.ink)
        }
        .padding(.top, 4)
        .padding(.vertical, 7)
    }
}

struct EmptyRoomPromptRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.message")
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.6))

            VStack(alignment: .leading, spacing: 3) {
                Text("等待房间")
                    .font(.headline.weight(.black))
                Text("创建或加入后，成员槽位和房间状态才会出现。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()
        }
        .padding(.top, 4)
        .padding(.vertical, 7)
        .accessibilityIdentifier("rooms.empty.prompt")
    }
}

struct CurrentRoomDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @State private var draftRoomName = ""
    @State private var saveSucceeded = false
    @State private var reminderPhase: AppOperationPhase = .idle
    @State private var moderationPhase: AppOperationPhase = .idle
    @State private var reportTarget: RoomMember?
    @State private var blockTarget: RoomMember?
    @FocusState private var isRoomNameFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                MangaPanel("当前房间") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("房间名")
                            .font(.caption.weight(.black))
                            .foregroundStyle(MangaTheme.subtle)
                        TextField("输入房间名", text: $draftRoomName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isRoomNameFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                isRoomNameFocused = false
                            }
                            .font(.headline.weight(.black))
                            .padding(12)
                            .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.6))
                            .disabled(appState.isReviewExperienceActive)
                    }

                    Button {
                        saveRoomName()
                    } label: {
                        Label(saveSucceeded ? "已保存" : "保存房间名", systemImage: saveSucceeded ? "checkmark.seal.fill" : "checkmark")
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(!canSaveRoomName)

                    if saveSucceeded {
                        Label("保存成功", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(MangaTheme.ink)
                            .padding(.top, 2)
                    }

                    InfoRow(label: "邀请码", value: appState.displayRoomCode)
                }

                MangaPanel("房间状态") {
                    InfoRow(label: "容量", value: "\(appMembers.count)/\(appState.roomCapacity)")
                    InfoRow(
                        label: "连接",
                        value: appState.isReviewExperienceActive ? "本地演示 · 未连接" : radarRuntime.relayPhase.rawValue
                    )
                    InfoRow(label: "房间码", value: appState.displayRoomCode)
                    InfoRow(label: "在线成员", value: "\(appMembers.filter(\.isOnline).count)")
                }

                MangaPanel("提醒查看雷达") {
                    if appState.isReviewExperienceActive {
                        ReviewExperienceSafetyNotice()
                        Button {
                            // Intentionally inert: review experience never sends notifications.
                        } label: {
                            Label("演示模式不发送提醒", systemImage: "bell.slash.fill")
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .disabled(true)
                        .accessibilityIdentifier("rooms.reminder.send")
                    } else {
                        Text("点击后，房间内其他成员会收到一条“查看雷达”提醒。前台成员会立即在 App 内看到，后台成员通过系统通知接收。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = appState.radarReminderCooldownRemaining(
                                roomCode: appState.inviteCode,
                                at: context.date
                            )
                            Button {
                                Task { await sendRadarReminder() }
                            } label: {
                                Label(
                                    reminderButtonTitle(remaining: remaining),
                                    systemImage: reminderPhase.isLoading ? "hourglass" : "bell.badge.fill"
                                )
                            }
                            .buttonStyle(InkButtonStyle())
                            .disabled(
                                reminderPhase.isLoading
                                    || remaining > 0
                                    || !appState.isSignedIn
                                    || appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            .accessibilityIdentifier("rooms.reminder.send")
                        }
                    }

                    if reminderPhase != .idle {
                        OperationStatusView(phase: reminderPhase)
                            .accessibilityIdentifier("rooms.reminder.status")
                    }
                }

                MangaPanel("成员槽位") {
                    Text(appState.isReviewExperienceActive ? "以下成员均为本地演示数据。" : "成员列表由房间自动同步。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)

                    LazyVStack(spacing: 0) {
                        ForEach(0..<appState.roomCapacity, id: \.self) { index in
                            if index < appMembers.count {
                                let member = appMembers[index]
                                RoomSlotRow(
                                    index: index + 1,
                                    member: member,
                                    reportAction: member.canUseModerationActions ? {
                                        reportTarget = member
                                    } : nil,
                                    blockAction: member.canUseModerationActions ? {
                                        blockTarget = member
                                    } : nil
                                )
                            } else {
                                EmptyRoomSlotRow(index: index + 1)
                            }
                        }
                    }

                    if moderationPhase != .idle {
                        OperationStatusView(phase: moderationPhase)
                            .accessibilityIdentifier("rooms.moderation.status")
                    }
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("当前房间")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("取消") {
                    cancelRoomNameEdit()
                }
                Spacer()
                Button("收起") {
                    isRoomNameFocused = false
                }
            }
        }
        .onAppear {
            draftRoomName = appState.activeRoomName
        }
        .onChange(of: appState.activeRoomName) { _, newValue in
            if draftRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftRoomName = newValue
            }
        }
        .onChange(of: appState.inviteCode) { _, _ in
            reminderPhase = .idle
        }
        .onChange(of: draftRoomName) { _, newValue in
            let cleanName = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanName != appState.activeRoomName {
                saveSucceeded = false
            }
        }
        .sheet(item: $reportTarget) { member in
            MemberReportSheet(member: member)
        }
        .confirmationDialog(
            blockConfirmationTitle,
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        blockTarget = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("屏蔽并继续", role: .destructive) {
                guard let member = blockTarget else { return }
                blockTarget = nil
                Task { await block(member) }
            }
            .accessibilityIdentifier("rooms.moderation.block.confirm")
            Button("取消", role: .cancel) {
                blockTarget = nil
            }
        } message: {
            Text("屏蔽后双方不能加入同一房间。若你不是房主，你将立即退出双方共同房间；若你是房主，对方将被移除。解除屏蔽不会自动恢复成员关系。")
        }
    }

    private var canSaveRoomName: Bool {
        guard !appState.isReviewExperienceActive else { return false }
        let cleanName = draftRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty && cleanName != appState.activeRoomName
    }

    private var appMembers: [RoomMember] {
        appState.members.filter { $0.role == "app" || $0.isLocal }
    }

    private func saveRoomName() {
        let cleanName = draftRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        appState.renameActiveRoom(to: cleanName)
        draftRoomName = cleanName
        saveSucceeded = true
        isRoomNameFocused = false
    }

    private func cancelRoomNameEdit() {
        draftRoomName = appState.activeRoomName
        saveSucceeded = false
        isRoomNameFocused = false
    }

    @MainActor
    private func sendRadarReminder() async {
        guard !appState.isReviewExperienceActive else { return }
        let originRoomCode = appState.inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        reminderPhase = .loading
        let result = await appState.sendRadarReminderAndWait(roomCode: originRoomCode)
        let currentRoomCode = appState.inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard currentRoomCode == originRoomCode else { return }
        if result.succeeded {
            reminderPhase = .success(result.message)
        } else {
            reminderPhase = .failed(result.message)
        }
    }

    private func reminderButtonTitle(remaining: Int) -> String {
        if reminderPhase.isLoading {
            return "正在发送提醒"
        }
        if remaining > 0 {
            return "\(remaining) 秒后可再次提醒"
        }
        return "提醒房间成员查看雷达"
    }

    private var blockConfirmationTitle: String {
        guard let blockTarget else { return "屏蔽成员？" }
        return "屏蔽 \(blockTarget.name)？"
    }

    @MainActor
    private func block(_ member: RoomMember) async {
        moderationPhase = .loading
        let result = await appState.blockMemberAndWait(member)
        moderationPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }
}

struct RoomSlotRow: View {
    var index: Int
    var member: RoomMember
    var reportAction: (() -> Void)? = nil
    var blockAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.black))
                .frame(width: 28, height: 28)
                .background(member.isOnline ? MangaTheme.ink : MangaTheme.panelLight, in: Circle())
                .foregroundStyle(member.isOnline ? MangaTheme.paper : MangaTheme.ink)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 1.6))

            VStack(alignment: .leading, spacing: 3) {
                Text(member.name)
                    .font(.headline.weight(.black))
                    .accessibilityIdentifier("rooms.member.name.\(index)")
                Text(member.locationPaused ? "位置共享已暂停" : "\(member.distance) · \(member.bearing)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()

            StatusChip(text: member.isOnline ? "在线" : "离线", filled: member.isOnline)

            if member.canUseModerationActions,
               let reportAction,
               let blockAction {
                Menu {
                    Button(action: reportAction) {
                        Label("举报成员", systemImage: "exclamationmark.bubble")
                    }
                    Button(role: .destructive, action: blockAction) {
                        Label("屏蔽成员", systemImage: "person.crop.circle.badge.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3.weight(.black))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("\(member.name)的安全操作")
                .accessibilityIdentifier("rooms.member.moderation.\(index)")
            }
        }
        .padding(.vertical, 6)
    }
}

struct MemberReportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var member: RoomMember

    @State private var contentType: ModerationContentType = .behavior
    @State private var category: ModerationReportCategory = .harassment
    @State private var details = ""
    @State private var submitPhase: AppOperationPhase = .idle
    @State private var caseNumber: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("举报对象") {
                    LabeledContent("成员", value: member.name)
                    Text("提交后平台会根据房间记录核查；对方不会收到你的账号标识。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("内容类型") {
                    Picker("内容类型", selection: $contentType) {
                        ForEach(ModerationContentType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("rooms.report.contentType")
                }

                Section("举报类别") {
                    Picker("举报类别", selection: $category) {
                        ForEach(ModerationReportCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("rooms.report.category")
                }

                Section("补充说明（可选）") {
                    TextEditor(text: $details)
                        .frame(minHeight: 132)
                        .accessibilityIdentifier("rooms.report.details")
                    HStack {
                        Text("请勿填写密码、验证码等敏感信息。")
                        Spacer()
                        Text("\(details.count)/1000")
                            .monospacedDigit()
                            .accessibilityIdentifier("rooms.report.details.count")
                    }
                    .font(.caption)
                    .foregroundStyle(details.count == 1_000 ? MangaTheme.warning : MangaTheme.subtle)
                }

                Section("提交状态") {
                    if let caseNumber {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("举报已受理", systemImage: "checkmark.shield.fill")
                                .font(.headline.weight(.black))
                            Text("案件号 \(caseNumber)")
                                .font(.body.monospaced().weight(.black))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("rooms.report.caseNumber")
                            Text("请保存案件号，后续联系支持时可用于查询。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        OperationStatusView(phase: submitPhase)
                            .accessibilityIdentifier("rooms.report.status")
                    }
                }
            }
            .navigationTitle("举报成员")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(MangaBackground())
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: details) { _, newValue in
                if newValue.count > 1_000 {
                    details = String(newValue.prefix(1_000))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(caseNumber == nil ? "取消" : "关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitPhase.isLoading ? "提交中" : "提交举报") {
                        Task { await submit() }
                    }
                    .disabled(submitPhase.isLoading || caseNumber != nil)
                    .accessibilityIdentifier("rooms.report.submit")
                }
            }
        }
        .accessibilityIdentifier("rooms.report.sheet")
    }

    @MainActor
    private func submit() async {
        submitPhase = .loading
        let result = await appState.reportMemberAndWait(
            member,
            contentType: contentType,
            category: category,
            details: details
        )
        if result.succeeded, let resultCaseNumber = result.caseNumber {
            caseNumber = resultCaseNumber
            submitPhase = .success(result.message)
        } else {
            submitPhase = .failed(result.message)
        }
    }
}

struct EmptyRoomSlotRow: View {
    var index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.black))
                .frame(width: 28, height: 28)
                .background(MangaTheme.panelLight, in: Circle())
                .overlay(Circle().stroke(MangaTheme.ink.opacity(0.45), lineWidth: 1.4))

            VStack(alignment: .leading, spacing: 3) {
                Text("空槽位")
                    .font(.headline.weight(.black))
                Text("等待邀请成员加入")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()
            StatusChip(text: "可邀请")
        }
        .padding(.vertical, 6)
        .opacity(0.72)
    }
}

struct JoinRoomSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var submitPhase: AppOperationPhase = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section("邀请码") {
                    TextField("6-8 位邀请码", text: $code)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("rooms.join.code")
                    LabeledContent("成员", value: "加入后等待成员同步")
                }
                Section {
                    Text("第 8 名成员会被拒绝。加入后会自动切换到这个房间。")
                        .foregroundStyle(.secondary)
                }
                Section("状态") {
                    OperationStatusView(phase: submitPhase)
                        .accessibilityIdentifier("rooms.join.status")
                }
            }
            .navigationTitle("加入房间")
            .scrollContentBackground(.hidden)
            .background(MangaBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitPhase.isLoading ? "加入中" : "加入") {
                        Task { await submitJoin() }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitPhase.isLoading)
                    .accessibilityIdentifier("rooms.join.submit")
                }
            }
        }
        .accessibilityIdentifier("rooms.join.sheet")
    }

    @MainActor
    private func submitJoin() async {
        submitPhase = .loading
        let result = await appState.joinRoomAndWait(code: code)
        if result.succeeded {
            submitPhase = .success(result.message)
            try? await Task.sleep(for: .milliseconds(450))
            dismiss()
        } else {
            submitPhase = .failed(result.message)
        }
    }
}

struct CreateRoomSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var submitPhase: AppOperationPhase = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section("房间名") {
                    TextField("输入房间名", text: $roomName)
                    LabeledContent("人数上限", value: "7")
                }
                Section("创建后") {
                    LabeledContent("成员", value: "初始仅自己")
                    LabeledContent("定位", value: "由你主动开启共享")
                }
                Section("状态") {
                    OperationStatusView(phase: submitPhase)
                }
            }
            .navigationTitle("创建房间")
            .scrollContentBackground(.hidden)
            .background(MangaBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitPhase.isLoading ? "创建中" : "创建") {
                        Task { await submitCreate() }
                    }
                    .disabled(roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitPhase.isLoading)
                }
            }
        }
    }

    @MainActor
    private func submitCreate() async {
        submitPhase = .loading
        let result = await appState.createRoomAndWait(named: roomName)
        if result.succeeded {
            submitPhase = .success(result.message)
            try? await Task.sleep(for: .milliseconds(450))
            dismiss()
        } else {
            submitPhase = .failed(result.message)
        }
    }
}

struct OperationStatusView: View {
    var phase: AppOperationPhase

    var body: some View {
        switch phase {
        case .idle:
            Label("等待操作", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在连接服务端")
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
