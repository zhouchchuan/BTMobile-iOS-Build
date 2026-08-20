import SwiftUI
import PhotosUI

struct RootView: View {
    @EnvironmentObject var vm: ChatViewModel
    var body: some View {
        Group {
            if vm.loggedIn { MainView() } else { LoginView() }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.loggedIn)
    }
}

struct LoginView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 70)

                    Image("AppLoginLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .blue.opacity(0.2), radius: 18, y: 8)

                    Text("客服工作台")
                        .font(.largeTitle.bold())
                    Text("实时接收并回复网页客户消息")
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        TextField("客服账号", text: $vm.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)

                        SecureField("密码", text: $vm.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 14)

                    if !vm.errorText.isEmpty {
                        Text(vm.errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await vm.login() }
                    } label: {
                        HStack {
                            if vm.isBusy { ProgressView().tint(.white) }
                            Text(vm.isBusy ? "正在登录…" : "登录")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.isBusy)

                    Text("服务地址：service.linkyou.win:9443")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)

                    Text("登录后会申请系统通知权限。开启通知后，可在后台或锁屏状态接收新的客户咨询提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.chats.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("暂无客户会话").font(.headline)
                        Text("有客户从网页发起咨询后，会话会实时出现在这里。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                } else {
                    List(vm.chats) { chat in
                        Button {
                            Task {
                                await vm.open(chat)
                                showChat = true
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(.blue.gradient)
                                    .frame(width: 46, height: 46)
                                    .overlay(
                                        Text(String(chat.visitor_name.prefix(1)))
                                            .foregroundStyle(.white)
                                            .bold()
                                    )

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(chat.visitor_name).font(.headline)
                                        Spacer()
                                        if chat.unread_agent > 0 {
                                            Text("\(chat.unread_agent)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.white)
                                                .padding(6)
                                                .background(.red, in: Circle())
                                        }
                                    }
                                    Text(chat.last_message?.content ?? chat.ip)
                                        .lineLimit(1)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("IP \(chat.ip)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .refreshable { await vm.refreshChats() }
                }
            }
            .navigationTitle(vm.me?.display_name ?? "客服")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.connected ? .green : .orange)
                            .frame(width: 9, height: 9)
                        Text(vm.connected ? "已连接" : "连接中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("开启通知") { vm.requestPushPermission() }
                        Button("刷新会话") { Task { await vm.refreshChats() } }
                        Button("退出登录", role: .destructive) { vm.logout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(isPresented: $showChat) { ChatView() }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.messages) { message in
                            HStack {
                                if message.sender_type == "agent" { Spacer(minLength: 50) }

                                Group {
                                    if message.kind == "image", let url = imageURL(message.content) {
                                        AsyncImage(url: url) { image in
                                            image.resizable().scaledToFit()
                                        } placeholder: {
                                            ProgressView().frame(width: 140, height: 120)
                                        }
                                        .frame(maxWidth: 240, maxHeight: 280)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    } else {
                                        Text(message.content)
                                            .textSelection(.enabled)
                                            .padding(11)
                                            .background(message.sender_type == "agent" ? Color.blue : Color(.secondarySystemBackground))
                                            .foregroundColor(message.sender_type == "agent" ? .white : .primary)
                                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    }
                                }
                                .frame(maxWidth: 285, alignment: message.sender_type == "agent" ? .trailing : .leading)

                                if message.sender_type != "agent" { Spacer(minLength: 50) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.messages.count) { _ in
                    if let id = vm.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .onChange(of: photoItem) { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            await vm.uploadImage(data)
                        }
                        photoItem = nil
                    }
                }

                TextField("回复客户…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let value = text
                    text = ""
                    Task { await vm.send(value) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle(vm.selected?.visitor_name ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func imageURL(_ content: String) -> URL? {
        if content.hasPrefix("http://") || content.hasPrefix("https://") {
            return URL(string: content)
        }
        return URL(string: vm.server + content)
    }
}
