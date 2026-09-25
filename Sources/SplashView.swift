import SwiftUI

/* 我们自己的启动页：铺满整屏显示 splash.png，进来盖 1 秒后淡出。
   图片打包在 App 里（CI 会把 iosfull/splash.png 拷进 bundle），不走网络，
   所以断网、冷启动都能立刻显示。 */
struct SplashView: View {
    /// 后台配的启动页图片（后台「界面配置」里换）；空着就用包里那张
    var remote: String = ""

    var body: some View {
        /* 用 GeometryReader 拿"整块窗口"的真实尺寸（含状态栏/刘海那一条），
           再用 ignoresSafeArea 铺出去 —— 之前用 UIScreen 尺寸在安全区里布局，
           顶部会留 ~13pt 露出页面底色，看着就是一条白条。 */
        GeometryReader { geo in
            ZStack {
                Color.black
                /* 优先用后台配的那张（远端图，带缓存）：换图不用重装 App。
                   没配、或者还没下载完 → 下面用包里那张兜底，保证冷启动/断网都不白屏。 */
                if !remote.isEmpty {
                    /* ① 底：同一张图放大填满 + 模糊 —— 把「比例不合留出来的边」填掉，
                          所以**不会出现黑边**（这一层会被裁掉一部分，但它是模糊背景，看不出来）。 */
                    RemoteImage(path: remote, mode: .fill, maxSide: 1600)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 26)
                        .clipped()
                    /* ② 面：整张图**完整显示**（fit，一点不裁、也不变形）；
                          maxSide 2560 是解码上限，别把高清图压糊（默认只有 1600）。 */
                    RemoteImage(path: remote, mode: .fit, maxSide: 2560)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let img = UIImage(named: "splash") {
                    /* 包里那张也按同样办法：底图填满模糊（不留黑边）＋ 上面整图完整显示 */
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 26)
                        .clipped()
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()          // 完整显示，不裁剪
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 54))
                            .foregroundColor(.white)
                        Text("Luchat")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(.all)
    }
}
