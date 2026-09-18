import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()
    @ObservedObject private var realtime = Realtime.shared

    private var latestThumb: String {
        for m in app.moments {
            if let img = m.images?.first, !img.isEmpty { return img }
        }
        return ""
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: "发现")
                    .measure("discover.nav")
                ScrollView {
                    VStack(spacing: 0) {
                        GroupCard {
                            MenuRow(icon: I.moments,
                                    iconColor: Color(hex: 0x4A90D9),
                                    title: "朋友圈",
                                    badge: !latestThumb.isEmpty,
                                    thumb: latestThumb,
                                    onTap: { path.append("moments") })
                        }
                        GroupGap()

                        GroupCard {
                            MenuRow(icon: I.channels, iconColor: Color(hex: 0xF2943B),
                                    title: "视频号", onTap: { path.append("soon:视频号") })
                            rowLine
                            MenuRow(icon: I.live, iconColor: Color(hex: 0xF4525B),
                                    title: "直播", onTap: { path.append("soon:直播") })
                        }
                        GroupGap()

                        GroupCard {
                            MenuRow(icon: I.scan, iconColor: Color(hex: 0x3D83E7),
                                    title: "扫一扫", onTap: { path.append("soon:扫一扫") })
                            rowLine
                            MenuRow(icon: I.shake, iconColor: Color(hex: 0x4489EA),
                                    title: "摇一摇", onTap: { path.append("soon:摇一摇") })
                        }
                        GroupGap()

                        GroupCard {
                            MenuRow(icon: I.look, iconColor: Color(hex: 0x7275E9),
                                    title: "看一看", onTap: { path.append("soon:看一看") })
                            rowLine
                            MenuRow(icon: I.searchRow, iconColor: Color(hex: 0x59C47E),
                                    title: "搜一搜", onTap: { path.append("soon:搜一搜") })
                        }
                        GroupGap()

                        GroupCard {
                            MenuRow(icon: I.nearby, iconColor: Color(hex: 0x3D83E7),
                                    title: "附近", onTap: { path.append("soon:附近") })
                        }
                        GroupGap()

                        GroupCard {
                            MenuRow(icon: I.game, iconColor: Color(hex: 0x9A6AE8),
                                    title: "游戏", onTap: { path.append("soon:游戏") })
                        }
                        GroupGap()

                        Spacer().frame(height: 20)
                    }
                }
                .background(C.pageBg)
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            .background(C.navBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                if key == "moments" {
                    MomentsView()
                } else {
                    ComingSoonView(title: String(key.dropFirst(5)))
                }
            }
        }
        // 别人发了新朋友圈 → 发现页那个小图也跟着换
        .onChange(of: realtime.event) { ev in
            if ev.type == "moment" || ev.user != nil { Task { await app.loadMoments() } }
        }
    }

    private var gap: some View {
        Rectangle().fill(C.pageBg).frame(height: L.groupGap)
    }

    private var rowLine: some View {
        HairLine(inset: L.menuLineInset)
    }
}

struct ComingSoonView: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Text("这一页排在下一批").font(pf(14)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.pageBg)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(pf(18, .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(pf(UIConfig.num("navTitle", 17))).foregroundColor(C.label)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .swipeBack { dismiss() }
    }
}

/* ============================================================ 朋友圈 */

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MomentsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var target: User? = nil

    @State private var offset: CGFloat = 0
    /// 静止时「内容顶端」在屏幕上的位置，用来算往下滚了多少
    @State private var baseY: CGFloat?
    @State private var moments: [Moment] = []
    @State private var cameraMenu = false
    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showCoverPhoto = false
    @State private var composerPick = false
    @State private var posting = false
    @State private var draft = ""
    @State private var picked: [UIImage] = []
    @State private var uploading = false
    @State private var commenting: Moment?
    @State private var commentText = ""
    @State private var actionMoment: Moment?
    /// 点开朋友圈的图片：paths = 这条动态的图片，index = 点的那张
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?
    /// 朋友圈往下翻页：还有没有更多 / 正在加载 / 一共多少条
    @State private var hasMoreMoments = false
    @State private var loadingMore = false
    @State private var momentTotal = 0
    @ObservedObject private var realtime = Realtime.shared

    /// 和网页版一致：往下滚过「封面高度 - 52」时，顶部出现「朋友圈」三个字
    /// （用屏幕坐标量「内容最顶端被推上去多少」，比命名坐标空间稳，任何机型都一样）
    private var scrolled: CGFloat { max(0, (baseY ?? offset) - offset) }
    private var solid: Bool { scrolled > (L.coverH - 52) }
    private var owner: User? { target ?? app.me }
    private var cover: String { owner?.momentCover ?? "" }

    var body: some View {
        ZStack(alignment: .top) {
            C.pageBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    /* 内容最顶端：把它的屏幕坐标报上来，用来看往下滚了多少 */
                    GeometryReader { g in
                        Color.clear.preference(key: OffsetKey.self,
                                               value: g.frame(in: .global).minY)
                    }
                    .frame(height: 0)
                    coverView
                    momentList
                }
            }
            .onPreferenceChange(OffsetKey.self) { y in
                if baseY == nil { baseY = y }
                offset = y
            }
            .ignoresSafeArea(edges: .top)

            navBar

            if let i = viewerIndex, !viewerPaths.isEmpty {
                PhotoPager(paths: viewerPaths, startIndex: i) { viewerIndex = nil }
                    .zIndex(40)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .onAppear { baseY = nil }
        .task { await reload() }
        // 别人发朋友圈 / 换了封面，这边立刻跟着变
        .onChange(of: realtime.event) { _ in
            Task {
                app.me = try? await API.shared.me()
                await pollNewMoments()          // 只把新出现的插到最前面，别把翻过的页冲掉
            }
        }
        .task {
            // 兜底：每 8 秒对一次（万一长连接断了）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                app.me = try? await API.shared.me()
                await pollNewMoments()
            }
        }
        .confirmationDialog("发表", isPresented: $cameraMenu, titleVisibility: .visible) {
            Button("拍摄") { showCamera = true }
            Button("从相册选择") { showPhoto = true }
            if target == nil { Button("换封面") { showCoverPhoto = true } }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { image in
                picked = [image]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { posting = true }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                picked = [image]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { posting = true }
            }
        }
        .sheet(isPresented: $showCoverPhoto) {
            PhotoPicker { image in changeCover(image) }
        }
        .sheet(isPresented: $posting) { publishSheet }
        .alert("评论", isPresented: Binding(
            get: { commenting != nil },
            set: { if !$0 { commenting = nil } }
        )) {
            TextField("说点什么", text: $commentText)
            Button("发送") { submitComment() }
            Button("取消", role: .cancel) { commenting = nil }
        }
        .confirmationDialog("这条动态", isPresented: Binding(
            get: { actionMoment != nil },
            set: { if !$0 { actionMoment = nil } }
        ), titleVisibility: .visible) {
            if let m = actionMoment {
                if m.likedByMe == true {
                    Button("取消赞") { like(m) }
                } else {
                    Button("赞") { like(m) }
                }
                Button("评论") {
                    commentText = ""
                    commenting = m
                }
                if m.mine == true {
                    Button("删除", role: .destructive) { remove(m) }
                }
            }
            Button("取消", role: .cancel) { actionMoment = nil }
        }
    }

    /* ---------------------------------------------------------- 封面 */

    private var coverView: some View {
        ZStack(alignment: .bottom) {
            if cover.isEmpty {
                LinearGradient(colors: [Color(hex: 0x0D3B66), Color(hex: 0x1D6FB8), Color(hex: 0x0099FF)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                RemoteImage(path: cover, icon: "photo")
            }

            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.34), Color.black.opacity(0.52)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: L.coverH * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                Text(app.me?.name ?? "")
                    .font(pf(17, .semibold))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 4, x: 0, y: 1)
                    .padding(.bottom, 24)
                Avatar(path: app.me?.avatarPath ?? "", size: L.coverAvatar, radius: 8)
                    .shadow(color: Color.black.opacity(0.28), radius: 5, x: 0, y: 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .offset(y: 21)
        }
        .frame(height: L.coverH)
        .zIndex(1)
    }

    /* ---------------------------------------------------------- 列表 */

    private var momentList: some View {
        VStack(spacing: 0) {
            if moments.isEmpty {
                Text("正在加载朋友圈…")
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 40)
            }
            ForEach(moments) { moment in
                MomentRow(moment: moment,
                          onMore: { actionMoment = moment },
                          onOpenImage: { path in openPhoto(path, in: moment) })
            }
            // 滑到底自动接着拉：3000 条也能一直往下翻（微信就是这样）
            if hasMoreMoments {
                Text(loadingMore ? "正在加载…" : " ")
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .onAppear {
                        Task { await loadMoreMoments() }
                    }
            } else if momentTotal > 0 {
                Text("没有更多了")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, L.momentPadH)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .background(Color.dyn(0xFFFFFF, 0x191919))
        .offset(y: 0)
        .zIndex(0)
    }

    /* ---------------------------------------------------------- 顶部浮条 */

    private var navBar: some View {
        ZStack {
            // 滚过封面后回到中间出现「朋友圈」（网页版就是这样）
            if solid {
                Text("朋友圈")
                    .font(pf(UIConfig.num("navTitle", 17)))
                    .foregroundColor(C.label)
            }

            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    SVGIcon(markup: I.backCover, size: 20, color: solid ? C.label : .white)
                        .frame(width: 36, height: 36)
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)

                Spacer(minLength: 0)

                Button { cameraMenu = true } label: {
                    SVGIcon(markup: I.camera, size: 26, color: solid ? C.label : .white)
                        .frame(width: 36, height: 36)
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            }
        }
        .frame(height: L.navH)
        .background(
            Group {
                if solid {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color.clear
                }
            }
            .ignoresSafeArea(edges: .top)
        )
    }

    /* ---------------------------------------------------------- 发表 / 评论 / 点赞 */

    private func openPhoto(_ path: String, in moment: Moment) {
        let all = moment.images ?? []
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }

    private var publishSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draft)
                    .frame(minHeight: 110)
                    .font(pf(17))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2))
                    )
                if !picked.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(picked.indices, id: \.self) { i in
                            Image(uiImage: picked[i])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 74, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                    }
                }
                Button {
                    composerPick = true
                } label: {
                    Label("添加图片", systemImage: "photo.on.rectangle")
                        .font(pf(15))
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("发表")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $composerPick) {
                PhotoPicker { image in picked.append(image) }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { posting = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("发表") { publish() }
                        .disabled(uploading || (draft.isEmpty && picked.isEmpty))
                }
            }
        }
    }

    private func reload() async {
        if let feed = try? await API.shared.momentsFeed(limit: 30, userId: target?.id) {
            moments = feed.moments
            hasMoreMoments = feed.hasMore
            momentTotal = feed.total
        } else {
            moments = app.moments
            hasMoreMoments = false
        }
        // 打开朋友圈 = 看过了：把「发现」上的小红点清掉
        if target == nil {
            await API.shared.markMomentsSeen()
            app.momentsUnread = 0
        }
    }

    /// 往下翻一页（3000 条也能一条条刷到底）
    private func loadMoreMoments() async {
        guard hasMoreMoments, !loadingMore, let last = moments.last else { return }
        loadingMore = true
        if let feed = try? await API.shared.momentsFeed(limit: 30, before: last.createdAt,
                                                        userId: target?.id) {
            let known = Set(moments.map { $0.id })
            moments.append(contentsOf: feed.moments.filter { !known.contains($0.id) })
            hasMoreMoments = feed.hasMore && !feed.moments.isEmpty
        } else {
            hasMoreMoments = false
        }
        loadingMore = false
    }

    /// 轮询 / 收到推送时：只把「新出现的」插到最前面，已经在列表里的和翻过的页都不动
    private func pollNewMoments() async {
        guard let feed = try? await API.shared.momentsFeed(limit: 30, userId: target?.id) else { return }
        let known = Set(moments.map { $0.id })
        let fresh = feed.moments.filter { !known.contains($0.id) }
        if !fresh.isEmpty { moments.insert(contentsOf: fresh, at: 0) }
        momentTotal = feed.total
        if moments.count <= 30 { hasMoreMoments = feed.hasMore }
    }

    private func publish() {
        uploading = true
        Task {
            var urls: [String] = []
            for image in picked {
                if let url = try? await API.shared.upload(image: image) { urls.append(url) }
            }
            do {
                try await API.shared.postMoment(content: draft, images: urls)
                app.show("已发表")
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
            draft = ""
            picked = []
            uploading = false
            posting = false
            await reload()
            await app.loadMoments()
        }
    }

    private func changeCover(_ image: UIImage) {
        Task {
            uploading = true
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.updateMe(["momentCover": url])
                if let me = try? await API.shared.me() {
                    app.me = me
                }
                app.show("封面换好了")
            }
            uploading = false
        }
    }

    private func like(_ moment: Moment) {
        Task {
            await API.shared.likeMoment(id: moment.id)
            await reload()
        }
    }

    private func submitComment() {
        guard let moment = commenting else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        commenting = nil
        if text.isEmpty { return }
        Task {
            await API.shared.commentMoment(id: moment.id, text: text)
            await reload()
        }
    }

    private func remove(_ moment: Moment) {
        Task {
            await API.shared.deleteMoment(id: moment.id)
            await reload()
            await app.loadMoments()
            app.show("已删除")
        }
    }
}

struct MomentRow: View {
    let moment: Moment
    var onMore: (() -> Void)? = nil
    /// 点图片 → 看大图
    var onOpenImage: ((String) -> Void)? = nil

    private var images: [String] { moment.images ?? [] }
    private var cols: Int {
        let n = images.count
        if n == 1 { return 1 }
        if n == 2 || n == 4 { return 2 }
        return 3
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(path: moment.author?.avatarPath ?? "", size: L.momentAvatar, radius: 5)

            VStack(alignment: .leading, spacing: 0) {
                Text(moment.author?.name ?? "")
                    .font(pf(18.3, .medium))
                    .foregroundColor(C.link)

                if let content = moment.content, !content.isEmpty {
                    Text(content)
                        .font(pf(18.3))
                        .foregroundColor(C.label)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                if !images.isEmpty {
                    grid
                        .padding(.top, 13)
                }

                HStack(spacing: 14) {
                    Text(TimeFmt.ago(moment.createdAt))
                        .font(pf(14.5))
                        .foregroundColor(Color.dyn(0xA5A5A5, 0x8A8A8E))

                    Spacer()

                    Button {
                        onMore?()
                    } label: {
                        HStack(spacing: 2.6) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill((moment.likedByMe == true) ? Color(hex: 0xFF6B6B) : Color.dyn(0x7F7F7F, 0xD8D8D8))
                                    .frame(width: 3.4, height: 3.4)
                            }
                        }
                        .frame(width: 28, height: 19)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.dyn(0xF0F0F0, 0x3A3A3C)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)

                let likes = moment.likes ?? []
                let comments = moment.comments ?? []
                if !likes.isEmpty || !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !likes.isEmpty {
                            Text(likes.compactMap { $0.nickname }.joined(separator: "、"))
                                .font(pf(15))
                                .foregroundColor(C.link)
                        }
                        ForEach(comments.indices, id: \.self) { i in
                            let c = comments[i]
                            Text((c.nickname ?? "") + "：" + (c.content ?? ""))
                                .font(pf(15))
                                .foregroundColor(C.label)
                        }
                    }
                    .padding(.top, 9)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private var grid: some View {
        let n = images.count
        let avail = L.width - L.momentPadH * 2 - L.momentAvatar - 9
        let maxW: CGFloat
        if n == 1 { maxW = avail * 0.525 }
        else if n == 2 { maxW = avail * 0.62 }
        else if n == 4 { maxW = avail * 0.52 }
        else { maxW = avail * 0.74 }
        let c = CGFloat(cols)
        let cellW = (maxW - (c - 1) * 4) / c
        let cellH: CGFloat = n == 1 ? min(cellW * 0.78, 240) : (n == 2 ? cellW * 0.75 : cellW)
        let rows = stride(from: 0, to: n, by: cols).map { start in
            Array(images[start..<min(start + cols, n)])
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        RemoteImage(path: rows[r][i], icon: "photo")
                            .frame(width: cellW, height: cellH)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenImage?(rows[r][i]) }
                    }
                    if rows[r].count < cols { Spacer(minLength: 0) }
                }
            }
        }
    }
}
