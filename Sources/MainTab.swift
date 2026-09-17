import SwiftUI
import UIKit

/* ============================================================ 底部四个标签 */

struct MainTabView: View {
    @EnvironmentObject var app: AppState
    @State private var tab = 0

    private var unreadTotal: Int {
        app.chats.reduce(0) { $0 + ($1.unread ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if tab == 0 {
                    ChatsView()
                } else if tab == 1 {
                    ContactsView()
                } else if tab == 2 {
                    DiscoverView()
                } else {
                    MeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabBar(selection: $tab, badge: unreadTotal)
        }
        .background(C.navBg.ignoresSafeArea())
    }
}

struct TabBar: View {
    @Binding var selection: Int
    var badge: Int

    private let items: [(String, String, String)] = [
        ("message", "message.fill", "微信"),
        ("person.2", "person.2.fill", "通讯录"),
        ("safari", "safari", "发现"),
        ("person.crop.circle", "person.crop.circle.fill", "我")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: selection == i ? items[i].1 : items[i].0)
                                .font(.system(size: 25, weight: .regular))
                                .frame(width: 26, height: 26)
                            if i == 0 && badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(C.red))
                                    .offset(x: 9, y: -6)
                            }
                        }
                        Text(items[i].2)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(selection == i ? C.green : C.tabInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: L.tabH)
        .background(
            ZStack {
                C.tabBg.ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    Rectangle().fill(C.navLine).frame(height: 0.5)
                    Spacer()
                }
                .ignoresSafeArea(edges: .bottom)
            }
        )
    }
}

/* ============================================================ 顶部导航条 */

struct NavBar<Right: View>: View {
    let title: String
    let back: (() -> Void)?
    let onLongPressTitle: (() -> Void)?
    private let right: Right

    init(title: String,
         back: (() -> Void)? = nil,
         onLongPressTitle: (() -> Void)? = nil,
         @ViewBuilder right: () -> Right) {
        self.title = title
        self.back = back
        self.onLongPressTitle = onLongPressTitle
        self.right = right()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: titleSize, weight: weight))
                .foregroundColor(C.label)
                .onLongPressGesture { onLongPressTitle?() }

            HStack(spacing: 0) {
                if let back = back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                right()
            }
        }
        .frame(height: L.navH)
    }

    /// 网页版：会话/聊天页 18px，发现页 17px，都是常规体
    private var titleSize: CGFloat { title == "发现" ? 17 : 18 }
    private var weight: Font.Weight { .regular }
}

extension NavBar where Right == EmptyView {
    init(title: String, back: (() -> Void)? = nil, onLongPressTitle: (() -> Void)? = nil) {
        self.init(title: title, back: back, onLongPressTitle: onLongPressTitle) { EmptyView() }
    }
}

/* ============================================================ 搜索框 */

/// 微信页：纯白、圆角 5、没输入时「放大镜 + 搜索」整组居中（和手机微信一样）
struct SearchBoxCenter: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    private var centered: Bool { text.isEmpty && !focused }

    var body: some View {
        HStack(spacing: centered ? 3 : 6) {
            SVGIcon(markup: I.searchSmall, size: 16, color: C.searchIcon)

            ZStack(alignment: centered ? .center : .leading) {
                if text.isEmpty {
                    Text("搜索")
                        .font(.system(size: 16))
                        .foregroundColor(C.searchIcon)
                }
                TextField("", text: $text)
                    .focused($focused)
                    .font(.system(size: 16))
                    .foregroundColor(C.label)
                    .multilineTextAlignment(centered ? .center : .leading)
            }
            .frame(maxWidth: centered ? 46 : .infinity)
        }
        .padding(.leading, centered ? 28 : 9)
        .padding(.trailing, centered ? 18 : 9)
        .frame(height: L.searchBoxH)
        .background(
            RoundedRectangle(cornerRadius: centered ? 5 : 6, style: .continuous)
                .fill(C.searchBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: centered ? 5 : 6, style: .continuous)
                .stroke(C.searchBorder, lineWidth: 1)
        )
    }
}

/// 通讯录页：圆角 10、带一点阴影、放大镜在左、「搜索」左对齐
struct SearchBoxLeft: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: L.v(5, 1.8, 8)) {
            SVGIcon(markup: I.searchBig, size: 16, color: C.searchIcon2)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("搜索")
                        .font(.system(size: 15))
                        .foregroundColor(C.searchIcon2)
                }
                TextField("", text: $text)
                    .font(.system(size: 15))
                    .foregroundColor(C.label)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: L.searchBoxH)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(C.searchBg)
                .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(C.searchBorder, lineWidth: 1)
        )
    }
}

/* ============================================================ 通用行 */

/// 发现页 / 我页 / 设置页的一行：图标 + 文字 +（右侧值）+ 箭头
struct MenuRow: View {
    let icon: String
    var iconColor: Color = C.green
    let title: String
    var detail: String = ""
    var showArrow: Bool = true
    var badge: Bool = false
    var thumb: String = ""
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: L.menuGap) {
                SVGIcon(markup: icon, size: L.menuIcon * 1.13, color: iconColor)
                    .frame(width: L.menuIcon, height: L.menuIcon)

                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(C.label)

                Spacer(minLength: 0)

                if !detail.isEmpty {
                    Text(detail).font(.system(size: 15)).foregroundColor(C.subLabel)
                }
                if !thumb.isEmpty {
                    ZStack(alignment: .topTrailing) {
                        RemoteImage(path: thumb)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        if badge {
                            Circle().fill(C.red).frame(width: 9, height: 9).offset(x: 4.5, y: -4.5)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .padding(.trailing, -8)
                }
                if showArrow {
                    Chevron(size: 9, line: 1.6)
                        .padding(.trailing, 3)
                }
            }
            .padding(.leading, L.menuPadL)
            .padding(.trailing, L.menuPadR)
            .frame(height: L.menuH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }
}

struct MenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.gray.opacity(0.16) : Color.clear)
    }
}

struct GroupCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(C.cardBg)
    }
}
