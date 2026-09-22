import SwiftUI
import CryptoKit

/* ============================================================
   手势密码（微信那种「安全锁」）
   —— 开了以后，点钱包里的「零钱 / 经营账户」要先画一遍手势才给进，
      也可以直接按面容解锁。手势只存在这台手机的钥匙串里，不上传。
   ============================================================ */

enum GestureStore {
    private static let key = "gestureLockPattern"
    private static let saltKey = "gestureLockSalt"

    static var enabled: Bool { Keychain.get(key) != nil }

    private static var salt: String {
        if let s = Keychain.get(saltKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        Keychain.set(s, for: saltKey)
        return s
    }

    private static func hash(_ pattern: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "#" + pattern).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func set(_ pattern: String) { Keychain.set(hash(pattern), for: key) }
    static func verify(_ pattern: String) -> Bool { Keychain.get(key) == hash(pattern) }
    static func clear() { Keychain.remove(key) }
}

/// 九宫格：手指划过就把点连起来（返回的是 "0-4-8" 这种）
struct PatternPad: View {
    @Binding var picked: [Int]
    var onEnd: () -> Void

    private let side: CGFloat = 250
    private let dot: CGFloat = 62

    private func center(_ i: Int) -> CGPoint {
        let r = i / 3, c = i % 3
        let step = side / 3
        return CGPoint(x: step * (CGFloat(c) + 0.5), y: step * (CGFloat(r) + 0.5))
    }

    var body: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                let p = center(i)
                let on = picked.contains(i)
                Circle()
                    .fill(on ? C.green.opacity(0.18) : Color.clear)
                    .overlay(
                        Circle().stroke(on ? C.green : Color.dyn(0xCFCFCF, 0x4A4A4A),
                                        lineWidth: on ? 2.5 : 1.5)
                    )
                    .overlay(
                        Circle().fill(on ? C.green : Color.dyn(0xDADADA, 0x5A5A5A))
                            .frame(width: dot * 0.26, height: dot * 0.26)
                    )
                    .frame(width: dot, height: dot)
                    .position(p)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    for i in 0..<9 {
                        let p = center(i)
                        if hypot(p.x - v.location.x, p.y - v.location.y) < dot * 0.62,
                           !picked.contains(i) {
                            picked.append(i)
                        }
                    }
                }
                .onEnded { _ in onEnd() }
        )
    }
}

/// 验证手势（点「零钱 / 经营账户」时弹这个）
struct GestureLockView: View {
    var hint: String = "请输入手势密码"
    var onOk: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [Int] = []
    @State private var error = ""
    @State private var checking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text(Tr("取消"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 10)

            VStack(spacing: 12) {
                Text(hint)
                    .font(pf(19, .medium))
                    .foregroundColor(C.label)
                if !error.isEmpty {
                    Text(error)
                        .font(pf(13))
                        .foregroundColor(Color(hexString: "#FA5151"))
                } else {
                    Color.clear.frame(height: 18)
                }
            }

            Spacer(minLength: 14)

            PatternPad(picked: $picked) { check() }

            if Biometrics.available {
                Button {
                    Task { await faceUnlock() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid").font(.system(size: 17))
                        Text(Biometrics.label).font(pf(15))
                    }
                    .foregroundColor(C.green)
                    .padding(.top, 22)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 24)
        }
        .background(C.pageBg.ignoresSafeArea())
    }

    private func check() {
        guard picked.count >= 4, !checking else {
            if picked.count < 4 { error = "至少连 4 个点" }
            picked = []
            return
        }
        checking = true
        let pattern = picked.map(String.init).joined(separator: "-")
        picked = []
        if GestureStore.verify(pattern) {
            onOk()
            dismiss()
        } else {
            error = "手势不对，再试一次"
        }
        checking = false
    }

    private func faceUnlock() async {
        let r = await Biometrics.authenticate(reason: "验证身份，打开零钱")
        if r.ok { onOk(); dismiss() } else if !r.message.isEmpty { error = r.message }
    }
}

/// 设置 / 修改 / 关闭手势密码（我 → 设置 → 安全中心 → 安全锁）
struct GestureSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState

    @State private var on = GestureStore.enabled
    @State private var step = 0            // 0 画第一次 · 1 再画一次确认
    @State private var first = ""
    @State private var picked: [Int] = []
    @State private var tip = "画一遍手势（至少连 4 个点）"
    @State private var error = ""
    @State private var verifyOld = false   // 改 / 关之前先验一次老的

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("安全锁"), back: { dismiss() })

            if on && step == 0 && !verifyOld {
                ScrollView {
                    VStack(spacing: 0) {
                        Text(Tr("手势密码已开启"))
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                            .padding(.top, 18)
                            .padding(.bottom, 18)
                        row(Tr("修改手势密码")) { verifyOld = true; first = ""; step = 0; tip = "先画一遍现在的手势" }
                        row(Tr("关闭手势密码")) {
                            verifyOld = true; first = ""; step = 0
                            tip = "先画一遍现在的手势（验证后关闭）"
                            closing = true
                        }
                    }
                    .background(C.cardBg)
                }
                .background(C.pageBg)
            } else {
                VStack(spacing: 10) {
                    Text(tip)
                        .font(pf(18, .medium))
                        .foregroundColor(C.label)
                    if !error.isEmpty {
                        Text(error).font(pf(13)).foregroundColor(Color(hexString: "#FA5151"))
                    } else {
                        Color.clear.frame(height: 16)
                    }
                    PatternPad(picked: $picked) { done() }
                    Button {
                        /* 已经设过手势的：这颗只是「取消」，别手一滑把锁清了 */
                        if GestureStore.enabled {
                            dismiss()
                        } else {
                            GestureStore.clear()
                            on = false
                            app.show(Tr("手势密码已关闭"))
                            dismiss()
                        }
                    } label: {
                        Text(Tr(GestureStore.enabled ? "取消" : "先不设置"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.top, 18)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 30)
                Spacer(minLength: 0)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    @State private var closing = false

    private func row(_ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HairLine(inset: 16) }
    }

    private func done() {
        guard picked.count >= 4 else {
            error = "至少连 4 个点"
            picked = []
            return
        }
        let pattern = picked.map(String.init).joined(separator: "-")
        picked = []
        error = ""

        /* 改 / 关之前：先验老的 */
        if verifyOld {
            guard GestureStore.verify(pattern) else {
                error = "手势不对，再试一次"
                return
            }
            verifyOld = false
            if closing {
                closing = false
                GestureStore.clear()
                on = false
                app.show(Tr("手势密码已关闭"))
                dismiss()
                return
            }
            tip = "画一遍新的手势"
            return
        }

        if first.isEmpty {
            first = pattern
            tip = "再画一遍确认"
            return
        }
        if first == pattern {
            GestureStore.set(pattern)
            on = true
            app.show(Tr("手势密码设好了：进零钱要画一遍"))
            dismiss()
        } else {
            first = ""
            tip = "两次不一样，重新画一遍"
            error = "两次手势不一样"
        }
    }
}
