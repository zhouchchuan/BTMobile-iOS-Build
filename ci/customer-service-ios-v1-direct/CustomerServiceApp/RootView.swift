import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit
import UIKit

struct RootView: View {
    @EnvironmentObject var vm: ChatViewModel
    var body: some View {
        Group { if vm.loggedIn { MainView() } else { LoginView() } }
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
                    Image("AppLoginLogo").resizable().scaledToFit().frame(width:108,height:108)
                        .clipShape(RoundedRectangle(cornerRadius:24,style:.continuous)).shadow(color:.blue.opacity(0.2),radius:18,y:8)
                    Text("客服工作台").font(.largeTitle.bold())
                    Text("实时接收并回复网页客户消息").foregroundStyle(.secondary)
                    VStack(spacing:12) {
                        TextField("客服账号",text:$vm.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        SecureField("密码",text:$vm.password).textFieldStyle(.roundedBorder)
                    }.padding(.top,14)
                    if !vm.errorText.isEmpty { Text(vm.errorText).font(.footnote).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading) }
                    Button { Task { await vm.login() } } label: {
                        HStack { if vm.isBusy { ProgressView().tint(.white) }; Text(vm.isBusy ? "正在登录…":"登录") }
                            .frame(maxWidth:.infinity).padding(.vertical,10)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(vm.isBusy)
                    Text("service.linkyou.win:9443").font(.caption).foregroundStyle(.tertiary).padding(.top,6)
                    Text("V1.0.3 支持免费的 PWA 锁屏通知：登录后可从右上角菜单打开 Safari 设置，无需购买 Apple Developer 推送服务。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var path:[String] = []
    @State private var ending: ChatSession?
    @State private var showPushHelp = false

    var body: some View {
        NavigationStack(path:$path) {
            Group {
                if vm.chats.isEmpty {
                    VStack(spacing:12) {
                        Image(systemName:"bubble.left.and.bubble.right").font(.system(size:44)).foregroundStyle(.secondary)
                        Text("暂无客户会话").font(.headline)
                        Text("访客发起咨询后，会话会实时出现在这里。结束服务的会话会暂时隐藏，访客再次进入时自动恢复。")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(32)
                } else {
                    List {
                        ForEach(vm.chats) { chat in
                            NavigationLink(value:chat.token) { ConversationCard(chat:chat) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top:5,leading:16,bottom:5,trailing:16))
                                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                                .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                                    Button(role:.destructive) { ending = chat } label: { Label("结束服务",systemImage:"xmark.bubble") }
                                }
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden).background(Color(.systemGroupedBackground))
                        .refreshable { await vm.refreshChats() }
                }
            }
            .navigationTitle(vm.me?.display_name ?? "客服")
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    HStack(spacing:6) { Circle().fill(vm.connected ? .green:.orange).frame(width:9,height:9); Text(vm.connected ? "实时在线":"连接中").font(.caption).foregroundStyle(.secondary) }
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Menu {
                        Button("免费锁屏通知设置") { showPushHelp = true }
                        Button("原生 APNs 通知（可选）") { vm.requestPushPermission() }
                        Button("刷新会话") { Task { await vm.refreshChats() } }
                        Button("退出登录",role:.destructive){vm.logout()}
                    } label:{Image(systemName:"ellipsis.circle")}
                }
            }
            .navigationDestination(for:String.self) { token in ChatView(sessionToken:token) }
            .onChange(of:vm.pendingOpenToken) { token in
                guard let token else { return }
                Task {
                    await vm.refreshChats()
                    guard vm.chats.contains(where:{$0.token==token}) else { return }
                    if path.last != token { path.append(token) }
                    vm.pendingOpenToken = nil
                }
            }
            .confirmationDialog("结束本次客服服务？",isPresented:Binding(get:{ending != nil},set:{if !$0{ending=nil}}),titleVisibility:.visible) {
                Button("结束服务",role:.destructive) { if let ending { Task { await vm.endService(ending) } }; ending=nil }
                Button("取消",role:.cancel) { ending=nil }
            } message: { Text("会话记录不会删除。访客以后再次打开客服页面时，这个会话会重新出现在列表中继续沟通。") }
            .alert("免费锁屏通知",isPresented:$showPushHelp) {
                Button("打开 Safari") {
                    if let url=URL(string:"https://service.linkyou.win:9443/staff") { UIApplication.shared.open(url) }
                }
                Button("取消",role:.cancel){}
            } message: {
                Text("Safari 打开客服工作台后：分享 → 添加到主屏幕 → 从桌面打开“小美客服” → 点“开启通知”。之后锁屏或后台也能收到访客消息提醒。")
            }
        }
    }
}

struct ConversationCard: View {
    let chat:ChatSession
    var body: some View {
        HStack(spacing:13) {
            Circle().fill(LinearGradient(colors:[.cyan,.blue],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:52,height:52)
                .overlay(Text("访").font(.headline.bold()).foregroundStyle(.white))
            VStack(alignment:.leading,spacing:5) {
                HStack { Text(chat.visitor_name).font(.headline); Spacer(); Text(shortTime(chat.last_message_at)).font(.caption2).foregroundStyle(.tertiary) }
                Text(preview(chat.last_message)).lineLimit(1).font(.subheadline).foregroundStyle(.secondary)
                Text("IP \(chat.ip)").font(.caption).foregroundStyle(.tertiary)
            }
            if chat.unread_agent > 0 { Text("\(chat.unread_agent)").font(.caption2.bold()).foregroundStyle(.white).frame(minWidth:22,minHeight:22).background(.red,in:Circle()) }
        }
        .padding(14).background(.background,in:RoundedRectangle(cornerRadius:22,style:.continuous))
        .shadow(color:.black.opacity(0.035),radius:10,y:3).contentShape(Rectangle())
    }
    private func preview(_ m:ChatMessage?)->String { guard let m else{return "新会话"}; switch m.kind { case "image":return "[图片]"; case "video":return "[短视频]"; case "attachment_deleted":return "[附件已删除]"; default:return m.content } }
    private func shortTime(_ s:String)->String { let f=ISO8601DateFormatter(); guard let d=f.date(from:s) else{return ""}; let out=DateFormatter();out.dateFormat="HH:mm";return out.string(from:d) }
}

struct ChatView: View {
    @EnvironmentObject var vm:ChatViewModel
    let sessionToken:String
    @State private var text=""
    @State private var photoItem:PhotosPickerItem?

    private var currentSession:ChatSession? {
        if vm.selected?.token == sessionToken { return vm.selected }
        return vm.chats.first(where:{$0.token == sessionToken})
    }

    var body: some View {
        VStack(spacing:0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if vm.loadingMessages && vm.activeSessionToken == sessionToken && vm.messages.isEmpty {
                        VStack(spacing:10) { ProgressView(); Text("正在载入该访客会话…").font(.footnote).foregroundStyle(.secondary) }
                            .frame(maxWidth:.infinity).padding(.top,80)
                    } else {
                        LazyVStack(spacing:14) {
                            ForEach(vm.messages.filter { message in
                                guard vm.activeSessionToken == sessionToken else { return false }
                                guard let sid=currentSession?.id else { return false }
                                return message.session_id == sid
                            }) { message in MessageRow(message:message).id(message.id) }
                        }.padding(.horizontal,12).padding(.vertical,18)
                    }
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of:vm.messages.count) { _ in if vm.activeSessionToken == sessionToken, let id=vm.messages.last?.id { withAnimation(.easeOut(duration:0.18)){proxy.scrollTo(id,anchor:.bottom)} } }
            }
            Divider()
            HStack(spacing:10) {
                PhotosPicker(selection:$photoItem,matching:.any(of:[.images,.videos])) { Image(systemName:"photo.on.rectangle").font(.title3).frame(width:34,height:34) }
                    .disabled(vm.activeSessionToken != sessionToken || vm.loadingMessages)
                    .onChange(of:photoItem) { item in guard let item else{return}; Task { await sendPicked(item); photoItem=nil } }
                TextField("回复客户…",text:$text,axis:.vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    .disabled(vm.activeSessionToken != sessionToken || vm.loadingMessages)
                Button { let v=text;text="";Task{await vm.send(v)} } label:{Image(systemName:"paperplane.fill").font(.title3)}
                    .disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || vm.activeSessionToken != sessionToken || vm.loadingMessages)
            }.padding(10).background(.ultraThinMaterial)
        }
        .task(id:sessionToken) { await vm.open(token:sessionToken) }
        .onDisappear { vm.leaveConversation(token:sessionToken) }
        .toolbar {
            ToolbarItem(placement:.principal) {
                VStack(spacing:1) {
                    Text(currentSession?.visitor_name ?? "访客").font(.headline)
                    Text("IP \(currentSession?.ip ?? "—")").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendPicked(_ item:PhotosPickerItem) async {
        guard vm.activeSessionToken == sessionToken, let data = try? await item.loadTransferable(type:Data.self) else { return }
        let type = item.supportedContentTypes.first ?? .jpeg
        let mime = type.preferredMIMEType ?? "image/jpeg"
        let ext = type.preferredFilenameExtension ?? (mime.hasPrefix("video/") ? "mp4":"jpg")
        await vm.uploadAttachment(data, filename:"upload.\(ext)", mime:mime)
    }
}

struct MessageRow: View {
    @EnvironmentObject var vm:ChatViewModel
    let message:ChatMessage
    var isAgent:Bool { message.sender_type == "agent" }
    var isSystem:Bool { message.sender_type == "system" }
    var body: some View {
        if isSystem {
            HStack { Spacer(); MessageContent(message:message,isAgent:false).font(.footnote).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,7).background(.white.opacity(0.72),in:Capsule()); Spacer() }
        } else {
            HStack(alignment:.bottom,spacing:8) {
                if isAgent { Spacer(minLength:44) } else { VisitorAvatar() }
                MessageContent(message:message,isAgent:isAgent)
                if isAgent { AgentAvatar() } else { Spacer(minLength:44) }
            }
        }
    }
}

struct MessageContent: View {
    @EnvironmentObject var vm:ChatViewModel
    let message:ChatMessage
    let isAgent:Bool
    var body: some View {
        Group {
            if message.kind == "image", let url=absoluteURL(message.content) {
                AsyncImage(url:url) { image in image.resizable().scaledToFit() } placeholder:{ ProgressView().frame(width:150,height:120) }
                    .frame(maxWidth:250,maxHeight:300).clipShape(RoundedRectangle(cornerRadius:12,style:.continuous))
            } else if message.kind == "video", let url=absoluteURL(message.content) {
                VideoPlayer(player:AVPlayer(url:url)).frame(width:240,height:155).clipShape(RoundedRectangle(cornerRadius:12,style:.continuous))
            } else {
                Text(message.kind == "attachment_deleted" ? "附件已由管理员删除" : message.content)
                    .textSelection(.enabled).padding(.horizontal,13).padding(.vertical,10)
                    .background(isAgent ? Color(red:0.05,green:0.63,blue:0.94):Color.white)
                    .foregroundStyle(isAgent ? Color.white:Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius:11,style:.continuous))
            }
        }.frame(maxWidth:290,alignment:isAgent ? .trailing:.leading)
    }
    private func absoluteURL(_ value:String)->URL? { if value.hasPrefix("http://")||value.hasPrefix("https://"){return URL(string:value)};return URL(string:vm.server+value) }
}

struct VisitorAvatar:View { var body:some View{Circle().fill(LinearGradient(colors:[.cyan,.blue],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:38,height:38).overlay(Text("访").font(.caption.bold()).foregroundStyle(.white))} }
struct AgentAvatar:View { var body:some View{Image("AppLoginLogo").resizable().scaledToFill().frame(width:38,height:38).clipShape(Circle())} }
