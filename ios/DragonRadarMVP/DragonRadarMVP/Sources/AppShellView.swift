import AuthenticationServices
import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationPermissionCenter.self) private var notificationCenter
    @State private var routingReminderID = ""

    var body: some View {
        Group {
            if appState.isSignedIn {
                signedInShell
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LoginGateView()
                    .transition(.opacity)
            }
        }
        .tint(MangaTheme.ink)
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.22), value: appState.isSignedIn)
        .overlay(alignment: .top) {
            if appState.isSignedIn, let reminder = notificationCenter.latestRadarReminder {
                RadarReminderBanner(
                    reminder: reminder,
                    openAction: { openRadar(reminder) },
                    dismissAction: { notificationCenter.dismissRadarReminder(eventID: reminder.eventID) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: notificationCenter.latestRadarReminder?.eventID)
        .onAppear {
            routeNotificationIfNeeded()
        }
        .onChange(of: notificationCenter.radarNavigationRequestID) { _, _ in
            routeNotificationIfNeeded()
        }
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                routeNotificationIfNeeded()
            }
        }
        .onChange(of: appState.sessionRestorationCompleted) { _, completed in
            if completed {
                routeNotificationIfNeeded()
            }
        }
    }

    private var signedInShell: some View {
        @Bindable var state = appState
        return TabView(selection: $state.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    tabContent(tab)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .accessibilityIdentifier("app.shell.tabs")
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .radar:
            RadarOverviewView()
        case .rooms:
            RoomsView()
        #if !APP_ONLY
        case .devices:
            DevicesView()
        #endif
        case .account:
            AccountView()
        }
    }

    private func openRadar(_ reminder: RadarReminderEvent) {
        guard routingReminderID != reminder.eventID else { return }
        routingReminderID = reminder.eventID
        Task {
            let result = await appState.openRadarReminder(roomCode: reminder.roomCode)
            if result != .retryable {
                notificationCenter.consumeRadarNavigationRequest(eventID: reminder.eventID)
                notificationCenter.dismissRadarReminder(eventID: reminder.eventID)
            }
            routingReminderID = ""
        }
    }

    private func routeNotificationIfNeeded() {
        guard
            appState.isSignedIn,
            appState.sessionRestorationCompleted,
            let reminder = notificationCenter.latestRadarReminder,
            notificationCenter.radarNavigationRequestID == reminder.eventID
        else { return }
        openRadar(reminder)
    }
}

private struct RadarReminderBanner: View {
    var reminder: RadarReminderEvent
    var openAction: () -> Void
    var dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.title3.weight(.black))
                .frame(width: 38, height: 38)
                .background(MangaTheme.ink, in: Circle())
                .foregroundStyle(MangaTheme.paper)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.message)
                    .font(.headline.weight(.black))
                if !reminder.roomCode.isEmpty {
                    Text("房间 \(reminder.roomCode)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
            }

            Spacer(minLength: 8)

            Button("查看雷达", action: openAction)
                .font(.caption.weight(.black))
                .buttonStyle(.borderedProminent)
                .tint(MangaTheme.ink)
                .accessibilityIdentifier("radar.reminder.open")

            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提醒")
        }
        .padding(12)
        .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MangaTheme.ink, lineWidth: 2))
        .shadow(color: .black.opacity(0.18), radius: 0, x: 3, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("radar.reminder.banner")
    }
}

private struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var authPhase: AppOperationPhase = .idle
    @State private var appleSignInNonce = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 104)

            VStack(spacing: 60) {
                LoginMangaTitle()

                Image("LoginMangaPanel")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MangaTheme.ink, lineWidth: 2.4))
                    .shadow(color: .black.opacity(0.12), radius: 0, x: 2, y: 2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)

            Spacer()
                .frame(height: 72)

            MangaPanel {
                VStack(alignment: .leading, spacing: 12) {
                    if case .idle = authPhase {
                        EmptyView()
                    } else {
                        OperationStatusView(phase: authPhase)
                            .accessibilityIdentifier("login.gate.operation.status")
                    }

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
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MangaTheme.ink, lineWidth: 1.8))
                    .disabled(authPhase.isLoading)
                    .opacity(authPhase.isLoading ? 0.55 : 1)
                    .accessibilityIdentifier("login.gate.apple.signin")

                    LegalSupportLinksView(includeSupport: false)

                    #if DEBUG
                    Button {
                        Task { await signInForDevelopment() }
                    } label: {
                        Label(authPhase.isLoading ? "登录中" : "开发登录", systemImage: "hammer")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    .disabled(authPhase.isLoading)
                    .accessibilityIdentifier("login.gate.development.signin")
                    #endif
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)

            Spacer(minLength: 0)
        }
        .background(MangaBackground())
        .accessibilityIdentifier("login.gate.screen")
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
}

struct LegalSupportLinksView: View {
    var includeSupport: Bool
    private let environment = AppEnvironment.current

    var body: some View {
        Group {
            if hasAnyLink {
                HStack(spacing: 14) {
                    if let url = environment.privacyPolicyURL {
                        Link("隐私政策", destination: url)
                            .accessibilityIdentifier("legal.privacy")
                    }
                    if let url = environment.termsOfServiceURL {
                        Link("服务条款", destination: url)
                            .accessibilityIdentifier("legal.terms")
                    }
                    if includeSupport, let url = environment.supportURL {
                        Link("联系支持", destination: url)
                            .accessibilityIdentifier("legal.support")
                    }
                }
            } else {
                Text("政策与支持链接待配置")
                    .foregroundStyle(MangaTheme.warning)
                    .accessibilityIdentifier("legal.links.missing")
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(MangaTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var hasAnyLink: Bool {
        environment.privacyPolicyURL != nil
            || environment.termsOfServiceURL != nil
            || (includeSupport && environment.supportURL != nil)
    }
}

private struct LoginMangaTitle: View {
    private let title = "CAPSULE"
    private let titleFont = Font.custom("Futura-CondensedExtraBold", size: 62, relativeTo: .largeTitle)

    var body: some View {
        ZStack {
            titleLayer
                .foregroundStyle(MangaTheme.ink.opacity(0.20))
                .offset(x: 3, y: 3)

            ForEach(titleOffsets, id: \.self) { offset in
                titleLayer
                    .foregroundStyle(MangaTheme.ink)
                    .offset(x: offset.width, y: offset.height)
            }

            titleLayer
                .foregroundStyle(MangaTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("login.gate.title")
    }

    private var titleLayer: some View {
        Text(title)
            .font(titleFont)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
            .scaleEffect(x: 0.92, y: 1.16, anchor: .center)
    }

    private var titleOffsets: [CGSize] {
        [
            CGSize(width: -1.1, height: 0),
            CGSize(width: 1.1, height: 0),
            CGSize(width: 0, height: -1.1),
            CGSize(width: 0, height: 1.1)
        ]
    }
}
