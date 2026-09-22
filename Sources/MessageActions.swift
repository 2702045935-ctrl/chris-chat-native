import SwiftUI

/* ============================================================
   长按聊天里的消息 → 微信那一套动作条
   （复制 · 转发 · 收藏 · 引用 · 撤回 · 删除 · 多选 · 举报）
   ============================================================ */

struct MsgAction: Identifiable, Hashable {
    var key: String
    var label: String
    var icon: String
    var danger: Bool = false
    var id: String { key }
}

/* 长按消息弹出来的那个小方框（微信那种：白色圆角框 + 一排图标文字，
   贴在消息旁边，点外面就收起来）。 */
struct MsgMenuBox: View {
    let actions: [MsgAction]
    var onPick: (MsgAction) -> Void

    @Environment(\.colorScheme) private var scheme
    private var bg: Color { scheme == .dark ? Color(hex: 0x3A3A3C) : .white }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }

    static let itemW: CGFloat = 56
    static let itemH: CGFloat = 62
    static let padH: CGFloat = 6
    static let padV: CGFloat = 8

    /// 一排最多放几个（微信也是这么横着排）
    static func columns(_ n: Int) -> Int { min(6, max(1, n)) }

    static func size(_ n: Int) -> CGSize {
        let cols = columns(n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        return CGSize(width: CGFloat(cols) * itemW + padH * 2,
                      height: CGFloat(rows) * itemH + padV * 2)
    }

    var body: some View {
        let cols = MsgMenuBox.columns(actions.count)
        let rows = Int(ceil(Double(actions.count) / Double(cols)))
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { idx, a in
                        if idx / cols == r {
                            Button {
                                onPick(a)
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: a.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(a.danger ? Color(hexString: "#FA5151") : ink)
                                        .frame(height: 22)
                                    Text(Tr(a.label))
                                        .font(pf(11.5))
                                        .foregroundColor(a.danger ? Color(hexString: "#FA5151") : ink)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .frame(width: MsgMenuBox.itemW, height: MsgMenuBox.itemH)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, MsgMenuBox.padH)
        .padding(.vertical, MsgMenuBox.padV)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.black.opacity(scheme == .dark ? 0 : 0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

/* 转发：先选一个聊天（微信也是先选人） */
struct ForwardPickerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// 要转发的内容
    let kind: String
    let content: String
    var onSent: () -> Void

    @State private var keyword = ""
    @State private var busy = ""

    private var list: [Chat] {
        let base = app.chats
        guard !keyword.isEmpty else { return base }
        return base.filter { ($0.name).lowercased().contains(keyword.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("转发给")) {
                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(16)).foregroundColor(C.label)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            SearchBoxCenter(text: $keyword).padding(L.searchPad)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { chat in
                        Button {
                            send(to: chat)
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(path: chat.avatar ?? "", size: 44, radius: 6)
                                Text(chat.name)
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if busy == chat.id { ProgressView() }
                                else {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(C.green)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 66)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(C.cardBg)
                        .overlay(alignment: .bottom) { HairLine(inset: 72) }
                    }
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func send(to chat: Chat) {
        busy = chat.id
        Task {
            _ = try? await API.shared.send(chatId: chat.id, kind: kind, content: content)
            busy = ""
            app.show(Tr("已转发给") + "「" + chat.name + "」")
            onSent()
            dismiss()
        }
    }
}

/* 多选时底下那条：转发 / 收藏 / 删除 */
struct MultiSelectBar: View {
    let count: Int
    var onForward: () -> Void
    var onFavorite: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }

    var body: some View {
        HStack(spacing: 0) {
            item("转发", "arrowshape.turn.up.right", onForward)
            item("收藏", "star", onFavorite)
            item("删除", "trash", onDelete, danger: true)
            Button { onCancel() } label: {
                Text(Tr("取消"))
                    .font(pf(15))
                    .foregroundColor(ink)
                    .frame(width: 70, height: 54)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 54)
        .background(C.tabBg)
        .overlay(alignment: .top) { HairLine() }
    }

    private func item(_ title: String, _ icon: String, _ tap: @escaping () -> Void, danger: Bool = false) -> some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(Tr(title)).font(pf(11))
            }
            .foregroundColor(danger ? Color(hexString: "#FA5151") : ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
