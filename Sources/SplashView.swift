import SwiftUI

/* 我们自己的启动页：铺满整屏显示 splash.png，进来盖 1 秒后淡出。
   图片打包在 App 里（CI 会把 iosfull/splash.png 拷进 bundle），不走网络，
   所以断网、冷启动都能立刻显示。 */
struct SplashView: View {
    var body: some View {
        /* 用 GeometryReader 拿"整块窗口"的真实尺寸（含状态栏/刘海那一条），
           再用 ignoresSafeArea 铺出去 —— 之前用 UIScreen 尺寸在安全区里布局，
           顶部会留 ~13pt 露出页面底色，看着就是一条白条。 */
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = UIImage(named: "splash") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
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
