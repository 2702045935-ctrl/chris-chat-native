import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    GroupCard {
                        NavigationLink(value: "moments") {
                            MenuRow(icon: "photo.on.rectangle.angled", color: Color(hex: 0x3C9CFF), title: "朋友圈")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    GroupCard {
                        NavigationLink(value: "channels") {
                            MenuRow(icon: "play.rectangle.fill", color: Color(hex: 0xFF7043), title: "视频号")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "live") {
                            MenuRow(icon: "dot.radiowaves.left.and.right", color: Color(hex: 0xFFB300), title: "直播")
                        }
                        .buttonStyle(.plain)
                    }

                    GroupCard {
                        NavigationLink(value: "scan") {
                            MenuRow(icon: "qrcode.viewfinder", color: Color(hex: 0x4CD964), title: "扫一扫")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "shake") {
                            MenuRow(icon: "waveform.path", color: Color(hex: 0x3C9CFF), title: "摇一摇")
                        }
                        .buttonStyle(.plain)
                    }

                    GroupCard {
                        NavigationLink(value: "look") {
                            MenuRow(icon: "doc.text.magnifyingglass", color: Color(hex: 0xFF9500), title: "看一看")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "search") {
                            MenuRow(icon: "magnifyingglass", color: Color(hex: 0x5856D6), title: "搜一搜")
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer().frame(height: 20)
                }
            }
            .background(Brand.pageBg)
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { key in
                if key == "moments" {
                    MomentsView()
                } else {
                    ComingSoonView(title: titleFor(key))
                }
            }
        }
    }

    private func titleFor(_ key: String) -> String {
        switch key {
        case "channels": return "视频号"
        case "live": return "直播"
        case "scan": return "扫一扫"
        case "shake": return "摇一摇"
        case "look": return "看一看"
        case "search": return "搜一搜"
        default: return "敬请期待"
        }
    }
}

/* ============================================================ 朋友圈 */

struct MomentsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if app.moments.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().padding(.top, 30)
                        Text("正在加载朋友圈…")
                            .font(.system(size: 14))
                            .foregroundColor(Brand.subLabel)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                ForEach(app.moments) { moment in
                    MomentRow(moment: moment)
                    HairLine()
                }
            }
            .background(Brand.cellBg)
        }
        .background(Brand.cellBg)
        .navigationTitle("朋友圈")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.loadMoments() }
        .task { await app.loadMoments() }
    }
}

struct MomentRow: View {
    let moment: Moment

    private var images: [String] { moment.images ?? [] }

    private var rows: [[String]] {
        var result: [[String]] = []
        var index = 0
        while index < images.count {
            let end = min(index + 3, images.count)
            result.append(Array(images[index..<end]))
            index = end
        }
        return result
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(path: moment.author?.avatarPath ?? "", size: 40, radius: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(moment.author?.name ?? "")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hex: 0x576B95))

                if let content = moment.content, !content.isEmpty {
                    Text(content)
                        .font(.system(size: 16))
                        .foregroundColor(Brand.label)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !images.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            HStack(spacing: 4) {
                                ForEach(rows[rowIndex].indices, id: \.self) { index in
                                    let path = rows[rowIndex][index]
                                    RemoteImage(path: path, icon: "photo")
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                                if rows[rowIndex].count < 3 { Spacer(minLength: 0) }
                            }
                        }
                    }
                }

                Text(TimeFmt.ago(moment.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(Brand.subLabel)

                let likes = moment.likes ?? []
                let comments = moment.comments ?? []
                if !likes.isEmpty || !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !likes.isEmpty {
                            Text("♡ " + likes.compactMap { $0.nickname }.joined(separator: "、"))
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: 0x576B95))
                        }
                        ForEach(comments.indices, id: \.self) { index in
                            let comment = comments[index]
                            Text((comment.nickname ?? "") + "：" + (comment.content ?? ""))
                                .font(.system(size: 14))
                                .foregroundColor(Brand.label)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.dyn(0xF7F7F7, 0x2C2C2E)))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}
