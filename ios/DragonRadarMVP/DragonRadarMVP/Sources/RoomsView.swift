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
                            Text(hasActiveRoom ? "邀请码 \(appState.inviteCode) · \(appState.onlineMembers)/\(appState.roomCapacity)" : "创建或加入房间后，雷达会进入对应房间。")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MangaTheme.subtle)
                                .accessibilityIdentifier("rooms.current.summary")
                        }
                        Spacer()
                        StatusChip(text: hasActiveRoom ? "活跃" : "未进入", filled: hasActiveRoom)
                    }

                    HStack(spacing: 10) {
                        Button(copiedInvite ? "已复制" : "复制邀请码") {
                            UIPasteboard.general.string = appState.inviteCode
                            copiedInvite = true
                        }
                        .buttonStyle(InkButtonStyle())
                        .disabled(!hasActiveRoom)
                        Button("加入房间") {
                            state.showJoinRoomSheet = true
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .disabled(!appState.isSignedIn)
                        .accessibilityIdentifier("rooms.join.open")
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
                } else {
                    EmptyRoomPromptRow()
                }
                }

                MangaPanel("房间列表") {
                    if appState.rooms.isEmpty {
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
                    .disabled(!appState.isSignedIn)
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
        !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                Text("查看房间状态、成员槽位和语音概况。")
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

                    InfoRow(label: "邀请码", value: appState.inviteCode)
                }

                MangaPanel("房间状态") {
                    InfoRow(label: "容量", value: "\(appState.members.count)/\(appState.roomCapacity)")
                    InfoRow(label: "连接", value: radarRuntime.relayPhase.rawValue)
                    InfoRow(label: "房间码", value: appState.inviteCode)
                    InfoRow(label: "语音", value: "\(appState.voiceQuality) · \(radarRuntime.voicePhase.rawValue)")
                    InfoRow(label: "在线成员", value: "\(appState.onlineMembers)")
                }

                MangaPanel("成员槽位") {
                    Text("成员列表由房间自动同步。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)

                    LazyVStack(spacing: 0) {
                        ForEach(0..<appState.roomCapacity, id: \.self) { index in
                            if index < appState.members.count {
                                RoomSlotRow(index: index + 1, member: appState.members[index])
                            } else {
                                EmptyRoomSlotRow(index: index + 1)
                            }
                        }
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
        .onChange(of: draftRoomName) { _, newValue in
            let cleanName = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanName != appState.activeRoomName {
                saveSucceeded = false
            }
        }
    }

    private var canSaveRoomName: Bool {
        let cleanName = draftRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty && cleanName != appState.activeRoomName
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
}

struct RoomSlotRow: View {
    var index: Int
    var member: RoomMember

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
                Text(member.voiceCountdownText.isEmpty ? member.voiceStatusText : "\(member.voiceStatusText) · \(member.voiceCountdownText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()

            if member.isSpeaking {
                Image(systemName: "waveform")
                    .font(.caption.weight(.black))
            }
            StatusChip(text: member.isOnline ? "在线" : "离线", filled: member.isOnline)
        }
        .padding(.vertical, 6)
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
                    LabeledContent("成员", value: "保留本机")
                    LabeledContent("语音", value: "等待成员加入")
                    LabeledContent("定位", value: "继续使用 iPhone 桥接")
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
