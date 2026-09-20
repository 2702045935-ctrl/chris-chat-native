import SwiftUI

/* ============================================================
   游戏（发现 → 游戏）
   四个小游戏都是真能玩的，玩法在客户端（服务器只发列表，后台能改 data/games.json）：
     · 掷骰子：1~6 带滚动动画
     · 石头剪刀布：和机器人猜一把
     · 抽签：今天宜不宜出门
     · 大转盘：转一下决定吃什么
   玩完可以「发到聊天」把结果发进某个会话（走正常消息，对方也能看到）。
   ============================================================ */

struct GamesPageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var games: [MiniGame] = []
    @State private var playing: MiniGame?

    private let pageBg = Color(hex: 0x111111)
    private let cardBg = Color(hex: 0x1B1B1D)
    private let ink = Color.white
    private let subInk = Color(hex: 0x929292)

    private var fallback: [MiniGame] {
        [
            MiniGame(id: "g01", label: "掷骰子", desc: "一到六，看运气", icon: "🎲", kind: "dice", enabled: true),
            MiniGame(id: "g02", label: "石头剪刀布", desc: "和机器人猜一把", icon: "✊", kind: "rps", enabled: true),
            MiniGame(id: "g03", label: "抽签", desc: "今天宜不宜出门", icon: "🎋", kind: "fortune", enabled: true),
            MiniGame(id: "g04", label: "大转盘", desc: "转一下决定吃什么", icon: "🎡", kind: "wheel", enabled: true)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("游戏").font(pf(17, .semibold)).foregroundColor(ink)
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(list) { g in
                        Button { playing = g } label: { card(g) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .sheet(item: $playing) { g in
            GamePlayView(game: g)
        }
        .task {
            let items = (try? await API.shared.games()) ?? []
            games = items.isEmpty ? fallback : items
        }
    }

    private var list: [MiniGame] { games.isEmpty ? fallback : games }

    private func card(_ g: MiniGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g.icon ?? "🎮").font(.system(size: 34))
            Text(g.label ?? "").font(pf(15, .medium)).foregroundColor(ink)
            Text(g.desc ?? "").font(pf(12.5)).foregroundColor(subInk).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }
}

/* ---------------------------------------------------------- 玩法 */

struct GamePlayView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let game: MiniGame

    @State private var rolling = false
    @State private var result = ""
    @State private var dice = 1
    @State private var spinDegrees = 0.0
    @State private var pickerOpen = false

    private let pageBg = Color(hex: 0x111111)
    private let ink = Color.white

    private var kind: String { game.kind ?? "dice" }

    var body: some View {
        ZStack {
            pageBg.ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Text(game.label ?? "")
                        .font(pf(17, .semibold)).foregroundColor(ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ink.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                Spacer(minLength: 0)
                stage
                Text(result.isEmpty ? "点下面开始" : result)
                    .font(pf(15))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button { play() } label: {
                        Text(rolling ? "…" : (result.isEmpty ? "开始" : "再来一次"))
                            .font(pf(16, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(rolling)
                    if !result.isEmpty {
                        Button { pickerOpen = true } label: {
                            Text("发到聊天")
                                .font(pf(16)).foregroundColor(.white)
                                .frame(width: 108, height: 46)
                                .background(RoundedRectangle(cornerRadius: 23, style: .continuous)
                                    .stroke(Color(white: 1, opacity: 0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, max(24, L.safeBottom))
            }
        }
        .confirmationDialog("发到哪个聊天", isPresented: $pickerOpen, titleVisibility: .visible) {
            ForEach(app.chats.prefix(8)) { c in
                Button(c.name) { share(to: c) }
            }
            Button("取消", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch kind {
        case "rps":
            Text(rolling ? "✊" : (result.contains("石头") ? "✊" : result.contains("剪刀") ? "✌️" : result.isEmpty ? "✊" : "✋"))
                .font(.system(size: 96))
        case "fortune":
            Text("🎋").font(.system(size: 84))
                .rotationEffect(.degrees(rolling ? 8 : 0))
                .animation(.easeInOut(duration: 0.18).repeatCount(6, autoreverses: true), value: rolling)
        case "wheel":
            ZStack {
                Circle().fill(AngularGradient(colors: [
                    Color(hex: 0xFA5151), Color(hex: 0xFFB400), Color(hex: 0x07C160),
                    Color(hex: 0x4C9AFF), Color(hex: 0xB06CFF), Color(hex: 0xFA5151)
                ], center: .center))
                .frame(width: 190, height: 190)
                .rotationEffect(.degrees(spinDegrees))
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .offset(y: -104)
            }
        default:
            Text(diceFace(dice)).font(.system(size: 92))
                .rotationEffect(.degrees(rolling ? 0 : 0))
        }
    }

    private func diceFace(_ n: Int) -> String {
        ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"][max(0, min(5, n - 1))]
    }

    private func play() {
        rolling = true
        result = ""
        switch kind {
        case "rps":
            let mine = ["石头", "剪刀", "布"].randomElement()!
            let cpu = ["石头", "剪刀", "布"].randomElement()!
            let win = (mine == "石头" && cpu == "剪刀") || (mine == "剪刀" && cpu == "布") || (mine == "布" && cpu == "石头")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                rolling = false
                result = "我出\(mine)，对方出\(cpu) —— \(mine == cpu ? "平局" : (win ? "我赢了 🎉" : "我输了"))"
            }
        case "fortune":
            let list = ["大吉：今天适合出门走走", "中吉：做事顺，但别太急", "小吉：慢慢来，会好",
                        "平：宜喝杯奶茶", "小凶：少熬夜（说给你听的）", "大凶：今天别发誓 🤭"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                rolling = false
                result = list.randomElement()!
            }
        case "wheel":
            let choices = ["火锅", "烧烤", "日料", "麻辣烫", "汉堡", "随便点"]
            let idx = Int.random(in: 0..<choices.count)
            withAnimation(.easeOut(duration: 1.6)) {
                spinDegrees += Double.random(in: 720...1080)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                rolling = false
                result = "就吃：\(choices[idx])"
            }
        default:
            var ticks = 0
            Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
                ticks += 1
                dice = Int.random(in: 1...6)
                if ticks > 12 { t.invalidate(); rolling = false; result = "掷出了 \(dice) 点" }
            }
        }
    }

    private func share(to chat: Chat) {
        Task {
            do {
                _ = try await API.shared.send(chatId: chat.id, kind: "text",
                                              content: "\(game.icon ?? "🎮") \(result)")
                app.show("已发到「\(chat.name)」")
                dismiss()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
        }
    }
}
