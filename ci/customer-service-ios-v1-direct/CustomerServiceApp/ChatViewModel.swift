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
    @Published var activeSessionToken: String?
    @Published var loadingMessages = false
    @Published var errorText = ""
    @Published var connected = false
    @Published var isBusy = false
    @Published var pendingOpenToken: String?

    private var socket: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var messageRequestGeneration: UInt64 = 0

    init() {
        NotificationCenter.default.publisher(for: .apnsToken)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in Task { await self?.registerDevice(token) } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openChat)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in
                Task { @MainActor in
                    guard let self else { return }
                    self.pendingOpenToken = token
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.loggedIn else { return }
                    self.connectSocket()
                    await self.refreshChats()
                    await self.refreshActiveMessages()
                    await self.registerSavedDeviceToken()
                }
            }
            .store(in: &cancellables)
    }

    var loggedIn: Bool { !authToken.isEmpty }

    func login() async {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            errorText = "请输入客服账号和密码"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            server = Self.productionServer
            let data: LoginResponse = try await APIClient.shared.request(
                "/api/auth/login", baseURL: server, method: "POST",
                body: LoginBody(username: username, password: password)
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
            await registerSavedDeviceToken()
        } catch { errorText = error.localizedDescription }
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
        activeSessionToken = nil
        messages = []
        loadingMessages = false
        messageRequestGeneration &+= 1
        UserDefaults.standard.removeObject(forKey: "authToken")
    }

    func restore() async {
        guard loggedIn else { return }
        server = Self.productionServer
        do {
            let user: APIUser = try await APIClient.shared.request("/api/auth/me", baseURL: server, token: authToken)
            me = user
            await refreshChats()
            connectSocket()
            requestPushPermission()
            await registerSavedDeviceToken()
        } catch { logout() }
    }

    func refreshChats() async {
        guard loggedIn else { return }
        do {
            let rows: [ChatSession] = try await APIClient.shared.request("/api/staff/chats", baseURL: server, token: authToken)
            chats = rows
            if let token = activeSessionToken,
               let newer = rows.first(where: { $0.token == token }) {
                selected = newer
            }
        } catch { errorText = error.localizedDescription }
    }

    func open(token: String) async {
        beginSwitch(to: token)
        if let session = chats.first(where: { $0.token == token }) {
            selected = session
        } else {
            await refreshChats()
            guard activeSessionToken == token else { return }
            selected = chats.first(where: { $0.token == token })
        }
        await loadMessages(for: token)
        await refreshChats()
    }

    func open(_ session: ChatSession) async {
        beginSwitch(to: session.token)
        selected = session
        await loadMessages(for: session.token)
        await refreshChats()
    }

    private func beginSwitch(to token: String) {
        if activeSessionToken != token {
            messageRequestGeneration &+= 1
            activeSessionToken = token
            selected = chats.first(where: { $0.token == token })
            messages = []
            loadingMessages = true
            errorText = ""
        }
    }

    func leaveConversation(token: String) {
        guard activeSessionToken == token else { return }
        messageRequestGeneration &+= 1
        activeSessionToken = nil
        selected = nil
        messages = []
        loadingMessages = false
    }

    func endService(_ session: ChatSession) async {
        do {
            let _: CloseSessionResponse = try await APIClient.shared.request(
                "/api/staff/chats/\(session.token)/close", baseURL: server, token: authToken, method: "POST"
            )
            chats.removeAll { $0.token == session.token }
            if activeSessionToken == session.token { leaveConversation(token: session.token) }
        } catch { errorText = error.localizedDescription }
    }

    func send(_ text: String) async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionToken = activeSessionToken, !value.isEmpty else { return }
        do {
            let _: ChatMessage = try await APIClient.shared.request(
                "/api/staff/chats/\(sessionToken)/messages", baseURL: server, token: authToken,
                method: "POST", body: SendMessageBody(content: value, kind: "text")
            )
            await loadMessages(for: sessionToken)
            await refreshChats()
        } catch { errorText = error.localizedDescription }
    }

    func uploadAttachment(_ data: Data, filename: String, mime: String) async {
        guard let sessionToken = activeSessionToken else { return }
        do {
            _ = try await APIClient.shared.uploadAttachment(
                "/api/staff/chats/\(sessionToken)/upload", baseURL: server, token: authToken,
                data: data, filename: filename, mime: mime
            )
            await loadMessages(for: sessionToken)
            await refreshChats()
        } catch { errorText = error.localizedDescription }
    }

    func registerDevice(_ deviceToken: String) async {
        guard loggedIn, me?.role == "agent" else { return }
        do {
            let _: OKResponse = try await APIClient.shared.request(
                "/api/staff/device-token", baseURL: server, token: authToken, method: "POST",
                body: DeviceTokenBody(token: deviceToken, environment: "production")
            )
        } catch { print("Device token registration failed: \(error)") }
    }

    func registerSavedDeviceToken() async {
        if let token = UserDefaults.standard.string(forKey: "apnsDeviceToken"), !token.isEmpty {
            await registerDevice(token)
        }
    }

    func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    private func refreshActiveMessages() async {
        guard let token = activeSessionToken else { return }
        await loadMessages(for: token)
    }

    private func loadMessages(for sessionToken: String) async {
        guard loggedIn, activeSessionToken == sessionToken else { return }
        messageRequestGeneration &+= 1
        let generation = messageRequestGeneration
        loadingMessages = true
        do {
            let data: ChatMessagesResponse = try await APIClient.shared.request(
                "/api/staff/chats/\(sessionToken)/messages", baseURL: server, token: authToken
            )
            guard activeSessionToken == sessionToken, messageRequestGeneration == generation else { return }
            selected = data.session
            messages = data.messages.filter { $0.session_id == data.session.id }
            loadingMessages = false
        } catch {
            guard activeSessionToken == sessionToken, messageRequestGeneration == generation else { return }
            loadingMessages = false
            errorText = error.localizedDescription
        }
    }

    private func connectSocket() {
        reconnectWorkItem?.cancel()
        pingWorkItem?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connected = false
        guard loggedIn, let url = URL(string: server), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        c.scheme = url.scheme == "https" ? "wss" : "ws"
        c.path = "/ws/staff"
        c.queryItems = [URLQueryItem(name: "token", value: authToken)]
        guard let socketURL = c.url else { return }
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
        case .string(let text): data = text.data(using: .utf8)
        case .data(let value): data = value
        @unknown default: data = nil
        }
        guard let data else { return }

        var eventType = ""
        var eventToken: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            eventType = (object["type"] as? String ?? object["event"] as? String ?? "").lowercased()
            eventToken = extractSessionToken(from: object)
        }
        if ["ping", "pong", "heartbeat", "connected", "hello"].contains(eventType) { return }

        await refreshChats()
        guard let currentToken = activeSessionToken else { return }
        if eventToken == nil || eventToken == currentToken {
            await loadMessages(for: currentToken)
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
