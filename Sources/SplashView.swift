import SwiftUI

/* 我们自己的启动页：铺满整屏显示 splash.png，进来盖 1 秒后淡出。
   图片打包在 App 里（CI 会把 iosfull/splash.png 拷进 bundle），不走网络，
   所以断网、冷启动都能立刻显示。 */
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black
            if let img = UIImage(named: "splash") {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()          // 铺满整屏（不留黑边；深色图，左右裁一点看不出来）
                    .frame(width: UIScreen.main.bounds.width,
                           height: UIScreen.main.bounds.height)
            } else {
                /* 图没打进包时的兜底：黑底 + 名字 */
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
        .ignoresSafeArea()
        .clipped()
    }
}
