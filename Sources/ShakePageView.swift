import SwiftUI
import UIKit
import CoreLocation
import AudioToolbox

/* ============================================================
   摇一摇（发现 → 摇一摇）
   微信的逻辑：你真摇手机的那几秒里，另一个也在摇的人会被摇到。
   服务器只记「最近 30 秒谁摇过」，两边一撞就配对（近的先摇到），
   5 分钟内不会重复摇到同一个人。没有人在摇就提示「再摇一摇」。
   一个页面深色到底（和微信一样），中间一个大手掌图标，摇到人以后显示对方卡片。
   ============================================================ */

/// 真摇手机：UIKit 的 motionShake 事件（不用申请任何权限）
struct ShakeDetector: UIViewControllerRepresentable {
    var onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeVC {
        let vc = ShakeVC()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: ShakeVC, context: Context) {
        vc.onShake = onShake
    }

    final class ShakeVC: UIViewController {
        var onShake: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            resignFirstResponder()
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else { return }
            onShake?()
        }
    }
}

struct ShakePageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loc = NearbyLocator()

    @State private var result: NearbyPerson?
    @State private var shaking = 0
    @State private var busy = false
    @State private var tip = "摇一摇，找到同时在摇手机的人"
    @State private var wiggle = false
    @State private var helloText = "摇一摇摇到你了，交个朋友吧"
    @State private var showHello = false
    @State private var cardUser: User?

    private let pageBg = Color(hex: 0x111111)
    private let ink = Color.white
    private let subInk = Color(hex: 0x929292)

    var body: some View {
        ZStack {
            pageBg.ignoresSafeArea()
            ShakeDetector { shake() }.allowsHitTesting(false)

            VStack(spacing: 0) {
                navBar
                Spacer(minLength: 0)

                if let p = result {
                    matchedCard(p)
                } else {
                    handIcon
                    Text(tip)
                        .font(pf(15))
                        .foregroundColor(subInk)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                        .padding(.horizontal, 40)
                }

                Spacer(minLength: 0)

                /* 不摇手机也能测：点这个按钮等于摇一下 */
                Button {
                    shake()
                } label: {
                    Text(busy ? "正在找…" : (result == nil ? "摇 一 摇" : "再摇一次"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 23, style: .continuous)
                            .fill(Color(hex: 0x07C160)))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.horizontal, 60)
                .padding(.bottom, 34)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 和别的二级页一样：左边缘右滑返回 */
        .swipeBack { dismiss() }
        .navigationDestination(isPresented: Binding(
            get: { cardUser != nil },
            set: { if !$0 { cardUser = nil } }
        )) {
            if let u = cardUser {
                ContactCardView(user: u, onOpenChat: { _ in cardUser = nil }, onOpenMoments: { _ in cardUser = nil })
            }
        }
        .alert("打招呼", isPresented: $showHello) {
            TextField("说点什么…", text: $helloText)
            Button("发送") { sendHello() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("给 \(result?.name ?? "") 发一条消息")
        }
        .task { loc.start() }
    }

    /* ---------------------------------------------------------- 界面 */

    private var navBar: some View {
        ZStack {
            Text("摇一摇").font(pf(17, .semibold)).foregroundColor(ink)
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(ink)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if shaking > 1 {
                    Text("\(shaking) 人在摇")
                        .font(pf(13))
                        .foregroundColor(subInk)
                        .padding(.trailing, 14)
                }
            }
        }
        .frame(height: L.navH)
    }

    private var handIcon: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 92, weight: .regular))
            .foregroundColor(Color(hex: 0x4C9AFF))
            .rotationEffect(.degrees(wiggle ? 12 : -12))
            .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: wiggle)
            .onAppear { wiggle = true }
    }

    private func matchedCard(_ p: NearbyPerson) -> some View {
        VStack(spacing: 10) {
            Avatar(path: p.avatar ?? "", size: 96, radius: 10)
            Text(p.name)
                .font(pf(20, .medium))
                .foregroundColor(ink)
            if !p.distanceText.isEmpty {
                Text(p.distanceText)
                    .font(pf(14))
                    .foregroundColor(subInk)
            }
            if !signature(p).isEmpty {
                Text(signature(p))
                    .font(pf(14))
                    .foregroundColor(subInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
            HStack(spacing: 12) {
                Button {
                    showHello = true
                } label: {
                    Text("打招呼")
                        .font(pf(15))
                        .foregroundColor(.white)
                        .frame(width: 116, height: 38)
                        .background(RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(Color(hex: 0x07C160)))
                }
                .buttonStyle(.plain)
                Button {
                    openCard(p)
                } label: {
                    Text("看资料")
                        .font(pf(15))
                        .foregroundColor(ink)
                        .frame(width: 116, height: 38)
                        .background(RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .stroke(Color(white: 1, opacity: 0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 10)
    }

    private func signature(_ p: NearbyPerson) -> String {
        if let m = p.moodText, !m.isEmpty { return m }
        if let b = p.bio, !b.isEmpty { return b }
        if let r = p.region, !r.isEmpty { return r }
        return ""
    }

    /* ---------------------------------------------------------- 动作 */

    private func shake() {
        guard !busy else { return }
        busy = true
        result = nil
        tip = "正在找同时在摇的人…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioServicesPlaySystemSound(1104)          // 系统那个「咔」的一声
        Task {
            defer { busy = false }
            do {
                let r = try await API.shared.shake(lat: loc.lat, lng: loc.lng)
                shaking = r.shaking ?? 0
                if let p = r.matched {
                    result = p
                    tip = ""
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    AudioServicesPlaySystemSound(1057)
                } else {
                    tip = "没摇到人，再摇一摇试试\n（要有别人也在摇才能摇到）"
                }
            } catch {
                tip = (error as? APIError)?.errorDescription ?? "摇失败了，再试一次"
            }
        }
    }

    private func sendHello() {
        guard let p = result else { return }
        let text = helloText.trimmingCharacters(in: .whitespacesAndNewlines)
        let say = text.isEmpty ? "摇一摇摇到你了，交个朋友吧" : text
        Task {
            do {
                _ = try await API.shared.nearbyHello(userId: p.id, text: say)
                app.show("已打招呼")
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
