import SwiftUI
import AVKit
import PhotosUI

/* ============================================================
   视频号（发现 → 视频号）—— 抖音式上下刷
     · 一次一屏，手指上滑看下一条（松手吸附，跟手）
     · 右侧动作栏：头像+关注 / ❤️ / 💬 / ↗️
     · 底部：作者 + 文案 + 🎵 音乐名
     · 右上角 ＋ 可以发表自己的视频（从相册选，传到服务器）
   视频列表在服务器的 data/feed.json（后台可改），用户发的会追加进去。
   ============================================================ */

struct FeedAuthor: Decodable, Hashable {
    var id: String?
    var name: String?
    var avatar: String?
}

struct FeedItem: Decodable, Identifiable, Hashable {
    var id: String
    var video: String?
    var cover: String?
    var desc: String?
    var music: String?
    var tag: String?
    var author: FeedAuthor?
    var likes: Int?
    var liked: Bool?
    var comments: Int?
    var shares: Int?
    var mine: Bool?
}

struct ChannelsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [FeedItem] = []
    @State private var index = 0
    /// 视频号顶部 tab：0=关注 1=朋友 2=推荐（默认推荐）
    @State private var tab = 2
    @State private var drag: CGFloat = 0
    @State private var loading = true
    @State private var commentFor: FeedItem?
    @State private var commentText = ""
    @State private var pickOpen = false
    @State private var picked: PhotosPickerItem?
    @State private var uploading = false
    @State private var showPublish = false
    @State private var publishDesc = ""
    @State private var publishMusic = ""
    @State private var pendingVideoPath = ""
    @State private var uploadMB: Double = 0
    @State private var trim = 0          // 0=不处理 1=剪底部10% 2=剪底部14% 3=剪右侧12% 4=剪右下角
    @State private var style = FeedStyle()
    @State private var flags = FeedFlags()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if loading && items.isEmpty {
                    ProgressView().tint(.white)
                } else if items.isEmpty {
                    Text("视频号还没有内容\n去后台 data/feed.json 加，或者点右上角 ＋ 发一条")
                        .font(pf(14)).foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else {
                    /* 三条一组：上一条、当前、下一条，跟着手指上下移动 */
                    ForEach(visible, id: \.item.id) { row in
                        FeedCell(item: row.item,
                                 active: row.offset == 0,
                                 style: style,
                                 flags: flags,
                                 onLike: { toggleLike(row.item) },
                                 onComment: { commentFor = row.item; commentText = "" },
                                 onShare: { share(row.item) },
                                 onFollow: { follow(row.item) },
                                 onDelete: { remove(row.item) })
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(y: CGFloat(row.offset) * geo.size.height + drag)
                    }
                }
                topBar
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard !items.isEmpty else { return }
                        drag = v.translation.height
                    }
                    .onEnded { v in
                        guard !items.isEmpty else { return }
                        let h = geo.size.height
                        let far = abs(v.translation.height) > h * 0.22
                        let fast = abs(v.predictedEndTranslation.height) > h * 0.45
                        if (far || fast), v.translation.height < 0, index < items.count - 1 {
                            withAnimation(.easeOut(duration: 0.22)) { drag = -h }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { index += 1; drag = 0 }
                        } else if (far || fast), v.translation.height > 0, index > 0 {
                            withAnimation(.easeOut(duration: 0.22)) { drag = h }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { index -= 1; drag = 0 }
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) { drag = 0 }
                        }
                    }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .sheet(item: $commentFor) { item in
            commentSheet(item)
        }
        .sheet(isPresented: $showPublish) {
            publishSheet
        }
        .photosPicker(isPresented: $pickOpen, selection: $picked, matching: .videos)
        .onChange(of: picked) { v in Task { await uploadPicked(v) } }
        .overlay(alignment: .center) {
            if uploading {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ProgressView("正在上传视频…").tint(.white).foregroundColor(.white)
                        .padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.7)))
                }
            }
        }
        .task { await load() }
        /* 进视频号就把音频通道设成「播放」：这样手机的静音键拨下去也有声音
           （抖音就是这个行为），离开时再交还，别影响别人听歌。 */
        .onAppear {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? s.setActive(true)
        }
        .onDisappear {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /* ---------------------------------------------------------- 顶部 */

    private var topBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)

                /* 顶部三个 tab（和微信视频号一致）：关注 / 朋友 / 推荐
                   推荐 = 抖音那套（热度+新鲜度，每次刷新顺序会变） */
                HStack(spacing: 22) {
                    ForEach(Array(["关注", "朋友", "推荐"].enumerated()), id: \.offset) { i, name in
                        Button {
                            guard tab != i else { return }
                            tab = i
                            index = 0
                            items = []
                            loading = true
                            Task { await load() }
                        } label: {
                            VStack(spacing: 5) {
                                Text(Tr(name))
                                    .font(pf(tab == i ? 17.5 : 16.5, tab == i ? .semibold : .regular))
                                    .foregroundColor(tab == i ? .white : Color.white.opacity(0.62))
                                Capsule()
                                    .fill(tab == i ? Color.white : Color.clear)
                                    .frame(width: 18, height: 2.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()
                /* 后台把关了「允许前台发视频」就不显示这个 ＋ */
                if flags.allowPublish != false {
                    Button { pickOpen = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            Spacer()
        }
    }

    private struct Row { let item: FeedItem; let offset: Int }
    private var visible: [Row] {
        var out: [Row] = []
        for o in -1...1 {
            let i = index + o
            if i >= 0 && i < items.count { out.append(Row(item: items[i], offset: o)) }
        }
        return out
    }

    /* ---------------------------------------------------------- 数据 */

    private func load() async {
        if let r = try? await API.shared.feed(tab: ["follow", "friends", "recommend"][tab]) {
            items = r.items
            style = r.style
            flags = r.flags
        }
        loading = false
    }

    private func toggleLike(_ item: FeedItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        Task {
            if let r = try? await API.shared.feedLike(item.id) {
                items[i].liked = r.liked
                items[i].likes = r.likes
            }
        }
    }

    private func share(_ item: FeedItem) {
        UIPasteboard.general.string = (item.video ?? "") 
        app.show(Tr("链接已复制，可以去聊天里粘贴"))
    }

    private func follow(_ item: FeedItem) {
        guard let uid = item.author?.id, !uid.isEmpty else { return }
        Task {
            do {
                try await API.shared.addFriend(username: uid)
                app.show(Tr("已发送关注（好友申请）"))
            } catch {
                app.show(Tr("关注失败，可能已经是好友了"))
            }
        }
    }

    private func remove(_ item: FeedItem) {
        Task {
            await API.shared.feedDelete(item.id)
            await load()
            if index >= items.count { index = max(0, items.count - 1) }
        }
    }

    private func sendComment(_ item: FeedItem) {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commentFor = nil
        Task {
            if let n = try? await API.shared.feedComment(item.id, text: text),
               let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i].comments = n
            }
            app.show(Tr("评论成功"))
        }
    }

    private func commentSheet(_ item: FeedItem) -> some View {
        VStack(spacing: 14) {
            Text(Tr("评论")).font(pf(16, .medium)).padding(.top, 16)
            Text(item.desc ?? "").font(pf(13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
            TextField("说点什么…", text: $commentText)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 20)
            Button { sendComment(item) } label: {
                Text(Tr("发送")).font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            Spacer()
        }
        .presentationDetents([.height(260)])
    }

    /* ---------------------------------------------------------- 发表 */

    /// 发表前的小页面：文案、音乐、以及「剪掉水印」
    private var publishSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Tr("发表视频")).font(pf(17, .semibold))
            if uploadMB > 0 {
                Text(String(format: "视频已传好（压缩后 %.1f MB）", uploadMB))
                    .font(pf(12.5)).foregroundColor(.secondary)
            }
            TextField("说点什么…", text: $publishDesc)
                .textFieldStyle(.roundedBorder)
            TextField("音乐名（可留空）", text: $publishMusic)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text(Tr("剪掉水印")).font(pf(14, .medium))
                /* 后台关了「允许剪水印」就直接不显示这一排 */
                if flags.allowTrim != false {
                    Picker("剪掉水印", selection: $trim) {
                        Text(Tr("不处理")).tag(0)
                        Text(Tr("剪底部 10%")).tag(1)
                        Text(Tr("剪底部 14%")).tag(2)
                        Text(Tr("剪右侧 12%")).tag(3)
                        Text(Tr("剪右下角")).tag(4)
                    }
                    .pickerStyle(.segmented)
                }
                Text(Tr("剪完会把画面放大回原尺寸，不会变小 —— 只是把带水印的那一条切掉。"))
                    .font(pf(11.5)).foregroundColor(.secondary)
            }

            Button { publish() } label: {
                Text(Tr("发表")).font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
            }
            .buttonStyle(.plain)
            Button { showPublish = false } label: {
                Text(Tr("取消")).font(pf(15)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .presentationDetents([.height(430)])
    }

    private func uploadPicked(_ v: PhotosPickerItem?) async {
        guard let v = v else { return }
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await v.loadTransferable(type: Data.self), !data.isEmpty else {
                app.show(Tr("读不到这个视频")); return
            }
            /* 画质优先：
               ① ≤25MB 的视频**原样上传**（一点不重编码，画质最高）
               ② 更大的才压，而且压到 **1080p**（以前是 720p，所以看着糊） */
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("feed-raw-\(UUID().uuidString).mov")
            try data.write(to: raw)
            let uploadData: Data
            let mb = Double(data.count) / 1024 / 1024
            /* 发布提速：超过 12MB 就先在手机上压到 1080p（约 4Mbps），
               这样上传体积能砍一半以上；12MB 以内的原样传，省掉重编码那几十秒。 */
            if mb <= 12 {
                uploadData = data
            } else if let small = await Self.compress(raw), !small.isEmpty, small.count < data.count {
                uploadData = small
            } else {
                uploadData = data
            }
            try? FileManager.default.removeItem(at: raw)
            /* 二进制直传：不再 base64（少传 25%） */
            let url = try await API.shared.uploadBinary(uploadData, mime: "video/mp4")
            pendingVideoPath = url
            uploadMB = Double(uploadData.count) / 1024 / 1024
            showPublish = true
        } catch {
            app.show((error as? APIError)?.errorDescription ?? "上传失败（视频别超过 20MB）")
        }
    }

    /// 把视频压成 1080p（H.264，画质优先），返回压缩后的数据；失败返回 nil
    nonisolated static func compress(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        /* 1080p 起步；如果原片本来就不大，用「最高质量」档再保险一点 */
        let preset = AVAssetExportPreset1920x1080
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("feed-out-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
        let d = try? Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)
        return d
    }

    private func publish() {
        let desc = publishDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        let music = publishMusic.trimmingCharacters(in: .whitespacesAndNewlines)
        publishDesc = ""
        publishMusic = ""
        let crop = trim
        showPublish = false
        Task {
            do {
                var video = pendingVideoPath
                if crop > 0 {
                    let area: (top: Double, bottom: Double, left: Double, right: Double)
                    switch crop {
                    case 1: area = (0, 0.10, 0, 0)
                    case 2: area = (0, 0.14, 0, 0)
                    case 3: area = (0, 0, 0, 0.12)
                    default: area = (0, 0.12, 0, 0.10)
                    }
                    if let trimmed = try? await API.shared.feedTrim(video, top: area.top, bottom: area.bottom,
                                                                     left: area.left, right: area.right) {
                        video = trimmed
                    } else {
                        app.show(Tr("剪水印失败，就用原视频发了"))
                    }
                }
                _ = try await API.shared.feedPublish(video: video, desc: desc, music: music)
                app.show(Tr("发表成功"))
                index = 0
                await load()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
        }
        trim = 0
    }
}

/* ---------------------------------------------------------- 单条视频 */

struct FeedCell: View {
    let item: FeedItem
    let active: Bool
    var style = FeedStyle()
    var flags = FeedFlags()
    var onLike: () -> Void
    var onComment: () -> Void
    var onShare: () -> Void
    var onFollow: () -> Void
    var onDelete: () -> Void

    @State private var player: AVPlayer?
    @State private var loadingVideo = true
    @State private var liked = false
    @State private var likes = 0
    @State private var bounced = false

    var body: some View {
        ZStack {
            Color.black
            if !(item.cover ?? "").isEmpty {
                RemoteImage(path: item.cover ?? "").opacity(player == nil ? 1 : 0.001)
            }
            if let p = player {
                PlayerSurface(player: p)
            }
            if loadingVideo {
                ProgressView().tint(.white)
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)

            if flags.showRail != false {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer()
                    rightRail
                }
                .padding(.trailing, 12)
                .padding(.bottom, 110)
            }

            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text("@\(item.author?.name ?? "用户")")
                    .font(pf(style.nameSize ?? 16, .semibold)).foregroundColor(.white)
                Text(item.desc ?? "")
                    .font(pf(style.descSize ?? 14)).foregroundColor(.white.opacity(0.95))
                    .lineLimit(3)
                HStack(spacing: 5) {
                    Image(systemName: "music.note").font(.system(size: 12))
                    Text(item.music?.isEmpty == false ? (item.music ?? "") : "原创声音")
                        .font(pf(style.musicSize ?? 12.5))
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, max(style.padBottom ?? 28, L.safeBottom + 10))
        }
        .onAppear { setup() }
        .onDisappear { player?.pause() }
        .onChange(of: active) { on in
            if on { player?.play() } else { player?.pause(); player?.seek(to: .zero) }
        }
    }

    private var rightRail: some View {
        VStack(spacing: style.railGap ?? 20) {
            ZStack(alignment: .bottom) {
                Avatar(path: item.author?.avatar ?? "", size: style.avatar ?? 46,
                       radius: (style.avatar ?? 46) / 2, circle: true)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                Button { onFollow() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(hex: 0xFA5151)))
                        .offset(y: 9)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)

            railButton(icon: "heart.fill", tint: liked ? Color(hex: 0xFF4D6D) : .white,
                       text: "\(likes)") {
                liked.toggle()
                likes += liked ? 1 : -1
                bounced = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { bounced = false }
                onLike()
            }
            railButton(icon: "bubble.right.fill", tint: .white, text: "\(item.comments ?? 0)", action: onComment)
            railButton(icon: "arrowshape.turn.up.right.fill", tint: .white,
                       text: "\(item.shares ?? 0)", action: onShare)
            if item.mine == true {
                railButton(icon: "trash.fill", tint: .white, text: "删除", action: onDelete)
            }
        }
    }

    private func railButton(icon: String, tint: Color, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: style.railIcon ?? 27))
                    .foregroundColor(tint)
                    .scaleEffect(bounced && icon == "heart.fill" ? 1.25 : 1)
                Text(text).font(pf(12.5, .medium)).foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func setup() {
        liked = item.liked ?? false
        likes = item.likes ?? 0
        guard player == nil, let url = API.shared.assetURL(item.video ?? "") else { return }
        /* 边下边播：把鉴权头交给 AVPlayer，它自己用 Range 分片拉流。
           以前是「先整包下载到本地再播」，一条 5MB 视频要等 20 多秒才出画面。 */
        Task { @MainActor in
            do {
                let asset = API.shared.streamingAsset(item.video ?? "") ?? AVURLAsset(url: url)
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                p.isMuted = false
                p.actionAtItemEnd = .none
                p.automaticallyWaitsToMinimizeStalling = false
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: p.currentItem, queue: .main) { _ in
                    p.seek(to: .zero)
                    p.play()
                }
                player = p
                loadingVideo = false
                if active { p.play() }
            } catch {
                loadingVideo = false
            }
        }
    }
}

/// AVPlayer 的显示层（通话页那个 VideoSurface 是给 WebRTC 用的，这里是本地播放器）
/// 「作品」页点开一个方块后播这条视频（和视频号一样：先下载到本地再播）
struct FeedPlayerSheet: View {
    let item: FeedItem
    var all: [FeedItem] = []

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var liked = false
    @State private var likes = 0
    @State private var index = 0

    private var list: [FeedItem] { all.isEmpty ? [item] : all }
    private var cur: FeedItem { list[min(index, list.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player { PlayerSurface(player: p) }
            if loading { ProgressView().tint(.white) }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 8)
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("@\(cur.author?.name ?? "用户")")
                            .font(pf(15, .semibold)).foregroundColor(.white)
                        Text(cur.desc ?? "").font(pf(13.5)).foregroundColor(.white.opacity(0.95))
                            .lineLimit(3)
                        if !(cur.music ?? "").isEmpty {
                            Text("♪ \(cur.music ?? "")").font(pf(12)).foregroundColor(.white.opacity(0.8))
                        }
                    }
                    Spacer(minLength: 12)
                    Button {
                        liked.toggle(); likes += liked ? 1 : -1
                        Task { _ = try? await API.shared.feedLike(cur.id) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 26))
                                .foregroundColor(liked ? Color(hex: 0xFF4D6D) : .white)
                            Text("\(likes)").font(pf(12.5)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(20, L.safeBottom + 8))
            }
            /* 左右切换（作品页点开的那个列表） */
            if list.count > 1 {
                HStack {
                    Button { step(-1) } label: { chevron("chevron.left") }
                    Spacer()
                    Button { step(1) } label: { chevron("chevron.right") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .onAppear {
            index = list.firstIndex(where: { $0.id == item.id }) ?? 0
            liked = cur.liked ?? false
            likes = cur.likes ?? 0
            load(cur)
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 44, height: 60)
    }

    private func step(_ d: Int) {
        let n = index + d
        guard n >= 0, n < list.count else { return }
        index = n
        liked = cur.liked ?? false
        likes = cur.likes ?? 0
        player?.pause()
        player = nil
        load(cur)
    }

    private func load(_ w: FeedItem) {
        guard let url = API.shared.assetURL(w.video ?? "") else { loading = false; return }
        loading = true
        Task { @MainActor in
            do {
                let asset = API.shared.streamingAsset(w.video ?? "") ?? AVURLAsset(url: url)
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                p.actionAtItemEnd = .none
                p.automaticallyWaitsToMinimizeStalling = false
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: p.currentItem, queue: .main) { _ in
                    p.seek(to: .zero); p.play()
                }
                player = p
                loading = false
                p.play()
            } catch { loading = false }
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        v.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
