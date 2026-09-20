import SwiftUI
import CoreLocation
import UIKit

/* ============================================================
   附近的人（发现 → 附近）
   —— 进来先定位、把位置报到服务器，再拉名单：按距离排，能筛性别、能打招呼。
      微信的逻辑：要自己进过这个页面、并且半小时内报过位置，才会出现在别人名单里。
   位置只保存在服务器的 data/nearby.json，半小时自动过期清掉；可隐身。
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
    /// all / female / male —— 和微信那三个选项一样
    @State private var filter = "all"

    @State private var helloFor: NearbyPerson?
    @State private var helloText = "你好呀，我是在附近的人里看到你的"
    @State private var cardUser: User?
    @State private var busy = false

    private let filters: [(String, String)] = [("all", "全部"), ("female", "只看女生"), ("male", "只看男生")]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "附近的人", back: { dismiss() }) {
                Button {
                    Task { await reload(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }

            /* 筛选：全部 / 只看女生 / 只看男生 */
            HStack(spacing: 8) {
                ForEach(filters, id: \.0) { f in
                    Button {
                        filter = f.0
                        Task { await reload(force: false) }
                    } label: {
                        Text(f.1)
                            .font(pf(14))
                            .foregroundColor(filter == f.0 ? .white : C.label)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(filter == f.0 ? C.green : C.cardBg))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(C.pageBg)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if loc.denied {
                        hint("需要定位权限才能看到附近的人\n去「设置 → CHRIS聊天 → 位置」打开")
                    } else if loading && people.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if people.isEmpty {
                        hint(tip.isEmpty ? "附近还没有人\n（让对方也进一次「附近的人」）" : tip)
                    } else {
                        ForEach(people) { p in
                            personRow(p)
                            HairLine(inset: 76)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .navigationDestination(isPresented: Binding(
            get: { cardUser != nil },
            set: { if !$0 { cardUser = nil } }
        )) {
            if let u = cardUser {
                ContactCardView(user: u, onOpenChat: { _ in cardUser = nil }, onOpenMoments: { _ in cardUser = nil })
            }
        }
        .alert("打招呼", isPresented: Binding(
            get: { helloFor != nil },
            set: { if !$0 { helloFor = nil } }
        )) {
            TextField("说点什么…", text: $helloText)
            Button("发送") { sendHello() }
            Button("取消", role: .cancel) { helloFor = nil }
        } message: {
            Text("给 \(helloFor?.name ?? "") 发一条消息")
        }
        .task {
            loc.start()
            await reload(force: true)
        }
        .onChange(of: loc.lat) { _ in Task { await reload(force: true) } }
    }

    /* ---------------------------------------------------------- 一行 */

    private func personRow(_ p: NearbyPerson) -> some View {
        Button {
            helloFor = p
        } label: {
            HStack(spacing: 12) {
                Avatar(path: p.avatar ?? "", size: 48, radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(p.name)
                            .font(pf(16))
                            .foregroundColor(C.name)
                            .lineLimit(1)
                        Image(systemName: p.isFemale ? "female" : "male")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(p.isFemale ? Color(hex: 0xFA7FA8) : Color(hex: 0x4C9AFF))
                    }
                    Text(signature(p))
                        .font(pf(13))
                        .foregroundColor(C.preview)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(p.distanceText)
                        .font(pf(13))
                        .foregroundColor(C.label)
                    Text(p.timeText)
                        .font(pf(12))
                        .foregroundColor(C.time)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openCard(p)
            } label: {
                Label("查看资料", systemImage: "person.text.rectangle")
            }
            if let m = p.moments, m > 0 {
                Text("朋友圈 \(m) 条")
            }
        }
    }

    private func signature(_ p: NearbyPerson) -> String {
        if let m = p.moodText, !m.isEmpty { return m }
        if let b = p.bio, !b.isEmpty { return b }
        if let r = p.region, !r.isEmpty { return r }
        return p.friend == true ? "已经是好友" : "打个招呼吧"
    }

    private func hint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(pf(14))
                .foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
            if loc.denied {
                Button("去设置里打开") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(pf(15))
                .foregroundColor(C.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    /* ---------------------------------------------------------- 数据 */

    private func reload(force: Bool) async {
        if loading && !force { return }
        loading = true
        defer { loading = false }
        do {
            /* 有定位就先上报（进这个页面等于「我在附近」） */
            if let la = loc.lat, let ln = loc.lng {
                try? await API.shared.nearbyReport(lat: la, lng: ln)
            }
            people = try await API.shared.nearby(lat: loc.lat, lng: loc.lng, gender: filter)
            tip = ""
        } catch {
            tip = (error as? APIError)?.errorDescription ?? "加载失败，下拉重试"
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
                app.show("已打招呼")
                await app.loadChats()
                await app.refreshAll()
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
