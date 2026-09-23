import SwiftUI
import UIKit       // 分享要往剪贴板里放链接（UIPasteboard）

/* ============================================================
   直播专场（发现 → 直播专场）
   没有真视频（内网演示服跑不动推流），但「谁在看、谁在说话、多少赞」全是真的：
     · 房间名单在服务器的 data/live.json（后台可直接改）
     · 进房间上报，在线人数实时同步（长连接广播）
     · 弹幕、点赞都是实时的：同房间的人会立刻看到
   ============================================================ */

struct LiveRoom: Decodable, Identifiable, Hashable {
    struct Host: Decodable, Hashable {
        var id: String?
        var name: String?
        var avatar: String?
    }
    var id: String
    var title: String?
    var tag: String?
    var cover: String?
    var status: String?
    var hot: Int?
    var watching: Int?
    var likes: Int?
    /// 主播正在推流（有画面可看）
    var streaming: Bool?
    var hostId: String?
    var host: Host?

    var isLive: Bool { (status ?? "live") == "live" }
    var hostName: String { host?.name ?? "主播" }
    var hostAvatar: String { host?.avatar ?? "" }
}

/* 直播房间不需要额外的 decodable：API 里那几个方法只用得到 LiveRoom */

/* ---------------------------------------------------------- 房间列表 */

struct LiveListView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [LiveRoom] = []
    @State private var loading = true

    private let pageBg = Color(hex: 0x111111)
    private let cardBg = Color(hex: 0x1B1B1D)
    private let ink = Color.white
    private let subInk = Color(hex: 0x929292)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(Tr("直播专场")).font(pf(17, .semibold)).foregroundColor(ink)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(ink)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: L.navH)
            .background(pageBg)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if loading && rooms.isEmpty {
                        ProgressView().tint(.white).padding(.top, 60)
                    } else if rooms.isEmpty {
                        Text(Tr("还没有直播间"))
                            .font(pf(14)).foregroundColor(subInk).padding(.top, 70)
                    } else {
                        ForEach(rooms) { r in
                            NavigationLink(value: r) { roomCard(r) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .navigationDestination(for: LiveRoom.self) { r in
            LiveRoomView(room: r)
        }
        .task {
            rooms = (try? await API.shared.liveRooms()) ?? []
            loading = false
        }
    }

    private func roomCard(_ r: LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(r.isLive
                          ? LinearGradient(colors: [Color(hex: 0x2B3A55), Color(hex: 0x14161C)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(hex: 0x222225), Color(hex: 0x191919)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 132)
                if !(r.cover ?? "").isEmpty {
                    RemoteImage(path: r.cover ?? "").frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 6) {
                    if r.isLive {
                        Text(Tr("直播中"))
                            .font(pf(11, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(hex: 0xFA5151)))
                    } else {
                        Text(Tr("预告"))
                            .font(pf(11, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 1, opacity: 0.22)))
                    }
                    if !(r.tag ?? "").isEmpty {
                        Text(r.tag ?? "")
                            .font(pf(11)).foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 0, opacity: 0.35)))
                    }
                    Spacer(minLength: 0)
                    if r.isLive {
                        Text("\(r.watching ?? 0) 人在看")
                            .font(pf(11)).foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(10)
            }
            HStack(spacing: 9) {
                Avatar(path: r.hostAvatar, size: 34, radius: 17, circle: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title ?? "")
                        .font(pf(15, .medium)).foregroundColor(ink).lineLimit(1)
                    Text(r.isLive ? "\(r.hostName) · \(r.hot ?? 0) 热度" : "\(r.hostName) · 待开播")
                        .font(pf(12.5)).foregroundColor(subInk).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }
}

/* ---------------------------------------------------------- 直播间 */

struct LiveRoomView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let room: LiveRoom
    @ObservedObject private var live = LiveCenter.shared

    @State private var danmakus: [(who: String, text: String)] = []
    @State private var draft = ""
    @State private var watching = 0
    @State private var likes = 0
    /// 退出前确认（抖音会问一句）
    @State private var confirmExit = false
    /// 右侧竖排里的礼物面板
    @State private var showGifts = false
    @State private var liveGifts: [Gift] = []
    @State private var hearts: [UUID] = []

    @ObservedObject private var realtime = Realtime.shared

    var body: some View {
        ZStack {
            backdrop
            contentColumn
            rightRail
            videoLayer
            heartsLayer
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        /* 抖音那套：双击屏幕点赞（连点就飘心），退出前问一句 */
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            like()
            popHeart()
        })
        .confirmationDialog(Tr("确定要退出直播吗？"), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(Tr("退出直播"), role: .destructive) { dismiss() }
            Button(Tr("继续观看"), role: .cancel) { }
        }
        /* 礼物面板：抖音那种半屏，点一个就在直播间里送出去 */
        .sheet(isPresented: $showGifts) {
            LiveGiftPanel(gifts: liveGifts,
                          onPick: { g in sendGift(g) },
                          onClose: { showGifts = false })
                .presentationDetents([.height(430)])
                .task { liveGifts = (try? await API.shared.gifts()) ?? [] }
        }
        .onChange(of: realtime.event) { ev in
            guard ev.type == "live", ev.roomId == room.id else { return }
            switch ev.liveAction {
            case "danmaku":
                if !ev.liveText.isEmpty {
                    danmakus.append((ev.liveFrom.isEmpty ? "观众" : ev.liveFrom, ev.liveText))
                    if danmakus.count > 60 { danmakus.removeFirst(danmakus.count - 60) }
                }
            case "count":
                watching = ev.watching
            case "like":
                likes = ev.likes
                popHeart()
            default:
                break
            }
        }
        .task {
            watching = (try? await API.shared.liveJoin(room.id)) ?? 0
            likes = room.likes ?? 0
            danmakus.append(("系统", "欢迎来到「\(room.title ?? "直播间")」，友善聊天哦～"))
            /* 不是我的房间、而且主播在推流 → 自动看画面 */
            let isMine = (room.host?.id ?? "") == (app.me?.id ?? "-")
            if !isMine, let hid = room.host?.id, !hid.isEmpty, room.streaming == true {
                live.startWatch(room: room.id, host: hid)
            }
        }
        .onDisappear {
            live.stopWatch()
            Task { await API.shared.liveLeave(room.id) }
        }
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { confirmExit = true } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 40, height: L.navH)
            }
            .buttonStyle(.plain)
            Avatar(path: room.hostAvatar, size: 30, radius: 15, circle: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.hostName).font(pf(14, .medium)).foregroundColor(.white)
                Text(room.isLive ? "\(watching) 人在看" : "未开播")
                    .font(pf(11.5)).foregroundColor(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            /* 我的房间：给一个开播/结束的按钮 */
            if isMyRoom {
                Button {
                    Task {
                        if live.publishing {
                            live.stopPublish()
                        } else {
                            let ok = await live.startPublish(room: room.id)
                            if !ok { app.show(Tr("要相机和麦克风权限才能开播")) }
                        }
                    }
                } label: {
                    Text(live.publishing ? "结束直播" : "开始直播")
                        .font(pf(13, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(live.publishing ? Color(hex: 0xFA5151) : C.green))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
        .padding(.trailing, 14)
        .frame(height: L.navH)
        .background(Color.black.opacity(0.25))
    }

    private var isMyRoom: Bool { (room.host?.id ?? "") == (app.me?.id ?? "-") }

    /* ----------------------------------------------------------
       下面这几块原来都堆在 body 那个 ZStack 里，加上右侧竖排以后
       Swift 编译器的类型推断直接超时（跑 2 分多钟然后报错）。
       拆成一块一块的，每块都小，编译就正常了。
       ---------------------------------------------------------- */

    /// 背景：拿主播头像糊一层（和通话页一个做法），没有就用深色渐变
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B2233), Color(hex: 0x0C0C0E)],
                           startPoint: .top, endPoint: .bottom)
            if !room.hostAvatar.isEmpty {
                RemoteImage(path: room.hostAvatar).blur(radius: 55).scaleEffect(1.4).opacity(0.6)
            }
        }
        .ignoresSafeArea()
    }

    /// 弹幕那一列 + 底栏
    private var contentColumn: some View {
        VStack(spacing: 0) {
            navBar
            Spacer(minLength: 0)
            danmakuList
            bottomBar
        }
    }

    /// 抖音那种右侧竖排：头像 / 点赞（带数字）/ 礼物 / 分享，贴在输入栏上方
    private var rightRail: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                LiveRightRail(likes: likes,
                              hostAvatar: room.hostAvatar,
                              isMyRoom: isMyRoom,
                              onLike: { like() },
                              onGift: { showGifts = true },
                              onShare: { share() })
            }
            .padding(.trailing, 12)
            .padding(.bottom, 86)
        }
    }

    /// 真视频层：观众看到主播画面；主播看到自己的预览（右下小窗）
    private var videoLayer: some View {
        Group {
            if live.watching, live.remoteVideo != nil {
                VideoSurface(track: live.remoteVideo)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else if live.publishing, live.localVideo != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VideoSurface(track: live.localVideo)
                            .frame(width: 104, height: 148)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.trailing, 14)
                            .padding(.bottom, 120)
                    }
                }
                .allowsHitTesting(false)
            } else if live.watching {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(Tr("正在连主播的画面…")).font(pf(14)).foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    /// 点赞飘心
    private var heartsLayer: some View {
        ForEach(hearts, id: \.self) { id in
            FloatingHeart(id: id)
        }
    }

    private var danmakuList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(danmakus.suffix(9), id: \.text.hashValue) { d in
                HStack(alignment: .top, spacing: 6) {
                    Text(d.who)
                        .font(pf(12.5, .medium))
                        .foregroundColor(Color(hex: 0x7FD3FF))
                    Text(d.text)
                        .font(pf(13))
                        .foregroundColor(.white.opacity(0.95))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.28)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text(Tr("说点什么…")).foregroundColor(.white.opacity(0.5)))
                .font(pf(14))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(Color(white: 1, opacity: 0.14)))
                .onSubmit { send() }
            Button { send() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(C.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, max(10, L.safeBottom))
        .background(Color.black.opacity(0.35))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do { try await API.shared.liveDanmaku(room.id, text: text) }
            catch { app.show((error as? APIError)?.errorDescription ?? "发不出去") }
        }
    }

    private func like() {
        popHeart()
        Task { _ = try? await API.shared.liveLike(room.id) }
    }

    /// 送礼物：先在公屏上喊一句（房间里的人都看得到），余额扣费走礼物自己的接口
    private func sendGift(_ g: Gift) {
        showGifts = false
        let icon = g.icon ?? "🎁"
        let name = g.name ?? "礼物"
        let text = icon + " 送出了「" + name + "」"
        Task {
            do { try await API.shared.liveDanmaku(room.id, text: text) }
            catch { app.show((error as? APIError)?.errorDescription ?? "礼物没送出去") }
        }
    }

    /// 分享：把直播间链接复制走（微信里也是「复制链接」这一套）
    private func share() {
        UIPasteboard.general.string = "https://aa.x8iu.com/live.html?room=" + room.id
        app.show(Tr("直播链接已复制，去聊天里粘贴分享"))
    }

    private func popHeart() {
        let id = UUID()
        hearts.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            hearts.removeAll { $0 == id }
        }
    }
}

/// 点赞飘上去的小心心
struct FloatingHeart: View {
    let id: UUID
    @State private var up = false
    @State private var side: CGFloat = Bool.random() ? 1 : -1

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 22))
            .foregroundColor(Color(hex: 0xFF5A7A))
            .offset(x: L.width / 2 - 46 + (up ? side * 26 : 0), y: up ? -260 : -60)
            .opacity(up ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 1.5)) { up = true }
            }
    }
}

/* ============================================================
   抖音那种右侧竖排：主播头像（带关注 +）/ 点赞（带数字）/ 礼物 / 分享
   单独拎出来写：一来是排版跟抖音对齐，二来是拆小以后编译器不会再卡
   ============================================================ */

struct LiveRightRail: View {
    let likes: Int
    let hostAvatar: String
    let isMyRoom: Bool
    let onLike: () -> Void
    let onGift: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            host
            railButton("heart.fill", "\(likes)", Color(hex: 0xFF5A7A), onLike)
            railButton("gift.fill", Tr("礼物"), Color(hex: 0xFFC740), onGift)
            railButton("arrowshape.turn.up.right.fill", Tr("分享"), .white, onShare)
        }
    }

    /// 主播头像：抖音在底下挂一个红「+」（自己的房间就不挂）
    private var host: some View {
        ZStack(alignment: .bottom) {
            Avatar(path: hostAvatar, size: 44, radius: 22, circle: true)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
            if !isMyRoom {
                Text("+")
                    .font(pf(13, .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color(hex: 0xFA5151)))
                    .offset(y: 7)
            }
        }
        .frame(width: 46, height: 52)
    }

    private func railButton(_ symbol: String,
                            _ label: String,
                            _ color: Color,
                            _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.3)).frame(width: 44, height: 44)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(color)
                }
                Text(label)
                    .font(pf(11))
                    .foregroundColor(.white.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
    }
}

/* ============================================================
   礼物面板（右侧竖排点「礼物」弹出来）：点一个就在房间里送出去
   ============================================================ */

struct LiveGiftPanel: View {
    let gifts: [Gift]
    let onPick: (Gift) -> Void
    let onClose: () -> Void

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("送礼物"), back: onClose)
            if gifts.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(Tr("礼物还在路上…")).font(pf(13)).foregroundColor(C.subLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(gifts) { g in
                            giftCell(g)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(C.pageBg)
    }

    private func giftCell(_ g: Gift) -> some View {
        Button { onPick(g) } label: {
            VStack(spacing: 5) {
                Text(g.icon ?? "🎁").font(pf(30))
                Text(g.name ?? Tr("礼物"))
                    .font(pf(12.5))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Text(priceText(g))
                    .font(pf(11.5))
                    .foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.cardBg))
        }
        .buttonStyle(.plain)
    }

    private func priceText(_ g: Gift) -> String {
        let p = g.price ?? 0
        if p <= 0 { return Tr("免费") }
        return "¥" + String(format: "%.0f", p)
    }
}
