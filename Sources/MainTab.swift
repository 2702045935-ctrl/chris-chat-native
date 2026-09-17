import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var tab = 0

    init() {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor.dyn(0xF7F7F7, 0x1C1C1E)
        bar.shadowColor = UIColor.dyn(0xD9D9D9, 0x2C2C2E)
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor.dyn(0xEDEDED, 0x1C1C1E)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.dyn(0x181818, 0xEDEDED)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some View {
        TabView(selection: $tab) {
            ChatsView()
                .tabItem { Label("微信", systemImage: "message") }
                .tag(0)

            ContactsView()
                .tabItem { Label("通讯录", systemImage: "person.2") }
                .tag(1)

            DiscoverView()
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(2)

            MeView()
                .tabItem { Label("我", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .tint(Brand.green)
    }
}

/* ============================================================ 搜索框 */

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Brand.subLabel)
            TextField("搜索", text: $text)
                .font(.system(size: 16))
                .foregroundColor(Brand.label)
                .fixedSize(horizontal: text.isEmpty, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: text.isEmpty ? .center : .leading)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(Brand.cellBg))
    }
}

/* ============================================================ 通用行 */

struct MenuRow: View {
    let icon: String
    let color: Color
    let title: String
    var detail: String = ""
    var showArrow: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
            }
            .frame(width: 26, height: 26)

            Text(title)
                .font(.system(size: 17))
                .foregroundColor(Brand.label)

            Spacer()

            if !detail.isEmpty {
                Text(detail).font(.system(size: 15)).foregroundColor(Brand.subLabel)
            }
            if showArrow {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.dyn(0xC7C7CC, 0x48484A))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Brand.cellBg)
    }
}

struct GroupCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Brand.cellBg)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 16)
    }
}

struct ComingSoonView: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Brand.label)
            Text("这一页排在下一批，先把骨架跑起来")
                .font(.system(size: 14))
                .foregroundColor(Brand.subLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.pageBg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

