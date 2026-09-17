import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()

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

                        gap

                        GroupCard {
                            MenuRow(icon: I.channels, iconColor: Color(hex: 0xF2943B),
                                    title: "视频号", onTap: { path.append("soon:视频号") })
                            rowLine
                            MenuRow(icon: I.live, iconColor: Color(hex: 0xF4525B),
                                    title: "直播", onTap: { path.append("soon:直播") })
                        }

                        gap

                        GroupCard {
                            MenuRow(icon: I.scan, iconColor: Color(hex: 0x3D83E7),
                                    title: "扫一扫", onTap: { path.append("soon:扫一扫") })
                            rowLine
                            MenuRow(icon: I.shake, iconColor: Color(hex: 0x4489EA),
                                    title: "摇一摇", onTap: { path.append("soon:摇一摇") })
                        }

                        gap

                        GroupCard {
                            MenuRow(icon: I.look, iconColor: Color(hex: 0x7275E9),
                                    title: "看一看", onTap: { path.append("soon:看一看") })
                            rowLine
                            MenuRow(icon: I.searchRow, iconColor: Color(hex: 0x59C47E),
                                    title: "搜一搜", onTap: { path.append("soon:搜一搜") })
                        }

                        gap

                        GroupCard {
                            MenuRow(icon: I.nearby, iconColor: Color(hex: 0x3D83E7),
                                    title: "附近", onTap: { path.append("soon:附近") })
                        }

                        gap

                        GroupCard {
                            MenuRow(icon: I.game, iconColor: Color(hex: 0x9A6AE8),
                                    title: "游戏", onTap: { path.append("soon:游戏") })
                        }

                        gap

                        GroupCard {
                            MenuRow(icon: I.miniApp, iconColor: Color(hex: 0x4489EA),
                                    title: "小程序", onTap: { path.append("soon:小程序") })
                        }

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
    }

    private var gap: some View {
        Rectangle().fill(C.pageBg).frame(height: L.groupGap)
    }

    private var rowLine: some View {
        HairLine(inset: L.menuTextX)
    }
}

struct ComingSoonView: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 17)).foregroundColor(C.label)
            Text("这一页排在下一批").font(.system(size: 14)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.pageBg)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(.system(size: 18)).foregroundColor(C.label)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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

    @State private var offset: CGFloat = 0

    private var solid: Bool { offset < -(L.coverH - L.navH - 50) }
    private var cover: String { app.me?.momentCover ?? "" }

    var body: some View {
        ZStack(alignment: .top) {
            C.pageBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        Color.clear.preference(key: OffsetKey.self, value: geo.frame(in: .named("moments")).minY)
                    }
                    .frame(height: 0)

                    coverView
                    momentList
                }
            }
            .coordinateSpace(name: "moments")
            .onPreferenceChange(OffsetKey.self) { offset = $0 }
            .ignoresSafeArea(edges: .top)

            navBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await app.loadMoments() }
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
                    .font(.system(size: 17, weight: .semibold))
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
            if app.moments.isEmpty {
                Text("正在加载朋友圈…")
                    .font(.system(size: 14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 40)
            }
            ForEach(app.moments) { moment in
                MomentRow(moment: moment)
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
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                SVGIcon(markup: I.backCover, size: 20, color: .white)
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)

            Spacer()

            if solid {
                Text("朋友圈")
                    .font(.system(size: 18))
                    .foregroundColor(C.label)
                    .frame(maxWidth: .infinity)
            }

            Spacer()

            Button { app.show("发表 / 换封面排在下一批") } label: {
                SVGIcon(markup: I.camera, size: 26, color: .white)
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
        }
        .frame(height: L.navH)
        .padding(.top, L.safeTop)
        .background(
            Group {
                if solid {
                    C.navBg
                } else {
                    Color.clear
                }
            }
            .ignoresSafeArea(edges: .top)
        )
    }
}

struct MomentRow: View {
    let moment: Moment

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
                    .font(.system(size: 18.3, weight: .medium))
                    .foregroundColor(C.link)

                if let content = moment.content, !content.isEmpty {
                    Text(content)
                        .font(.system(size: 18.3))
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
                        .font(.system(size: 14.5))
                        .foregroundColor(Color.dyn(0xA5A5A5, 0x8A8A8E))

                    Spacer()

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
                .padding(.top, 10)

                let likes = moment.likes ?? []
                let comments = moment.comments ?? []
                if !likes.isEmpty || !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !likes.isEmpty {
                            Text(likes.compactMap { $0.nickname }.joined(separator: "、"))
                                .font(.system(size: 15))
                                .foregroundColor(C.link)
                        }
                        ForEach(comments.indices, id: \.self) { i in
                            let c = comments[i]
                            Text((c.nickname ?? "") + "：" + (c.content ?? ""))
                                .font(.system(size: 15))
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
                    }
                    if rows[r].count < cols { Spacer(minLength: 0) }
                }
            }
        }
    }
}
