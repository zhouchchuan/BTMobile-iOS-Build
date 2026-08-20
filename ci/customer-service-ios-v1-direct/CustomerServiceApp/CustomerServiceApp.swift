import SwiftUI

@main
struct CustomerServiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = ChatViewModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(vm).task { await vm.restore() } } }
}
