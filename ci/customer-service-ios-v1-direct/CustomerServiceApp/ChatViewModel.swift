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
    private var pingWorkItem: DispatchWorkItem?
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

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.loggedIn else { return }
                    self.connectSocket()
                    await self.refreshChats()
                    await self.refreshSelectedMessages()
                }
            }
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
        pingWorkItem?.cancel()
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
        await refreshSelectedMessages()
        await refreshChats()
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
            await refreshSelectedMessages()
            await refreshChats()
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
            await refreshSelectedMessages()
            await refreshChats()
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

    private func refreshSelectedMessages() async {
        guard let session = selected, loggedIn else { return }
        do {
            let data: ChatMessagesResponse = try await APIClient.shared.request(
                "/api/staff/chats/\(session.token)/messages", baseURL: server, token: authToken
            )
            selected = data.session
            messages = data.messages
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectSocket() {
        reconnectWorkItem?.cancel()
        pingWorkItem?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connected = false

        guard loggedIn,
              let url = URL(string: server),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = url.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/staff"
        components.queryItems = [URLQueryItem(name: "token", value: authToken)]
        guard let socketURL = components.url else { return }

        let task = URLSession.shared.webSocketTask(with: socketURL)
        socket = task
        task.resume()
        receiveLoop(task)
        schedulePing(task, delay: 1)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.connected = true
                    // Start listening for the next frame immediately.  Do not block the
                    // WebSocket receive loop while REST state is being refreshed.
                    self.receiveLoop(task)
                    await self.handleSocketMessage(message)
                case .failure(let error):
                    print("WebSocket receive failed: \(error)")
                    self.handleSocketFailure(task)
                }
            }
        }
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let value):
            data = value
        @unknown default:
            data = nil
        }

        guard let data else { return }

        // The server-side event payload may evolve.  The first build required one
        // exact Codable shape (type/message/session), so a harmless field/layout
        // difference caused the event to be silently ignored.  For live UI we only
        // need to know that a non-heartbeat event arrived; REST remains the source of
        // truth for sessions/messages.
        var eventType = ""
        var eventToken: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            eventType = (object["type"] as? String ?? object["event"] as? String ?? "").lowercased()
            eventToken = extractSessionToken(from: object)
        }

        if ["ping", "pong", "heartbeat", "connected", "hello"].contains(eventType) {
            return
        }

        await refreshChats()

        guard let currentToken = selected?.token else { return }
        // If the event identifies another session, only the list needs updating.
        // If it has no token (or it is the open session), refresh the open thread too.
        if eventToken == nil || eventToken == currentToken {
            await refreshSelectedMessages()
        }
    }

    private func extractSessionToken(from object: [String: Any]) -> String? {
        if let token = object["session_token"] as? String { return token }
        if let session = object["session"] as? [String: Any], let token = session["token"] as? String { return token }
        if let data = object["data"] as? [String: Any] {
            if let token = data["session_token"] as? String { return token }
            if let session = data["session"] as? [String: Any], let token = session["token"] as? String { return token }
            if let token = data["token"] as? String { return token }
        }
        return object["token"] as? String
    }

    private func schedulePing(_ task: URLSessionWebSocketTask, delay: TimeInterval = 20) {
        pingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task else { return }
            Task { @MainActor in
                guard self.socket === task, self.loggedIn else { return }
                task.sendPing { [weak self, weak task] error in
                    Task { @MainActor in
                        guard let self, let task, self.socket === task else { return }
                        if let error {
                            print("WebSocket ping failed: \(error)")
                            self.handleSocketFailure(task)
                        } else {
                            self.connected = true
                            self.schedulePing(task)
                        }
                    }
                }
            }
        }
        pingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleSocketFailure(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        connected = false
        pingWorkItem?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.loggedIn else { return }
            self.connectSocket()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

private struct LoginBody: Codable { let username: String; let password: String }
private struct OKResponse: Codable { let ok: Bool }
