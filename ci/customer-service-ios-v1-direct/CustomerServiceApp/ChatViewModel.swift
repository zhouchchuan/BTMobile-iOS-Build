import Foundation
import Combine
import UserNotifications
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    static let productionServer = "https://service.linkyou.win:9443"

    @Published var server = UserDefaults.standard.string(forKey: "server") ?? productionServer
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? "xiaomei"
    @Published var password = ""
    @Published var authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
    @Published var me: APIUser?
    @Published var chats: [ChatSession] = []
    @Published var selected: ChatSession?
    @Published var messages: [ChatMessage] = []
    @Published var errorText = ""
    @Published var connected = false
    @Published var isBusy = false

    private var socket: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .apnsToken)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in Task { await self?.registerDevice(token) } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openChat)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in Task { await self?.open(token: token) } }
            .store(in: &cancellables)
    }

    var loggedIn: Bool { !authToken.isEmpty }

    func login() async {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            errorText = "请输入客服账号和密码"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            server = Self.productionServer
            let body = LoginBody(username: username, password: password)
            let data: LoginResponse = try await APIClient.shared.request(
                "/api/auth/login", baseURL: server, method: "POST", body: body
            )
            guard data.user.role == "agent" || data.user.role == "admin" else {
                throw NSError(domain: "CustomerService", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "该账号没有客服权限"])
            }
            authToken = data.token
            me = data.user
            password = ""
            errorText = ""
            UserDefaults.standard.set(server, forKey: "server")
            UserDefaults.standard.set(username, forKey: "username")
            UserDefaults.standard.set(authToken, forKey: "authToken")
            await refreshChats()
            connectSocket()
            requestPushPermission()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func logout() {
        reconnectWorkItem?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        authToken = ""
        me = nil
        chats = []
        selected = nil
        messages = []
        UserDefaults.standard.removeObject(forKey: "authToken")
    }

    func restore() async {
        guard loggedIn else { return }
        server = Self.productionServer
        do {
            let user: APIUser = try await APIClient.shared.request(
                "/api/auth/me", baseURL: server, token: authToken
            )
            me = user
            await refreshChats()
            connectSocket()
            requestPushPermission()
        } catch {
            logout()
        }
    }

    func refreshChats() async {
        guard loggedIn else { return }
        do {
            let rows: [ChatSession] = try await APIClient.shared.request(
                "/api/staff/chats", baseURL: server, token: authToken
            )
            chats = rows
            if let current = selected,
               let newer = rows.first(where: { $0.token == current.token }) {
                selected = newer
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func open(token: String) async {
        if let session = chats.first(where: { $0.token == token }) {
            await open(session)
            return
        }
        await refreshChats()
        if let session = chats.first(where: { $0.token == token }) {
            await open(session)
        }
    }

    func open(_ session: ChatSession) async {
        selected = session
        do {
            let data: ChatMessagesResponse = try await APIClient.shared.request(
                "/api/staff/chats/\(session.token)/messages", baseURL: server, token: authToken
            )
            selected = data.session
            messages = data.messages
            await refreshChats()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = selected, !value.isEmpty else { return }
        do {
            let _: ChatMessage = try await APIClient.shared.request(
                "/api/staff/chats/\(session.token)/messages",
                baseURL: server,
                token: authToken,
                method: "POST",
                body: SendMessageBody(content: value, kind: "text")
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    func uploadImage(_ data: Data) async {
        guard let session = selected else { return }
        do {
            _ = try await APIClient.shared.uploadImage(
                "/api/staff/chats/\(session.token)/upload",
                baseURL: server,
                token: authToken,
                data: data
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    func registerDevice(_ deviceToken: String) async {
        guard loggedIn else { return }
        do {
            let _: OKResponse = try await APIClient.shared.request(
                "/api/staff/device-token",
                baseURL: server,
                token: authToken,
                method: "POST",
                body: DeviceTokenBody(token: deviceToken, environment: "production")
            )
        } catch {
            print("Device token registration failed: \(error)")
        }
    }

    func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    private func connectSocket() {
        reconnectWorkItem?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)

        guard let url = URL(string: server),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = url.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/staff"
        components.queryItems = [URLQueryItem(name: "token", value: authToken)]
        guard let socketURL = components.url else { return }

        let task = URLSession.shared.webSocketTask(with: socketURL)
        socket = task
        task.resume()
        connected = true
        receiveLoop(task)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    var text = ""
                    if case .string(let value) = message { text = value }
                    if let data = text.data(using: .utf8),
                       let event = try? JSONDecoder().decode(SocketEvent.self, from: data),
                       event.type == "message" {
                        await self.refreshChats()
                        if event.session?.token == self.selected?.token,
                           let incoming = event.message,
                           !self.messages.contains(where: { $0.id == incoming.id }) {
                            self.messages.append(incoming)
                        }
                    }
                    self.receiveLoop(task)
                case .failure:
                    self.connected = false
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.loggedIn else { return }
                        self.connectSocket()
                    }
                    self.reconnectWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                }
            }
        }
    }
}

private struct LoginBody: Codable { let username: String; let password: String }
private struct OKResponse: Codable { let ok: Bool }
private struct SocketEvent: Codable { let type: String; let message: ChatMessage?; let session: ChatSession? }
