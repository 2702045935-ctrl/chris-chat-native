import SwiftUI
import AVFoundation
import UIKit

/* ============================================================
   视频号「抖音版」全屏播放页
   · 一屏一条、上下滑切换（用系统分页容器，iOS 16 也能用）
   · 滑到哪条自动播、其它自动停；播完循环；点一下暂停/继续
   · **播放器池**：只给「当前 / 上一条 / 下一条」建播放器，滑过去立刻有画面 ——
     每滑一次新建播放器正是卡的根源，这里复用它
   · 素材仍然是服务端切好的 HLS（800kbps），所以起播快、流量小
   ============================================================ */

struct FeedPlayerView: View {
    let items: [FeedItem]
    var start: Int = 0

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var paused = false
    @State private var progress: Double = 0
    @State private var showHeart = false

    init(items: [FeedItem], start: Int = 0) {
        self.items = items
        self.start = start
        _index = State(initialValue: max(0, min(start, max(0, items.count - 1))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                Text(Tr("还没有视频")).foregroundColor(.white)
            } else {
                VerticalPager(index: $index, count: items.count) { i in
                    PlayerPage(item: items[i],
                               active: (i == index),
                               paused: paused,
                               onTap: { paused.toggle() },
                               onDoubleTap: { like(items[i]); showHeart = true
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showHeart = false } },
                               progress: (i == index) ? progress : 0)
                }
                .ignoresSafeArea()
            }

            if showHeart {
                Image(systemName: "heart.fill")
                    .font(.system(size: 110))
                    .foregroundColor(.white.opacity(0.85))
                    .transition(.scale.combined(with: .opacity))
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.28)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .task(id: index) {
            /* 只保留「当前 / 上一条 / 下一条」的播放器：滑得再多也不会越积越卡（内存和缓冲都省） */
            let lo = max(0, index - 1), hi = min(items.count - 1, index + 1)
            if lo <= hi { PlayerPool.shared.keepOnly(Array(items[lo...hi]).map { $0.id }) }
            await trackProgress()
        }
    }

    private func like(_ item: FeedItem) {
        Task { _ = try? await API.shared.feedLike(itemId: item.id) }
    }

    /// 底部进度条：每 0.25 秒读一次当前页的播放进度
    private func trackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            progress = PlayerPool.shared.progress(of: items[safe: index]?.id ?? "")
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { (i >= 0 && i < count) ? self[i] : nil }
}

/* ---------------------------------------------------------- 播放器池 */

/// 全局播放器池：只保留「当前 / 上一条 / 下一条」三个，多余的销毁。
/// 这样上下滑都是「复用已经在缓冲的播放器」，不会每滑一次重新建、重新缓冲（那就是卡）。
final class PlayerPool {
    static let shared = PlayerPool()
    private var players: [String: AVPlayer] = [:]      // itemId -> player
    private var urls: [String: URL] = [:]

    func player(for item: FeedItem) -> AVPlayer? {
        let key = item.id
        if let p = players[key] { return p }
        let raw = item.playPath
        guard !raw.isEmpty, let u = URL(string: raw.hasPrefix("http") ? raw : API.shared.base + raw) else { return nil }
        let p = AVPlayer(url: u)
        p.actionAtItemEnd = .none
        p.automaticallyWaitsToMinimizeStalling = false
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                              object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        players[key] = p
        urls[key] = u
        return p
    }

    func play(_ item: FeedItem) {
        guard let p = player(for: item) else { return }
        if p.timeControlStatus != .playing { p.play() }
    }

    func pause(_ item: FeedItem) {
        players[item.id]?.pause()
    }

    func progress(of id: String) -> Double {
        guard let p = players[id], let it = p.currentItem else { return 0 }
        let total = CMTimeGetSeconds(it.duration)
        guard total.isFinite, total > 0 else { return 0 }
        return max(0, min(1, CMTimeGetSeconds(p.currentTime()) / total))
    }

    /// 只留这些（当前 ± 1），其余释放 —— 避免越刷越占内存
    func keepOnly(_ ids: [String]) {
        for (k, p) in players where !ids.contains(k) {
            p.pause()
            p.replaceCurrentItem(with: nil)
            players.removeValue(forKey: k)
            urls.removeValue(forKey: k)
        }
    }
}

/* ---------------------------------------------------------- 单页 */

private struct PlayerPage: View {
    let item: FeedItem
    let active: Bool
    let paused: Bool
    var onTap: () -> Void = { }
    var onDoubleTap: () -> Void = { }
    var progress: Double = 0

    var body: some View {
        ZStack {
            /* 封面先铺上（已经在缓存里），再盖播放画面 —— 所以滑过去不会白屏 */
            if let c = item.cover, !c.isEmpty {
                RemoteImage(path: c, mode: .fill, maxSide: 1600)
                    .ignoresSafeArea()
            }
            PlayerLayerView(player: PlayerPool.shared.player(for: item))
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.author?.name ?? "")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                        Text(item.desc ?? "")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(2)
                            .padding(.trailing, 60)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
            }

            /* 底部进度条（抖音那种：细细一条贴着底） */
            VStack {
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25)).frame(height: 2)
                        Rectangle().fill(Color.white).frame(width: max(0, geo.size.width * progress), height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.bottom, 3)
            }

            if paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .onAppear { if active { PlayerPool.shared.play(item) } }
        .onChange(of: active) { a in
            if a { PlayerPool.shared.play(item) } else { PlayerPool.shared.pause(item) }
        }
        .onChange(of: paused) { p in
            if p { PlayerPool.shared.pause(item) } else if active { PlayerPool.shared.play(item) }
        }
    }
}

/// 一层 AVPlayerLayer（SwiftUI 里用它显示画面）
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .black
        let l = v.layer as? AVPlayerLayer
        l?.player = player
        l?.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        let l = v.layer as? AVPlayerLayer
        if l?.player !== player { l?.player = player }
    }
}

/* ---------------------------------------------------------- 竖向分页容器（iOS 16 可用） */

struct VerticalPager<Content: View>: UIViewControllerRepresentable {
    @Binding var index: Int
    let count: Int
    let content: (Int) -> Content

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical, options: nil)
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.setViewControllers([context.coordinator.host(index)], direction: .forward, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.current != index, let target = context.coordinator.host(index) as UIViewController? {
            let dir: UIPageViewController.NavigationDirection = index > context.coordinator.current ? .forward : .reverse
            vc.setViewControllers([target], direction: dir, animated: true)
            context.coordinator.current = index
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalPager
        var current: Int = 0
        /// 每个托管页面对应的下标（滑完靠它认出当前是哪一条）
        private var map: [ObjectIdentifier: Int] = [:]
        init(_ p: VerticalPager) { parent = p; current = p.index }

        func host(_ i: Int) -> UIHostingController<AnyView> {
            let vc = UIHostingController(rootView: AnyView(parent.content(i)))
            map[ObjectIdentifier(vc)] = i
            return vc
        }

        func pageViewController(_ vc: UIPageViewController, viewControllerBefore v: UIViewController) -> UIViewController? {
            guard let i = map[ObjectIdentifier(v)], i > 0 else { return nil }
            return host(i - 1)
        }
        func pageViewController(_ vc: UIPageViewController, viewControllerAfter v: UIViewController) -> UIViewController? {
            guard let i = map[ObjectIdentifier(v)], i + 1 < parent.count else { return nil }
            return host(i + 1)
        }
        func pageViewController(_ vc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let v = vc.viewControllers?.first,
                  let i = map[ObjectIdentifier(v)] else { return }
            current = i
            parent.index = i
        }
    }
}
