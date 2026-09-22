import SwiftUI
import MapKit
import CoreLocation

/* ============================================================
   位置（微信「＋ → 位置」那一套）
   · SendLocationView：发送位置 —— 地图上定我的位置，下面列出附近的地点，点一个就发出去
   · LiveLocationView：共享实时位置 —— 一个会话里几个人同时在地图上，
     每 5 秒上报一次自己的位置，别人动你会实时看到；点「停止共享」大家一起结束
   ============================================================ */

/// 共享实时位置的状态：谁在里面、都在哪（收到长连接推送就更新这儿）
final class LiveLocationStore: ObservableObject {
    static let shared = LiveLocationStore()

    struct Peer: Identifiable {
        var id: String
        var name: String
        var avatar: String
        var lat: Double
        var lng: Double
    }

    @Published var sessionId = ""
    @Published var chatId = ""
    @Published var active = false
    @Published var peers: [Peer] = []

    func reset() {
        sessionId = ""
        chatId = ""
        active = false
        peers = []
    }

    func apply(sessionId: String, members: [API.LiveMember]) {
        self.sessionId = sessionId
        active = true
        var list: [Peer] = []
        for m in members {
            guard let lat = m.lat, let lng = m.lng else { continue }
            list.append(Peer(id: m.userId, name: m.name ?? "",
                             avatar: m.avatar ?? "", lat: lat, lng: lng))
        }
        peers = list
    }

    func upsert(userId: String, name: String, avatar: String, lat: Double, lng: Double) {
        if let i = peers.firstIndex(where: { $0.id == userId }) {
            peers[i].lat = lat
            peers[i].lng = lng
            if !name.isEmpty { peers[i].name = name }
        } else {
            peers.append(Peer(id: userId, name: name, avatar: avatar, lat: lat, lng: lng))
        }
    }
}

/* ---------------------------------------------------------- 发送位置 */

struct SendLocationView: View {
    var onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    @State private var myLat = 0.0
    @State private var myLng = 0.0
    @State private var places: [(String, String, Double, Double)] = []
    @State private var loading = true
    @State private var picked = 0
    @State private var denied = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("发送位置"), back: { dismiss() }) {
                Button {
                    send()
                } label: {
                    Text(Tr("发送"))
                        .font(pf(17, .semibold))
                        .foregroundColor(places.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(places.isEmpty)
            }

            Map(coordinateRegion: $region, showsUserLocation: true,
                annotationItems: places.enumerated().map { IndexedPlace(index: $0.offset, name: $0.element.0,
                                                                       lat: $0.element.2, lng: $0.element.3) }) { p in
                MapMarker(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                          tint: p.index == picked ? C.green : .red)
            }
            .frame(height: 240)

            if loading {
                HStack { Spacer(); ProgressView(Tr("正在定位…")); Spacer() }
                    .frame(height: 70)
            } else if denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "location.slash").foregroundColor(C.subLabel)
                        Text(Tr("定位没开：点这里去设置里打开「位置」"))
                            .font(pf(14.5)).foregroundColor(C.link)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(C.cardBg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(places.indices, id: \.self) { i in
                        let p = places[i]
                        Button {
                            picked = i
                            region.center = CLLocationCoordinate2D(latitude: p.2, longitude: p.3)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(i == picked ? C.green : C.subLabel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.0).font(pf(16)).foregroundColor(C.label).lineLimit(1)
                                    if !p.1.isEmpty {
                                        Text(p.1).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if i == picked {
                                    Image(systemName: "checkmark").foregroundColor(C.green)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(C.cardBg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                    }
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await locate() }
    }

    private struct IndexedPlace: Identifiable {
        var id: Int { index }
        var index: Int
        var name: String
        var lat: Double
        var lng: Double
    }

    private func locate() async {
        guard let loc = await OneShotLocation.shared.current() else {
            /* 定位失败 / 没给权限：直接告诉用户去开，不再瞎给一个坐标 */
            places = []
            denied = true
            loading = false
            return
        }
        myLat = loc.coordinate.latitude
        myLng = loc.coordinate.longitude
        region.center = loc.coordinate
        var list: [(String, String, Double, Double)] = []
        if let marks = try? await CLGeocoder().reverseGeocodeLocation(loc) {
            for m in marks.prefix(6) {
                let name = m.name ?? m.locality ?? Tr("我的位置")
                let addr = [m.locality, m.subLocality, m.thoroughfare, m.subThoroughfare]
                    .compactMap { $0 }.joined(separator: " ")
                list.append((name, addr, loc.coordinate.latitude, loc.coordinate.longitude))
            }
        }
        if list.isEmpty { list.append((Tr("我的位置"), "", myLat, myLng)) }
        places = list
        loading = false
    }

    private func send() {
        guard places.indices.contains(picked) else { return }
        let p = places[picked]
        let payload = "{\"lat\":\(p.2),\"lng\":\(p.3),\"name\":\"\(p.0)\",\"addr\":\"\(p.1)\"}"
        onSend(payload)
        dismiss()
    }
}

/* ---------------------------------------------------------- 共享实时位置 */

struct LiveLocationView: View {
    let chat: Chat
    var onStop: (() -> Void)? = nil

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveLocationStore.shared

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    @State private var timer: Task<Void, Never>?
    @State private var hint = ""

    private var peers: [LiveLocationStore.Peer] { store.peers }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("共享实时位置"), back: { stopAndClose() })

            Map(coordinateRegion: $region, showsUserLocation: true,
                annotationItems: peers) { p in
                MapMarker(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                          tint: p.id == app.me?.id ? C.green : .red)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(store.active ? C.green : C.subLabel).frame(width: 8, height: 8)
                    Text(store.active ? Tr("正在共享实时位置") : Tr("共享已结束"))
                        .font(pf(15)).foregroundColor(C.label)
                    Spacer()
                    Text("\(peers.count) " + Tr("个人在共享"))
                        .font(pf(13)).foregroundColor(C.subLabel)
                }
                if !peers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(peers) { p in
                                HStack(spacing: 6) {
                                    Avatar(path: p.avatar, size: 26, radius: 13, circle: true)
                                    Text(p.name).font(pf(13)).foregroundColor(C.label)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 17).fill(C.cardBg))
                            }
                        }
                    }
                }
                if !hint.isEmpty {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "location.slash")
                            Text(hint).font(pf(13))
                            Text(Tr("去设置")).font(pf(13, .medium)).foregroundColor(C.link)
                        }
                        .foregroundColor(C.subLabel)
                    }
                    .buttonStyle(.plain)
                }
                Button { stopAndClose() } label: {
                    Text(Tr("停止共享"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(C.red))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .task { await start() }
        .onDisappear { timer?.cancel() }
    }

    private func start() async {
        guard let loc = await OneShotLocation.shared.current() else {
            hint = Tr("没给定位权限，先去 设置 → Luchat → 位置 打开")
            return
        }
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        region.center = loc.coordinate
        if let r = await API.shared.liveStart(chatId: chat.id, lat: lat, lng: lng) {
            store.sessionId = r.sessionId
            store.chatId = chat.id
            store.active = true
            if !r.joined { onStop?() }        // 是我发起的：往聊天里留一条
        }
        await pushState()
        /* 每 5 秒报一次我的位置（和微信一样，动一下对方就能看到） */
        timer?.cancel()
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await reportMyPosition()
                await pushState()          // 顺便把别人的位置也拉一遍（对方动了几秒内就能看到）
            }
        }
    }

    private func pushState() async {
        guard !store.sessionId.isEmpty else { return }
        if let s = await API.shared.liveState(sessionId: store.sessionId) {
            store.apply(sessionId: s.sessionId, members: s.members)
            if let me = s.members.first(where: { $0.userId == app.me?.id }),
               let lat = me.lat, let lng = me.lng {
                region.center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }
    }

    private func reportMyPosition() async {
        guard store.active, !store.sessionId.isEmpty else { return }
        guard let loc = await OneShotLocation.shared.current() else { return }
        await API.shared.livePos(sessionId: store.sessionId,
                                 lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
        store.upsert(userId: app.me?.id ?? "", name: app.me?.name ?? "",
                     avatar: app.me?.avatarPath ?? "",
                     lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
    }

    private func stopAndClose() {
        timer?.cancel()
        Task {
            if !store.sessionId.isEmpty {
                await API.shared.liveStop(sessionId: store.sessionId)
            }
            store.reset()
        }
        dismiss()
    }
}
