import AuthenticationServices
import PhotosUI
import SwiftUI
import UIKit

struct AccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(NotificationPermissionCenter.self) private var notificationCenter

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ToyBezel {
                    HStack(spacing: 14) {
                        ProfileAvatarView(
                            displayName: appState.displayName,
                            avatarData: appState.profileAvatarData,
                            size: 58
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.displayName)
                                .font(.title3.weight(.black))
                            Text(appState.isSignedIn ? "Sign in with Apple · 已登录" : "需要登录后使用房间")
                                .font(.caption)
                                .foregroundStyle(MangaTheme.subtle)
                            Text("定位 \(locationBridge.uploadReadinessText)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(MangaTheme.subtle)
                                .accessibilityIdentifier("account.location.header.status")
                        }
                        Spacer()
                        NavigationLink {
                            ProfileEditView()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.headline.weight(.black))
                        }
                        .buttonStyle(InkIconButtonStyle())
                    }
                }
                .overlay(alignment: .topTrailing) {
                    CloudRiderDecoration()
                }

                AuthPanel()
                LocationBridgePanel()

                MangaPanel("隐私与权限") {
                    AccountPermissionRow(
                        title: "iPhone 定位",
                        detail: "\(locationBridge.permissionText) · \(locationBridge.precisionText)",
                        symbol: "location.fill",
                        isReady: locationBridge.isAuthorized && !locationBridge.isReducedAccuracy
                    )
                    AccountPermissionRow(
                        title: "蓝牙配置通道",
                        detail: "\(bleBridge.authorizationText) · \(bleBridge.stateText)",
                        symbol: "dot.radiowaves.left.and.right",
                        isReady: bleBridge.stateText == "可用"
                    )
                    AccountPermissionRow(
                        title: "推送通知",
                        detail: notificationCenter.detailText,
                        symbol: "bell",
                        isReady: notificationCenter.isReady
                    )

                    NavigationLink {
                        PrivacyPermissionsView()
                    } label: {
                        AccountNavigationRow(
                            title: "隐私与权限",
                            detail: "定位、蓝牙、通知和共享状态",
                            symbol: "hand.raised.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }

                MangaPanel("安全与社区") {
                    Text("查看社区规则，管理已屏蔽成员，并在需要时解除屏蔽。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)

                    NavigationLink {
                        SafetyCommunityView()
                    } label: {
                        AccountNavigationRow(
                            title: "安全与社区",
                            detail: "举报说明、屏蔽列表与社区规则",
                            symbol: "checkmark.shield.fill"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account.safety.open")
                }

                MangaPanel("系统状态") {
                    InfoRow(label: "活跃房间", value: appState.activeRoomName)
                    InfoRow(label: "在线成员", value: "\(appState.onlineMembers)/7")
                    InfoRow(label: "定位", value: locationBridge.uploadReadinessText)
                }

            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("我的")
        .accessibilityIdentifier("account.screen")
        .task {
            await notificationCenter.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await notificationCenter.refresh()
            }
        }
    }
}

struct SafetyCommunityView: View {
    @Environment(AppState.self) private var appState
    @State private var loadPhase: AppOperationPhase = .idle
    @State private var unblockTarget: UserBlockRecord?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                MangaPanel("社区规则") {
                    CommunityRuleRow(
                        symbol: "person.2.fill",
                        title: "尊重房间成员",
                        detail: "不得骚扰、威胁、仇恨攻击、冒充他人或传播不当内容。"
                    )
                    CommunityRuleRow(
                        symbol: "hand.raised.fill",
                        title: "保护位置与隐私",
                        detail: "不要擅自公开他人的位置、身份或房间信息。"
                    )
                    CommunityRuleRow(
                        symbol: "exclamationmark.bubble.fill",
                        title: "及时举报",
                        detail: "在房间成员右侧菜单提交举报，并保存 DR 案件号。紧急危险请联系当地紧急服务。"
                    )
                }

                MangaPanel("已屏蔽成员") {
                    Text("屏蔽后双方不能加入同一房间。为保护双方隐私，此处不显示账号标识。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)

                    if loadPhase.isLoading && appState.blockedUsers.isEmpty {
                        ProgressView("正在加载")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if appState.blockedUsers.isEmpty {
                        Label("暂无已屏蔽成员", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline.weight(.black))
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("account.safety.blocks.empty")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.blockedUsers) { block in
                                BlockedMemberRow(block: block) {
                                    unblockTarget = block
                                }
                            }
                        }
                    }

                    if loadPhase != .idle {
                        OperationStatusView(phase: loadPhase)
                            .accessibilityIdentifier("account.safety.status")
                    }
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("安全与社区")
        .accessibilityIdentifier("account.safety.screen")
        .task {
            await refreshBlocks()
        }
        .refreshable {
            await refreshBlocks()
        }
        .confirmationDialog(
            "解除屏蔽？",
            isPresented: Binding(
                get: { unblockTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        unblockTarget = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("解除屏蔽") {
                guard let block = unblockTarget else { return }
                unblockTarget = nil
                Task { await unblock(block) }
            }
            .accessibilityIdentifier("account.safety.unblock.confirm")
            Button("取消", role: .cancel) {
                unblockTarget = nil
            }
        } message: {
            Text("解除后不会自动恢复原房间关系；双方仍需重新加入房间。")
        }
    }

    @MainActor
    private func refreshBlocks() async {
        loadPhase = .loading
        let result = await appState.refreshBlockedUsersFromServer()
        loadPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }

    @MainActor
    private func unblock(_ block: UserBlockRecord) async {
        loadPhase = .loading
        let result = await appState.unblockAndWait(blockID: block.blockID)
        loadPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }
}

private struct CommunityRuleRow: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct BlockedMemberRow: View {
    var block: UserBlockRecord
    var unblockAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.7))

            VStack(alignment: .leading, spacing: 3) {
                Text("已屏蔽成员")
                    .font(.headline.weight(.black))
                    .accessibilityIdentifier("account.safety.block.\(block.blockID)")
                Text("房间 \(block.roomCode) · \(createdDateText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                Text("记录 \(String(block.blockID.suffix(6)))")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()

            Button("解除屏蔽", action: unblockAction)
                .font(.caption.weight(.black))
                .buttonStyle(.bordered)
                .accessibilityIdentifier("account.safety.unblock.\(block.blockID)")
        }
        .padding(.vertical, 7)
    }

    private var createdDateText: String {
        Date(timeIntervalSince1970: TimeInterval(block.createdAt))
            .formatted(date: .abbreviated, time: .omitted)
    }
}

struct ProfileAvatarView: View {
    var displayName: String
    var avatarData: Data?
    var size: CGFloat

    var body: some View {
        Group {
            if let avatarData,
               let image = UIImage(data: avatarData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initialText)
                    .font(.system(size: size * 0.42, weight: .black))
                    .foregroundStyle(MangaTheme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MangaTheme.chip)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
        .shadow(color: MangaTheme.ink.opacity(0.16), radius: 0, x: 3, y: 3)
    }

    private var initialText: String {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleanName.first else { return "我" }
        return String(first)
    }
}

struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var avatarData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var savePhase: AppOperationPhase = .idle

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                MangaPanel("个人资料") {
                    HStack(alignment: .center, spacing: 14) {
                        ProfileAvatarView(displayName: displayName, avatarData: avatarData, size: 78)
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label("更换头像", systemImage: "photo")
                            }
                            .buttonStyle(InkButtonStyle())

                            Button {
                                avatarData = nil
                            } label: {
                                Label("移除头像", systemImage: "xmark.circle")
                            }
                            .buttonStyle(InkButtonStyle(filled: false))
                        }
                    }

                    TextField("用户名", text: $displayName)
                        .font(.title3.weight(.black))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MangaTheme.ink, lineWidth: 1.8))

                    HStack(spacing: 10) {
                        Button {
                            saveProfile()
                        } label: {
                            Label("保存", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(InkButtonStyle())
                        .disabled(!canSave)

                        Button {
                            dismiss()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                    }

                    OperationStatusView(phase: savePhase)
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("编辑资料")
        .onAppear {
            displayName = appState.displayName == "未登录" ? "" : appState.displayName
            avatarData = appState.profileAvatarData
        }
        .onChange(of: selectedPhoto) { _, newValue in
            Task { await loadAvatar(from: newValue) }
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveProfile() {
        guard canSave else {
            savePhase = .failed("请输入用户名")
            return
        }
        appState.updateUserProfile(displayName: displayName, avatarData: avatarData)
        savePhase = .success("已保存")
        dismiss()
    }

    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpegData = image.resizedAvatarJPEGData(maxPixel: 512)
        else {
            savePhase = .failed("头像读取失败")
            return
        }
        avatarData = jpegData
        savePhase = .idle
    }
}

private extension UIImage {
    func resizedAvatarJPEGData(maxPixel: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > 0 ? min(1, maxPixel / longest) : 1
        let nextSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: nextSize)
        let image = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: nextSize))
        }
        return image.jpegData(compressionQuality: 0.82)
    }
}

private struct AuthPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @State private var authPhase: AppOperationPhase = .idle
    @State private var deletePhase: AppOperationPhase = .idle
    @State private var showsDeleteConfirmation = false
    @State private var appleSignInNonce = ""

    var body: some View {
        MangaPanel("账号会话") {
            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: "状态", value: appState.isSignedIn ? "已登录" : "未登录")
                    .accessibilityIdentifier("account.auth.status")
                InfoRow(label: "用户", value: appState.displayName)

                OperationStatusView(phase: visibleAuthPhase)

                if appState.isSignedIn {
                    Button {
                        Task {
                            await radarRuntime.pauseLocationSharing()
                            locationBridge.stopSharing(markUserPaused: true)
                            radarRuntime.disconnectRelay()
                            let result = await appState.signOutAndWait()
                            authPhase = result.succeeded ? .success(result.message) : .failed(result.message)
                        }
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))

                    Divider()

                    Text("删除账户会永久删除你创建的房间、成员关系、推送记录和诊断数据，且无法恢复。")
                        .font(.caption)
                        .foregroundStyle(MangaTheme.subtle)

                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("永久删除账户", systemImage: "trash")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    .disabled(deletePhase.isLoading)
                    .accessibilityIdentifier("account.auth.delete")
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName]
                        do {
                            let nonce = try AppleSignInNonce.make()
                            appleSignInNonce = nonce
                            request.nonce = AppleSignInNonce.sha256(nonce)
                        } catch {
                            appleSignInNonce = ""
                            authPhase = .failed("无法启动安全的 Apple 登录，请重试。")
                        }
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MangaTheme.ink, lineWidth: 1.6))
                    .disabled(authPhase.isLoading)
                    .opacity(authPhase.isLoading ? 0.55 : 1)

                    #if DEBUG
                    Button {
                        Task { await signInForDevelopment() }
                    } label: {
                        Label(authPhase.isLoading ? "登录中" : "开发登录", systemImage: "hammer")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    .disabled(authPhase.isLoading)
                    .accessibilityIdentifier("account.auth.development.signin")
                    #endif
                }
            }
        }
        .accessibilityIdentifier("account.auth.panel")
        .confirmationDialog(
            "永久删除账户？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除账户和全部数据", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销。你拥有的房间也会被删除。")
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        let rawNonce = appleSignInNonce
        appleSignInNonce = ""
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authPhase = .failed("Apple 登录凭证无效。请重试。")
                return
            }
            guard !rawNonce.isEmpty else {
                authPhase = .failed("Apple 登录安全校验失败，请重试。")
                return
            }
            Task { await signInWithApple(credential: credential, rawNonce: rawNonce) }
        case .failure(let error):
            authPhase = .failed("Apple 登录取消或失败 · \(AppError.userFacingMessage(for: error))")
        }
    }

    @MainActor
    private func signInWithApple(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async {
        authPhase = .loading
        let result = await appState.signInWithAppleAndWait(credential: credential, rawNonce: rawNonce)
        authPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }

    @MainActor
    private func signInForDevelopment() async {
        authPhase = .loading
        let result = await appState.signInForDevelopmentAndWait()
        authPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }

    @MainActor
    private func deleteAccount() async {
        deletePhase = .loading
        await radarRuntime.pauseLocationSharing()
        locationBridge.stopSharing(markUserPaused: true)
        radarRuntime.disconnectRelay()
        let result = await appState.deleteAccountAndWait()
        deletePhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }

    private var visibleAuthPhase: AppOperationPhase {
        switch deletePhase {
        case .idle:
            break
        default:
            return deletePhase
        }
        if appState.isSignedIn, case .idle = authPhase {
            return .success("已登录 · \(appState.displayName)")
        }
        return authPhase
    }
}

private struct CloudRiderDecoration: View {
    var body: some View {
        Image("CloudRiderCutout")
            .resizable()
            .scaledToFit()
            .frame(width: 164)
            .offset(x: -12, y: -106)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct AccountPermissionRow: View {
    var title: String
    var detail: String
    var symbol: String
    var isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            StatusChip(text: isReady ? "可用" : "待处理", filled: isReady)
        }
        .padding(.vertical, 4)
    }
}

struct AccountNavigationRow: View {
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.subtle)
                .padding(.top, 7)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PrivacyPermissionsView: View {
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(NotificationPermissionCenter.self) private var notificationCenter
    @Environment(RadarRuntime.self) private var radarRuntime

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                MangaPanel("定位共享") {
                    InfoRow(label: "当前状态", value: locationBridge.sharingText)
                    InfoRow(label: "系统权限", value: locationBridge.permissionText)
                    InfoRow(label: "定位精度", value: locationBridge.precisionText)
                    InfoRow(label: "后台能力", value: locationBridge.backgroundText)
                    InfoRow(label: "最近定位", value: locationBridge.locationAgeText)
                    InfoRow(label: "最近上传", value: radarRuntime.lastLocationSentText)
                    InfoRow(label: "最近确认", value: radarRuntime.lastLocationAckedText)
                    InfoRow(label: "房间确认", value: radarRuntime.lastLocationAckText)
                    InfoRow(label: "共享对象", value: "当前房间成员")
                    InfoRow(label: "关闭方式", value: "我的 > iPhone 定位桥接 > 暂停共享")

                    HStack(spacing: 10) {
                        Button {
                            locationBridge.requestAccess()
                        } label: {
                            Label("授权定位", systemImage: "location.circle")
                        }
                        .buttonStyle(InkButtonStyle(filled: false))

                        Button {
                            if locationBridge.isSharing {
                                locationBridge.pauseSharingByUser()
                                Task {
                                    await radarRuntime.pauseLocationSharing()
                                }
                            } else {
                                locationBridge.startSharing()
                            }
                        } label: {
                            Label(locationBridge.isSharing ? "暂停共享" : "开始共享", systemImage: "location.fill")
                        }
                        .buttonStyle(InkButtonStyle(filled: locationBridge.isSharing))
                    }

                    if locationBridge.authorizationStatus != .authorizedAlways {
                        Text("只有你主动开启后，App 才会申请“始终允许”，用于手机放入口袋或锁屏后继续向当前房间共享位置。")
                            .font(.caption)
                            .foregroundStyle(MangaTheme.subtle)
                        Button {
                            locationBridge.requestBackgroundAccess()
                        } label: {
                            Label("开启口袋/锁屏共享", systemImage: "lock.iphone")
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                    }
                }

                MangaPanel("蓝牙配置") {
                    InfoRow(label: "系统权限", value: bleBridge.authorizationText)
                    InfoRow(label: "通道状态", value: bleBridge.stateText)
                    InfoRow(label: "用途", value: "连接雷达、绑定雷达、写入 Wi-Fi")
                    InfoRow(label: "状态", value: bleBridge.isBLEConnected ? "雷达已连接" : "未连接雷达")
                }

                MangaPanel("推送通知") {
                    InfoRow(label: "授权", value: notificationCenter.statusText)
                    InfoRow(label: "投递", value: notificationCenter.deliveryText)
                    InfoRow(label: "用途", value: "查看雷达提醒和房间邀请")

                    if !notificationCenter.lastError.isEmpty {
                        Text(notificationCenter.lastError)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MangaTheme.warning)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await notificationCenter.requestAuthorization()
                            }
                        } label: {
                            Label("请求通知", systemImage: "bell.badge")
                        }
                        .buttonStyle(InkButtonStyle(filled: !notificationCenter.isReady))

                        Button {
                            notificationCenter.openSystemSettings()
                        } label: {
                            Label("系统设置", systemImage: "gearshape")
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                    }
                }

                MangaPanel("政策与支持") {
                    Text("可在这里查看隐私政策、服务条款和联系支持。账户永久删除入口位于“我的 > 账号会话”。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                    LegalSupportLinksView(includeSupport: true)
                }

            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("隐私与权限")
        .task {
            await notificationCenter.refresh()
        }
    }
}

struct LocationBridgePanel: View {
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime

    var body: some View {
        MangaPanel("iPhone 定位桥接") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(locationBridge.coordinateText)
                            .font(.headline.monospacedDigit().weight(.black))
                        Text("\(locationBridge.accuracyText) · \(locationBridge.lastUpdateText)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                        Text("\(locationBridge.precisionText) · \(locationBridge.backgroundText)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(locationBridge.isReducedAccuracy ? MangaTheme.warning : MangaTheme.subtle)
                    }
                    Spacer()
                    StatusChip(text: locationBridge.uploadReadinessText, filled: locationBridge.isSharing && locationBridge.snapshot != nil)
                        .accessibilityIdentifier("account.location.upload.readiness")
                }
                Text("上传状态 \(locationBridge.uploadReadinessText)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MangaTheme.subtle)
                    .accessibilityIdentifier("account.location.upload.status")

                if let lastError = locationBridge.lastError {
                    Text(lastError)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MangaTheme.warning)
                        .accessibilityIdentifier("account.location.error")
                }

                InfoRow(label: "房间确认", value: radarRuntime.lastLocationAckText)
                InfoRow(label: "上传/确认", value: "\(radarRuntime.lastLocationSentText) / \(radarRuntime.lastLocationAckedText)")

                HStack(spacing: 10) {
                    Button {
                        locationBridge.requestAccess()
                    } label: {
                        Label("授权定位", systemImage: "location.circle")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))

                    Button {
                        if locationBridge.isSharing {
                            locationBridge.pauseSharingByUser()
                            Task {
                                await radarRuntime.pauseLocationSharing()
                            }
                        } else {
                            locationBridge.startSharing()
                        }
                    } label: {
                        Label(locationBridge.isSharing ? "暂停共享" : "开始共享", systemImage: "location.fill")
                    }
                    .buttonStyle(InkButtonStyle(filled: locationBridge.isSharing))
                }

                Text("开启后，iPhone 会持续把当前位置同步到当前房间。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
        }
        .accessibilityIdentifier("account.location.panel")
    }
}
