import SwiftUI
import CoreLocation
import UIKit

/* ============================================================
   附近的人（发现 → 附近）
   页面照桌面 vx 文件夹那张参考图量的（420×912pt 的截图）：
     · 整页深色：页面 #111111、每一行 #191919、行与行之间没有分割线
     · 行高 65pt；头像 46×46、左边距 8pt（圆角 5）
     · 头像右边 13pt 起是两行字：第一行名字（17pt 白）、第二行距离（14pt 灰「500米以内」）
     · 个性签名灰色，右对齐到右边距 16pt（最多两行）
     · 顶部：‹ 返回 + 居中「附近的人」+ 右侧 ⋯（筛选/刷新/清除位置都在 ⋯ 里）
   功能：进来先定位并上报（半小时有效），按距离排；可筛性别、可打招呼。
   ============================================================ */

/// 定位：要一次「使用期间」权限，拿到一次坐标就够（不用一直跟）
final class NearbyLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lat: Double?
    @Published var lng: Double?
    @Published var denied = false
    @Published var asking = false

    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch mgr.authorizationStatus {
        case .denied, .restricted:
            denied = true
        case .notDetermined:
            asking = true
            mgr.requestWhenInUseAuthorization()
        default:
            mgr.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            switch m.authorizationStatus {
            case .denied, .restricted:
                self.denied = true
                self.asking = false
            case .notDetermined:
                self.asking = true
            default:
                self.asking = false
                self.denied = false
                m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            self.lat = loc.coordinate.latitude
            self.lng = loc.coordinate.longitude
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }
}

struct NearbyPageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loc = NearbyLocator()

    @State private var people: [NearbyPerson] = []
    @State private var loading = false
    @State private var tip = ""
    /// all / female / male —— 和微信 ⋯ 里那三个选项一样
    @State private var filter = "all"
    @State private var showMenu = false
    /// 现在看多大的范围（默认 5 公里；5 公里没人可以点「扩大范围」）
    @State private var maxKm: Double = 5
    /// 20 公里内有几个人（用来提示「扩大范围」）
    @State private var wider = 0

    @State private var helloFor: NearbyPerson?
    @State private var helloText = "你好呀，我是在附近的人里看到你的"
    @State private var cardUser: User?

    /* 参考图里的颜色（深色页面，不走全局主题） */
    private let pageBg = Color(hex: 0x111111)
    private let rowBg = Color(hex: 0x191919)
    private let nameInk = Color.white
    private let subInk = Color(hex: 0x929292)

    private var filterTitle: String {
        switch filter {
        case "female": return "只看女生"
        case "male": return "只看男生"
        default: return "全部"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏：照参考图，深色 + 居中标题 + 右侧 ⋯ */
            ZStack {
                Text(Tr("附近的人"))
                    .font(pf(17, .semibold))
                    .foregroundColor(nameInk)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(nameInk)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { showMenu = true } label: {
                        Text("⋯")
                            .font(pf(22))
                            .foregroundColor(nameInk)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: L.navH)
            .background(pageBg)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if loc.denied {
                        hint("需要定位权限才能看到附近的人\n去「设置 → CHRIS聊天 → 位置」打开", showSetting: true)
                    } else if loading && people.isEmpty {
                        ProgressView().tint(.white).padding(.top, 70)
                    } else if people.isEmpty {
                        VStack(spacing: 12) {
                            hint(tip.isEmpty
                                 ? "\(Int(maxKm)) 公里内还没有其他人\n（对方也要打开「附近的人」，并且就在你附近）"
                                 : tip, showSetting: false)
                            if tip.isEmpty && maxKm < 20 {
                                if wider > 0 {
                                    Button("扩大到 20 公里（有 \(wider) 人）") {
                                        maxKm = 20
                                        Task { await reload(force: true) }
                                    }
                                    .font(pf(15))
                                    .foregroundColor(C.green)
                                } else {
                                    Text(Tr("20 公里内也没有人"))
                                        .font(pf(13))
                                        .foregroundColor(subInk.opacity(0.7))
                                }
                            }
                        }
                    } else {
                        ForEach(people) { p in
                            personRow(p)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea(edges: .bottom))
        .background(pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 和微信一样：从左边缘往右一滑就回上一页（别的二级页都挂了这一个） */
        .swipeBack { dismiss() }
        .navigationDestination(isPresented: Binding(
            get: { cardUser != nil },
            set: { if !$0 { cardUser = nil } }
        )) {
            if let u = cardUser {
                ContactCardView(user: u, onOpenChat: { _ in cardUser = nil }, onOpenMoments: { _ in cardUser = nil })
            }
        }
        .confirmationDialog("", isPresented: $showMenu, titleVisibility: .hidden) {
            Button(Tr("全部")) { setFilter("all") }
            Button(Tr("只看女生")) { setFilter("female") }
            Button(Tr("只看男生")) { setFilter("male") }
            Button(Tr("刷新")) { Task { await reload(force: true) } }
            Button(Tr("清除位置信息并退出"), role: .destructive) { clearLocation() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .alert("打招呼", isPresented: Binding(
            get: { helloFor != nil },
            set: { if !$0 { helloFor = nil } }
        )) {
            TextField("说点什么…", text: $helloText)
            Button(Tr("发送")) { sendHello() }
            Button(Tr("取消"), role: .cancel) { helloFor = nil }
        } message: {
            Text("给 \(helloFor?.name ?? "") 发一条消息")
        }
        .task {
            loc.start()
            await reload(force: true)
        }
        .onChange(of: loc.lat) { _ in Task { await reload(force: true) } }
    }

    /* ---------------------------------------------------------- 一行（照参考图） */

    private func personRow(_ p: NearbyPerson) -> some View {
        Button {
            helloFor = p
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Avatar(path: p.avatar ?? "", size: 46, radius: 5)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(pf(17))
                        .foregroundColor(nameInk)
                        .lineLimit(1)
                    Text(p.distanceText)
                        .font(pf(14))
                        .foregroundColor(subInk)
                        .lineLimit(1)
                }
                .padding(.top, 1)

                Spacer(minLength: 8)

                if !signature(p).isEmpty {
                    Text(signature(p))
                        .font(pf(13.5))
                        .foregroundColor(subInk)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .padding(.top, 3)
                }
            }
            .padding(.trailing, 16)
            .frame(height: 65, alignment: .top)
            .background(rowBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { openCard(p) } label: {
                Label(Tr("查看资料"), systemImage: "person.text.rectangle")
            }
        }
    }

    /// 右边那列灰字：优先个性签名，其次简介；好友就直接写「已经是好友」
    private func signature(_ p: NearbyPerson) -> String {
        if let m = p.moodText, !m.isEmpty { return m }
        if let b = p.bio, !b.isEmpty { return b }
        if p.friend == true { return "已经是好友" }
        return ""
    }

    private func hint(_ text: String, showSetting: Bool) -> some View {
        VStack(spacing: 10) {
            Text(text)
                .font(pf(14))
                .foregroundColor(subInk)
                .multilineTextAlignment(.center)
            if showSetting {
                Button(Tr("去设置里打开")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(pf(15))
                .foregroundColor(C.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /* ---------------------------------------------------------- 数据 */

    private func setFilter(_ f: String) {
        filter = f
        Task { await reload(force: true) }
    }

    private func reload(force: Bool) async {
        if loading && !force { return }
        loading = true
        defer { loading = false }
        do {
            /* 有定位就先上报（进这个页面等于「我在附近」） */
            if let la = loc.lat, let ln = loc.lng {
                try? await API.shared.nearbyReport(lat: la, lng: ln)
            }
            let r = try await API.shared.nearby(lat: loc.lat, lng: loc.lng, gender: filter, maxKm: maxKm)
            people = r.people
            wider = r.wider
            tip = ""
        } catch {
            tip = (error as? APIError)?.errorDescription ?? "加载失败"
        }
    }

    private func clearLocation() {
        Task {
            try? await API.shared.nearbyClear()
            people = []
            app.show(Tr("已清除位置信息"))
            dismiss()
        }
    }

    private func sendHello() {
        guard let p = helloFor else { return }
        let text = helloText.trimmingCharacters(in: .whitespacesAndNewlines)
        let say = text.isEmpty ? "你好呀，我是在附近的人里看到你的" : text
        helloFor = nil
        Task {
            do {
                _ = try await API.shared.nearbyHello(userId: p.id, text: say)
                app.show(Tr("已打招呼"))
                await app.loadChats()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
        }
    }

    private func openCard(_ p: NearbyPerson) {
        Task {
            if let u = try? await API.shared.user(id: p.id) { cardUser = u }
        }
    }
}
