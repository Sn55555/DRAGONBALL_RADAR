import AuthenticationServices
import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState

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
        case .devices:
            DevicesView()
        case .account:
            AccountView()
        }
    }
}

private struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var authPhase: AppOperationPhase = .idle

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
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authPhase = .failed("Apple 登录凭证无效。请重试。")
                return
            }
            Task { await signInWithApple(credential: credential) }
        case .failure(let error):
            authPhase = .failed("Apple 登录取消或失败 · \(AppError.userFacingMessage(for: error))")
        }
    }

    @MainActor
    private func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        authPhase = .loading
        let result = await appState.signInWithAppleAndWait(credential: credential)
        authPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }

    @MainActor
    private func signInForDevelopment() async {
        authPhase = .loading
        let result = await appState.signInForDevelopmentAndWait()
        authPhase = result.succeeded ? .success(result.message) : .failed(result.message)
    }
}

private struct LoginMangaTitle: View {
    private let title = "DragonBall Radar"
    private let titleFont = Font.custom("Futura-CondensedExtraBold", size: 56, relativeTo: .largeTitle)

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
        .padding(.horizontal, 2)
        .scaleEffect(x: 0.94, y: 1.34, anchor: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("login.gate.title")
    }

    private var titleLayer: some View {
        Text(title)
            .font(titleFont)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
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
