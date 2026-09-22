import Foundation
import UIKit
import SwiftUI          // 服务页样式里要算颜色（Color）
import AVFoundation     // 视频边下边播要用 AVURLAsset

/* ============================================================ 数据模型 */

struct User: Codable, Identifiable, Hashable {
    var id: String
    var requestId: String?
    var moodText: String?
    var moodIcon: String?
    var moodColor: String?
    var moodColor2: String?
    var username: String?
    var nickname: String?
    var avatar: String?
    var bio: String?
    var gender: String?
    var region: String?
    var phone: String?
    var status: String?
    var chatBackground: String?
    var birthday: String?
    var momentCover: String?
    var bot: Bool?
    var online: Bool?
    var balance: Double?
    /// 我和他的关系：self / friend / incoming / requested / none（名片页按钮按它变）
    var relation: String?
    /// 他发过几条朋友圈（名片上朋友圈那一行有没有）
    var momentCount: Int?

    var name: String {
        if let n = nickname, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return "未知用户"
    }
    var avatarPath: String { avatar ?? "" }
}

struct LastMessage: Decodable, Hashable {
    var id: String?
    var senderId: String?
    var senderName: String?
    var kind: String?
    var preview: String?
    var createdAt: String?
}

struct Chat: Decodable, Identifiable, Hashable {
    var id: String
    var type: String?
    var title: String?
    var avatar: String?
    var unread: Int?
    var pinned: Bool?
    var botRank: Int?
    var memberCount: Int?
    /// 会话成员（单聊里用来找「对方是谁」，打语音/视频要用）
    var memberIds: [String]?
    var lastMessage: LastMessage?
    var updatedAt: String?
    /// 消息免打扰（群屏蔽）
    var muted: Bool?
    /// 群主 id（群聊才有）
    var ownerId: String?
    /// 群公告（群聊才有）
    var announce: String?
    /// 群禁言：全员禁言 / 我有没有被单独禁言
    var muteAll: Bool?
    var meMuted: Bool?

    var name: String { (title?.isEmpty == false) ? title! : "会话" }
    var unreadCount: Int { unread ?? 0 }
}

struct Message: Decodable, Identifiable, Hashable {
    var id: String
    var chatId: String?
    var seq: Int?
    var senderId: String?
    var kind: String?
    var content: String?
    var createdAt: String?
    var recalled: Bool?
    var senderName: String?
    var senderAvatar: String?
    /// 通话记录专用的附加信息（服务端写系统消息时带上）
    var call: CallMeta?

    var kindName: String { kind ?? "text" }
    var body: String { content ?? "" }
    var isRecalled: Bool { recalled ?? false }

    /// 这行系统消息是不是一条通话记录
    var isCallRecord: Bool {
        if call != nil { return true }
        let t = body
        return t.contains("通话") || t == "已取消" || t == "未接听" || t == "对方无应答"
            || t == "对方已拒绝" || t == "对方忙线中" || t == "对方不在线"
    }
    /// 视频通话（图标画摄像机）
    var isVideoCall: Bool { (call?.media ?? "").contains("video") || body.contains("视频") }
}

/// 通话系统消息的附加信息：媒体类型、状态、时长
struct CallMeta: Decodable, Hashable {
    var media: String?
    var state: String?
    var secs: Int?
}

/* ============================================================ 附近的人 */

/// 附近名单里的一个人
struct NearbyPerson: Decodable, Identifiable, Hashable {
    var id: String
    var nickname: String?
    var avatar: String?
    var gender: String?
    var region: String?
    var bio: String?
    var moodText: String?
    var moments: Int?
    var online: Bool?
    var friend: Bool?
    /// 距离（公里，服务器算好的，一位小数）
    var km: Double?
    /// 几分钟前报的位置
    var minutes: Int?

    var name: String { (nickname?.isEmpty == false) ? nickname! : "附近的人" }
    var isFemale: Bool { (gender ?? "") == "female" }
    /// 距离文字：照参考图那种微信写法 —— 不到 1 公里「500米以内」，超过就「1.2公里以内」
    var distanceText: String {
        guard let km = km else { return "" }
        if km < 1 {
            let m = max(100, Int(ceil(km * 1000 / 100)) * 100)      // 往大取到 100 米
            return "\(m)米以内"
        }
        return String(format: "%.1f公里以内", km)
    }
    var timeText: String {
        guard let m = minutes else { return "" }
        if m <= 0 { return "刚刚" }
        if m < 60 { return "\(m) 分钟前" }
        return "\(m / 60) 小时前"
    }
}

private struct NearbyPayload: Decodable {
    var people: [NearbyPerson]
    /// 5 公里内没人时：20 公里内有几个（提示「扩大范围」用）
    var wider: Int?
    var maxKm: Double?
}
private struct NearbyHelloPayload: Decodable { var chatId: String?; var text: String? }

/// 摇一摇的结果：摇到人就是 matched，没人同时在摇就是 nil
struct ShakeResult: Decodable {
    var matched: NearbyPerson?
    /// 现在有几台设备在摇（微信也会提示「同时有 N 人在摇」）
    var shaking: Int?
}

/* ---------------- 直播专场 ---------------- */
private struct LivePayload: Decodable { var rooms: [LiveRoom] }
private struct LiveJoinPayload: Decodable { var watching: Int? }
private struct LiveLikePayload: Decodable { var likes: Int? }
private struct GamesPayload: Decodable { var items: [MiniGame] }

/// 小游戏：玩法写在客户端，服务器只发列表（后台能改 data/games.json）
struct MiniGame: Decodable, Identifiable, Hashable {
    var id: String
    var label: String?
    var desc: String?
    var icon: String?
    var kind: String?
    var enabled: Bool?
}

/* ---------------- 视频号 ---------------- */
/// 视频号的后台可调样式（后台「视频号」面板里改）
struct FeedStyle: Decodable, Hashable {
    var avatar: Double?
    var nameSize: Double?
    var descSize: Double?
    var musicSize: Double?
    var railIcon: Double?
    var railGap: Double?
    var padBottom: Double?
}

/// 视频号的开关
struct FeedFlags: Decodable, Hashable {
    var allowPublish: Bool?
    var allowTrim: Bool?
    var showRail: Bool?
    var autoPlay: Bool?
}

private struct FeedPayload: Decodable {
    var items: [FeedItem]
    var style: FeedStyle?
    var flags: FeedFlags?
}
private struct FeedLikePayload: Decodable { var liked: Bool?; var likes: Int? }
private struct FeedCommentPayload: Decodable { var comments: Int? }
private struct FeedPublishPayload: Decodable { var id: String?; var video: String? }
private struct FeedTrimPayload: Decodable { var url: String?; var width: Int?; var height: Int? }

struct MomentLike: Decodable, Hashable {
    var userId: String?
    var nickname: String?
    var at: String?
}

struct MomentComment: Decodable, Hashable {
    var id: String?
    var userId: String?
    var nickname: String?
    var replyToName: String?
    var content: String?
    var at: String?
}

struct Moment: Decodable, Identifiable, Hashable {
    var id: String
    var authorId: String?
    var author: User?
    var content: String?
    var images: [String]?
    var createdAt: String?
    var likes: [MomentLike]?
    var likedByMe: Bool?
    var comments: [MomentComment]?
    var mine: Bool?
}

private struct ChatsPayload: Decodable { var chats: [Chat] }
private struct ChatPayload: Decodable { var chat: Chat? }
private struct ChatMembersPayload: Decodable {
    var members: [User]?
    var ownerId: String?
    var createdAt: String?
    var avatar: String?
}
private struct PinPayload: Decodable { var pinned: Bool?; var forced: Bool? }
private struct ChatInfoPayload: Decodable { var name: String?; var announce: String? }
private struct MutePayload: Decodable { var muted: Bool? }
private struct GroupActionPayload: Decodable { var memberCount: Int?; var left: Bool?; var dismissed: Bool? }
private struct SearchPayload: Decodable { var messages: [FoundMessage] }
private struct BankCardsPayload: Decodable { var cards: [BankCard]? }
private struct SendPayload: Decodable { var sent: Bool?; var id: String? }

/// 银行卡（卡号只回后四位）
struct BankCard: Decodable, Identifiable, Hashable {
    var id: String
    var bank: String?
    var holder: String?
    var tail: String?

    var title: String { (bank ?? "银行卡") + " 尾号" + (tail ?? "****") }
}

/// 「查找聊天记录」搜出来的那一条
struct FoundMessage: Decodable, Identifiable, Hashable {
    var id: String
    var seq: Int?
    var kind: String?
    var content: String?
    var createdAt: String?
    var senderId: String?
    var senderName: String?
}
private struct UsersPayload: Decodable { var users: [User] }
private struct MessagesPayload: Decodable {
    var chat: Chat?
    var messages: [Message]
    var hasMore: Bool?
}
private struct MessagePayload: Decodable { var message: Message? }
private struct CreditScorePayload: Decodable { var score: CreditScore }

/// 安全分（服务端按真实记录算：资料 / 登录设备 / 转账 / 记账 / 安全事件）
struct CreditScore: Decodable, Hashable {
    struct Item: Decodable, Hashable {
        var label: String
        var ok: Bool
        var tip: String?
    }
    struct Dim: Decodable, Hashable, Identifiable {
        var key: String
        var label: String
        var score: Int
        var max: Int
        var items: [Item]?
        var id: String { key }
    }
    struct Stats: Decodable, Hashable {
        var deviceCount: Int?
        var sentCount: Int?
        var successCount: Int?
        var expiredCount: Int?
        var ledgerCount: Int?
    }
    var score: Int
    var level: String
    var min: Int
    var max: Int
    var percent: Int
    var updatedAt: String?
    var dims: [Dim]
    var tips: [String]
    var stats: Stats?
}
private struct ContactsPayload: Decodable {
    var friends: [User]
    var incoming: [User]?
    var outgoing: [User]?
}
private struct MePayload: Decodable { var user: User? }
private struct UserPayload: Decodable { var user: User? }
private struct LoginPayload: Decodable { var user: User? }
private struct SessionPayload: Decodable { var authenticated: Bool?; var user: User? }
private struct PhoneCodePayload: Decodable { var sent: Bool?; var devCode: String?; var nickname: String? }
private struct CaptchaPayload: Decodable { var id: String?; var svg: String? }
private struct PairStartPayload: Decodable { var code: String?; var expiresIn: Int? }
private struct PairStatusPayload: Decodable { var status: String?; var user: User?; var token: String? }
private struct MomentsPayload: Decodable {
    var moments: [Moment]
    var hasMore: Bool?
    var unread: Int?
    var total: Int?
}
private struct BrandingPayload: Decodable { var branding: BrandInfo? }
private struct BadgesPayload: Decodable { var badges: [String: String]? }

struct BrandInfo: Decodable, Hashable {
    var appName: String?
    var logo: String?
    /// 服务器上配的「默认聊天背景」（用户自己没设时用它）
    var chatBackground: String?
    var fontScale: Double?
    var accentColor: String?
    /// 通话用的 ICE 服务器（后台「语音通话」里配的，跨网络需要 TURN 时填这儿）
    var iceServers: String?
    /// 登录页外观（后台「🎨 登录页」里配的）
    var login: LoginBrand?
}

struct LoginBrand: Decodable, Hashable {
    var accent: String?
    var accent2: String?
    var disabledAccent: String?
    var disabledGray: String?
    var bg: String?
    var card: String?
    var text: String?
    var sub: String?
    var bgImage: String?
    var appName: String?
    var subTitle: String?
    var logo: String?
    var terms: String?
    var privacy: String?
}



struct PlusItem: Decodable, Identifiable, Hashable {
    var id: String?
    var label: String?
    var icon: String?
    var action: String?
    var enabled: Bool?
}

struct Gift: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var icon: String?
    var price: Double?
    var category: String?
}

struct StickerPack: Decodable, Hashable {
    var id: String?
    var name: String?
    var icon: String?
    var stickers: [String]?
}

struct StatusItem: Decodable, Hashable {
    var id: String?
    var icon: String?
    var label: String?
    var color: String?
    var color2: String?
}

struct StatusCategory: Decodable, Hashable {
    var id: String?
    var name: String?
    var items: [StatusItem]?
}

/// 发现页的一行（后台可以自由增删改）
struct DiscoverItem: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var icon: String?
    var svg: String?
    var color: String?
    var action: String?
    var group: Int?
    var enabled: Bool?
}

private struct StickersPayload: Decodable { var packs: [StickerPack]? }
private struct StatusesPayload: Decodable { var categories: [StatusCategory]? }
private struct DiscoverPayload: Decodable { var items: [DiscoverItem] }

/* ---------------- 服务页（我 → 服务，后台「服务页」模块下发） ---------------- */

/// 绿卡的一半：收付款 / 钱包
struct ServiceHalf: Decodable, Hashable {
    var label: String
    var sub: String?
    var icon: String?
    var svg: String?
    var action: String?
}

/// 绿卡本身（底色 + 左右两半）
struct ServiceCard: Decodable, Hashable {
    var enabled: Bool?
    var bg: String?
    var left: ServiceHalf?
    var right: ServiceHalf?
}

/// 一个分类：标题 + 里面的格子（格子复用发现页那套字段）
/// 版块只给「上 / 下」两个值（块与块之间的空隙；nil = 用默认：上 0 / 下 8）
struct ServiceGroupStyle: Decodable, Hashable {
    var gapTop: Double?
    var gapBottom: Double?
}

struct ServiceGroup: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var enabled: Bool?
    var style: ServiceGroupStyle?
    var items: [DiscoverItem]?
}

/// 服务页的样式：绿卡背景图 / 图标大小 / 各处字体的大小和颜色（后台「服务页 → 样式」里配）
struct ServiceStyle: Decodable, Hashable {
    var cardImage: String?
    var cardTextColor: String?
    var cardTextSize: Double?
    var cardSubSize: Double?
    var curSize: Double?
    var cardSubOpacity: Double?
    var iconSize: Double?
    var gridTitleSize: Double?
    var gridTitleColor: String?
    var gridTextSize: Double?
    var gridTextColor: String?
    var maskAmount: Bool?       // 绿卡右边的零钱打成 ¥****
    var maskReveal: Bool?       // 点一下能不能看

    /// 默认值 = 照参考图量出来的那套
    var icon: CGFloat { CGFloat(iconSize ?? 28) }
    var cardNameSize: CGFloat { CGFloat(cardTextSize ?? 18) }
    var cardSubSizeV: CGFloat { CGFloat(cardSubSize ?? 12) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    var cardSubOpacityV: Double { cardSubOpacity ?? 0.5 }
    var titleSize: CGFloat { CGFloat(gridTitleSize ?? 14) }
    var textSize: CGFloat { CGFloat(gridTextSize ?? 13) }
    var cardText: Color { Color(hexString: cardTextColor ?? "#FFFFFF", fallback: 0xFFFFFF) }
    /// 标题颜色：还是默认值就跟主题走（浅色 #7A7A7A / 深色 #8A8A8A）
    var titleColor: Color {
        let v = (gridTitleColor ?? "#7A7A7A").uppercased()
        if v == "#7A7A7A" { return Color.dyn(0x7A7A7A, 0x8A8A8A) }
        return Color(hexString: v, fallback: 0x7A7A7A)
    }
    /// 格子文字颜色：留空就跟主题
    var gridText: Color {
        if let c = gridTextColor, !c.isEmpty { return Color(hexString: c, fallback: 0x191919) }
        return C.label
    }
    /// 尺寸变了，卡片和格子跟着长，不把字挤出去
    var cardHeight: CGFloat { 144 + (icon - 28) + (cardNameSize - 18) + (cardSubSizeV - 12) }
    var cellHeight: CGFloat { 92 + (icon - 28) + (textSize - 13) }
    var titleHeight: CGFloat { 48 + (titleSize - 14) }
}

/// 整页服务页的配置
struct ServiceConfig: Decodable, Hashable {
    var title: String?
    var card: ServiceCard?
    var style: ServiceStyle?
    var groups: [ServiceGroup]?
}

/* ---------------- 钱包页（我 → 服务 → 钱包，后台「钱包页」模块下发） ---------------- */

/// 钱包页的一行
struct WalletItem: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var value: String?
    var valueKind: String?      // "balance" = 这一行的数值现算这个人的零钱
    var note: String?           // 小字，比如「收益率 1.01%」
    var icon: String?
    var svg: String?
    var color: String?
    var action: String?
    var mask: Bool?             // 这一行的金额要不要打星号
    var enabled: Bool?
}

/// 钱包页的一张白卡
struct WalletGroup: Decodable, Identifiable, Hashable {
    var id: String
    var enabled: Bool?
    var items: [WalletItem]?
}

/// 右上角那个按钮（默认是「账单」）
struct WalletRight: Decodable, Hashable {
    var label: String?
    var action: String?
}

/// 底部的蓝色链接（身份信息 / 支付设置）
struct WalletFoot: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var action: String?
    var enabled: Bool?
}

/// 钱包页的样式（行高 / 图标 / 字体 / 颜色）
struct WalletStyle: Decodable, Hashable {
    var rowHeight: Double?
    var iconSize: Double?
    var iconLeft: Double?
    var textLeft: Double?
    var rightInset: Double?
    var labelSize: Double?
    var valueSize: Double?
    var curSize: Double?
    var noteSize: Double?
    var footerSize: Double?
    var groupGap: Double?
    var dividerInset: Double?
    var labelColor: String?
    var valueColor: String?
    var noteColor: String?
    var footerColor: String?
    var maskAmount: Bool?       // 金额打成 ¥****
    var maskReveal: Bool?       // 点一下能不能看

    var row: CGFloat { CGFloat(rowHeight ?? 56.3) }
    var icon: CGFloat { CGFloat(iconSize ?? 20) }
    var iconX: CGFloat { CGFloat(iconLeft ?? 18) }
    var textX: CGFloat { CGFloat(textLeft ?? 56.7) }
    var rightPad: CGFloat { CGFloat(rightInset ?? 18) }
    var labelFont: CGFloat { CGFloat(labelSize ?? 17) }
    var valueFont: CGFloat { CGFloat(valueSize ?? 16) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    var noteFont: CGFloat { CGFloat(noteSize ?? 13) }
    var footFont: CGFloat { CGFloat(footerSize ?? 13) }
    var gap: CGFloat { CGFloat(groupGap ?? 12) }
    var divider: CGFloat { CGFloat(dividerInset ?? 56) }
    /// 行标题：留空就跟主题
    var labelColorV: Color {
        if let c = labelColor, !c.isEmpty { return Color(hexString: c, fallback: 0x191919) }
        return C.label
    }
    var valueColorV: Color {
        let v = (valueColor ?? "#1A1A1A").uppercased()
        if v == "#1A1A1A" { return C.label }
        return Color(hexString: v, fallback: 0x1A1A1A)
    }
    var noteColorV: Color { Color(hexString: noteColor ?? "#FA9D3B", fallback: 0xFA9D3B) }
    var footerColorV: Color { Color(hexString: footerColor ?? "#576B95", fallback: 0x576B95) }
    /// 金额打星号（默认开）
    var mask: Bool { maskAmount ?? true }
    var canReveal: Bool { maskReveal ?? true }
}

/// 整页钱包页的配置
struct WalletConfig: Decodable, Hashable {
    var title: String?
    var right: WalletRight?
    var groups: [WalletGroup]?
    var footer: [WalletFoot]?
    var style: WalletStyle?
    var balance: Double?
}

/* ---------------- 账单（钱包页右上角「账单」进来，数据来自 /api/bills） ---------------- */

/// 一条账单（就是一笔转账，带对方是谁）
struct BillRecord: Decodable, Identifiable, Hashable {
    var id: String
    var chatId: String?
    var amount: Double
    var note: String?
    var method: String?
    var status: String?
    var createdAt: String?
    var expiresAt: Double?
    var receivedAt: String?
    var refundedAt: String?
    var direction: String?          // out = 我转出去 / in = 别人转给我
    var peerId: String?
    var peerName: String?
    var peerAvatar: String?

    var mine: Bool { direction != "in" }
    var peer: String { (peerName?.isEmpty == false) ? peerName! : "好友" }
    var stateText: String {
        let st = status ?? "pending"
        if mine {
            if st == "received" { return "对方已收款" }
            if st == "refunded" { return "已退回" }
            return "待对方收款"
        }
        if st == "received" { return "已收款" }
        if st == "refunded" { return "已退回" }
        return "待收款"
    }
}

/// 账单汇总（in 是关键字，映射成 inSum）
struct BillSummary: Decodable, Hashable {
    var out: Double
    var inSum: Double
    var pendingOut: Int
    var pendingIn: Int
    var count: Int

    enum CodingKeys: String, CodingKey {
        case out
        case inSum = "in"
        case pendingOut, pendingIn, count
    }
}

struct BillsPayload: Decodable, Hashable {
    var bills: [BillRecord]
    var months: [String]?
    var summary: BillSummary?
    var month: String?
    var style: BillsPageStyle?
    var faq: [BalanceFaq]?
}

/// 账单页外观（后台「账单页」里调）
struct BillsPageStyle: Decodable, Hashable {
    var iconSize: Double?
    var titleSize: Double?
    var timeSize: Double?
    var amountSize: Double?
    var curSize: Double?
    var amountWeight: Double?
    var showCur: Bool?
    var monthSize: Double?
    var sumSize: Double?
    var rowHeight: Double?

    var icon: CGFloat { CGFloat(iconSize ?? 48) }
    var titleFont: CGFloat { CGFloat(titleSize ?? 17) }
    var timeFont: CGFloat { CGFloat(timeSize ?? 13) }
    var amountFont: CGFloat { CGFloat(amountSize ?? 16) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    /// 金额字重：300 细 / 400 常规 / 500 中 / 600 粗（账单页默认 400，比钱包页细）
    var amountWeightV: Font.Weight {
        switch Int(amountWeight ?? 400) {
        case ..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        default: return .semibold
        }
    }
    /// 每行金额要不要带 ¥（默认不带，参考图里只显示 +/− 和数字）
    var showCurV: Bool { showCur ?? false }
    var monthFont: CGFloat { CGFloat(monthSize ?? 15) }
    var sumFont: CGFloat { CGFloat(sumSize ?? 13) }
    var row: CGFloat { CGFloat(rowHeight ?? 80) }
}

/* ---------------- 零钱页（钱包页点「零钱」进来，后台「零钱页」模块下发） ---------------- */

struct BalanceButton: Decodable, Hashable {
    var label: String?
    var action: String?
}

struct BalanceLink: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var action: String?
    var enabled: Bool?
}

struct BalanceFaq: Decodable, Hashable {
    var q: String
    var a: String
}

struct BalanceStyle: Decodable, Hashable {
    var bg: String?
    var circleSize: Double?
    var circleColor: String?
    var yenSize: Double?
    var yenColor: String?
    var titleSize: Double?
    var amountSize: Double?
    var curSize: Double?
    var noteSize: Double?
    var noteColor: String?
    var padTop: Double?
    var gapTitle: Double?
    var gapAmount: Double?
    var gapNote: Double?
    var btnWidth: Double?
    var btnHeight: Double?
    var btnRadius: Double?
    var rechargeBg: String?
    var rechargeInk: String?
    var withdrawBg: String?
    var withdrawInk: String?
    var linkSize: Double?
    var linkColor: String?
    var footerSize: Double?
    var footerColor: String?

    var circle: CGFloat { CGFloat(circleSize ?? 64) }
    var yenFont: CGFloat { CGFloat(yenSize ?? 24) }
    var titleFont: CGFloat { CGFloat(titleSize ?? 18) }
    var amountFont: CGFloat { CGFloat(amountSize ?? 64) }
    var curFont: CGFloat { CGFloat(curSize ?? 28) }
    var noteFont: CGFloat { CGFloat(noteSize ?? 16) }
    var topPad: CGFloat { CGFloat(padTop ?? 60) }
    var gapTitleV: CGFloat { CGFloat(gapTitle ?? 24) }
    var gapAmountV: CGFloat { CGFloat(gapAmount ?? 16) }
    var gapNoteV: CGFloat { CGFloat(gapNote ?? 20) }
    var btnW: CGFloat { CGFloat(btnWidth ?? 183.7) }
    var btnH: CGFloat { CGFloat(btnHeight ?? 47.7) }
    var btnR: CGFloat { CGFloat(btnRadius ?? 8) }
    var linkFont: CGFloat { CGFloat(linkSize ?? 13) }
    var footFont: CGFloat { CGFloat(footerSize ?? 12) }
    /* 后台配的颜色当浅色用，深色模式自动给对应的深色（后台也能写 "#浅色|#深色" 自己定两套）。
       以前这些是写死的单色 —— 深色模式下整页还是白的，就是这儿。 */
    var pageBg: Color { colorDyn(bg, light: 0xFFFFFF, dark: 0x0B0B0D) }
    var circleColorV: Color { colorDyn(circleColor, light: 0xFFD100, dark: 0xFFD100) }
    var yenColorV: Color { colorDyn(yenColor, light: 0xFFFFFF, dark: 0xFFFFFF) }
    var noteColorV: Color { colorDyn(noteColor, light: 0xEB9400, dark: 0xEB9400) }
    var rechargeBgV: Color { colorDyn(rechargeBg, light: 0x07C160, dark: 0x3EB575) }
    var rechargeInkV: Color { colorDyn(rechargeInk, light: 0xFFFFFF, dark: 0xFFFFFF) }
    var withdrawBgV: Color { colorDyn(withdrawBg, light: 0xF2F2F2, dark: 0x2C2C2E) }
    var withdrawInkV: Color { colorDyn(withdrawInk, light: 0x313131, dark: 0xEDEDED) }
    var linkColorV: Color { colorDyn(linkColor, light: 0x576B95, dark: 0x7D90A9) }
    var footerColorV: Color { colorDyn(footerColor, light: 0xB3B3B3, dark: 0x8E8E93) }
}

struct BalancePageConfig: Decodable, Hashable {
    var navTitle: String?
    var title: String?
    var note: String?
    var recharge: BalanceButton?
    var withdraw: BalanceButton?
    var links: [BalanceLink]?
    var footer: String?
    var faq: [BalanceFaq]?
    var style: BalanceStyle?
    var balance: Double?
    var frozen: Double?
}

private struct PlusPayload: Decodable { var items: [PlusItem]? }
private struct GiftsPayload: Decodable { var gifts: [Gift]? }
private struct UploadPayload: Decodable {
    var url: String?
    var name: String?
    var bytes: Int?
    var image: Bool?
}

/* ============================================================ 网络 */

enum APIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// 局域网服务器用的是自签名证书，这里直接放行
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class API {
    static let shared = API()

    let session: URLSession
    private let trustDelegate = TrustAllDelegate()

    private(set) var token: String = ""
    private(set) var server: String = "aa.x8iu.com"

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg, delegate: trustDelegate, delegateQueue: nil)

        /* 老版本存过局域网地址（192.168.2.7:5443）的机器，自动升级到云端域名，
           否则装了新包也还在连电脑那台。用户手动改过别的地址就不动。 */
        if let saved = UserDefaults.standard.string(forKey: "chris.server"),
           !saved.isEmpty, saved != "192.168.2.7:5443", saved != "192.168.2.7" {
            server = API.normalizeServer(saved)
        } else {
            UserDefaults.standard.set(server, forKey: "chris.server")
        }
        // 令牌优先从钥匙串读（重装 App 也不掉），读不到再看老地方
        if let saved = Keychain.get("token") {
            token = saved
        } else if let saved = UserDefaults.standard.string(forKey: "chris.token") {
            token = saved
            Keychain.set(saved, for: "token")
        }
    }

    /* 一律走加密通道：http 会被同网段的人抓到账号密码。
       证书是自签的，但 App 里带了信任代理（TrustAllDelegate），所以不用装证书也能连。 */
    var base: String { "https://\(server)" }

    /// 把用户填的地址规范化：统一成 https + 5443（老地址 :5180 自动换成 :5443）
    static func normalizeServer(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.replacingOccurrences(of: "https://", with: "")
        v = v.replacingOccurrences(of: "http://", with: "")
        while v.hasSuffix("/") { v.removeLast() }
        if !v.contains(":") { v += ":5443" }
        v = v.replacingOccurrences(of: ":5180", with: ":5443")
        v = v.replacingOccurrences(of: ":80", with: ":5443")
        return v
    }

    func setServer(_ value: String) {
        let v = API.normalizeServer(value)
        guard !v.isEmpty else { return }
        server = v
        UserDefaults.standard.set(v, forKey: "chris.server")
    }

    func setToken(_ value: String) {
        token = value
        UserDefaults.standard.set(value, forKey: "chris.token")
        Keychain.set(value, for: "token")
    }

    func clearToken() {
        token = ""
        UserDefaults.standard.removeObject(forKey: "chris.token")
        Keychain.remove("token")
    }

    /// /uploads/xxx.png、http://…、data:… 都能转成可加载的地址
    func assetURL(_ path: String) -> URL? {
        if path.isEmpty { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        if path.hasPrefix("data:") { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + p)
    }

    /// 取图片专用的下载：**带上登录令牌**。
    /// 服务器对 /uploads 的规则是「要么带签名、要么本人已登录」，
    /// 以前这里用的是不带任何请求头的 session.data(from:)，所以只要拿到的是
    /// 没签名/签名过期的老链接，就一律 403 —— 表现就是「头像能看、背景全加载不出来」。
    func imageData(_ url: URL) async throws -> Data {
        try await assetData(url)
    }

    /// 取任意资源（图片 / 语音 / 文件）的字节：**带登录令牌**。
    /// 语音消息要先把 m4a 下载下来才能播（AVAudioPlayer 只能读本地文件）。
    func assetData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await session.data(for: req)
        return data
    }

    /* ---------------------------------------------------------- 底层请求 */

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: base + path) else {
            throw APIError.message("服务器地址不正确")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw APIError.message("连不上服务器（\(server)），检查手机是不是和电脑同一个 Wi-Fi")
        }
        let data = result.0
        let response = result.1

        if let http = response as? HTTPURLResponse,
           let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
           let range = raw.range(of: "chris_chat_session=") {
            let rest = raw[range.upperBound...]
            let value = rest.split(separator: ";").first.map(String.init) ?? ""
            if !value.isEmpty { setToken(value) }
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        guard let dict = obj as? [String: Any] else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        if (dict["ok"] as? Bool) != true {
            let msg = (dict["error"] as? String) ?? "请求失败"
            throw APIError.message(msg)
        }
        return dict["data"] ?? [String: Any]()
    }

    private func decode<T: Decodable>(_ any: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.message("数据解析失败")
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let any = try await request("GET", path)
        return try decode(any, as: T.self)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        let any = try await request("POST", path, body: body)
        return try decode(any, as: T.self)
    }

    private func patch<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        let any = try await request("PATCH", path, body: body)
        return try decode(any, as: T.self)
    }

    /* ---------------------------------------------------------- 业务接口 */

    func branding() async -> BrandInfo? {
        guard let payload: BrandingPayload = try? await get("/api/branding", as: BrandingPayload.self) else { return nil }
        return payload.branding
    }

    /* 服务器版本（「设置 → 版本更新」用）：拿不到就返回 nil */
    func serverVersion() async -> String? {
        struct VersionPayload: Decodable { var version: String? }
        guard let p: VersionPayload = try? await get("/api/version", as: VersionPayload.self) else { return nil }
        return p.version ?? ""
    }

    /// 后台配的「红点提醒」：某个位置 auto（按真实数据）/ on（一直亮）/ off（不显示）
    func badgeConfig() async -> [String: String] {
        guard let payload: BadgesPayload = try? await get("/api/badges", as: BadgesPayload.self) else { return [:] }
        return payload.badges ?? [:]
    }

    /// 服务器上的界面配置（data/ui.json）+ 换过的 UI 图标（data/icons.json）
    func uiConfig() async -> (ui: [String: Any], icons: [String: String]) {
        guard let any = try? await request("GET", "/api/ui"),
              let dict = any as? [String: Any] else { return ([:], [:]) }
        let ui = dict["ui"] as? [String: Any] ?? [:]
        var icons: [String: String] = [:]
        if let raw = dict["icons"] as? [String: Any] {
            for (k, v) in raw where !k.hasPrefix("_") {
                if let s = v as? String, !s.isEmpty { icons[k] = s }
            }
        }
        return (ui, icons)
    }

    /// 把真实量到的尺寸报回服务器（只用来对着参考图校准，不影响使用）
    func reportMeasure(_ items: [[String: Any]]) async {
        _ = try? await request("POST", "/api/measure", body: [
            "screen": Double(L.width),
            "safeTop": Double(L.safeTop),
            "safeBottom": Double(L.safeBottom),
            "menuH": Double(L.menuH),
            "chatRowH": Double(L.rowH),
            "ctRowH": Double(L.ctRowH),
            "items": items
        ])
    }

    func login(username: String, password: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/login",
                                                   ["username": username, "password": password],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    /// 账号被禁用后的「身份证自助解封」：服务器校验 18 位身份证（含校验位），
    /// 通过就解封并把登录态直接发下来，所以调完这个就等于登录成功了。
    @discardableResult
    func unban(username: String, password: String, idCard: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/unban",
                                                   ["username": username, "password": password, "idCard": idCard],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("解封失败") }
        return user
    }

    /// 本地没接短信通道，服务器会直接把验证码给回来
    func phoneCode(phone: String) async throws -> String? {
        let payload: PhoneCodePayload = try await post("/api/login/phone-code",
                                                       ["phone": phone],
                                                       as: PhoneCodePayload.self)
        return payload.devCode
    }

    /// 注册用的图形验证码（服务器给的是 SVG，App 里用 CaptchaView 画出来）
    func captcha() async throws -> (id: String, svg: String) {
        let payload: CaptchaPayload = try await get("/api/captcha", as: CaptchaPayload.self)
        return (payload.id ?? "", payload.svg ?? "")
    }

    /// 注册新账号（注册完成后由调用方再去登录一次）
    func register(username: String, nickname: String, password: String, captchaId: String, captcha: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/register", [
            "username": username,
            "nickname": nickname,
            "password": password,
            "captchaId": captchaId,
            "captcha": captcha
        ], as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("注册失败") }
        return user
    }

    /* ---------------- 设备确认登录（就是「微信登录」那个核心按钮）----------------
       这台设备出一个 6 位数字，在已经登录的设备上确认，这台就登上了。 */
    func pairStart() async throws -> (code: String, expiresIn: Int) {
        let p: PairStartPayload = try await post("/api/pair/start", [:], as: PairStartPayload.self)
        return (p.code ?? "", p.expiresIn ?? 180)
    }

    /// 轮询：pending（还没确认）/ approved（确认了，带回登录令牌）/ expired
    func pairStatus(code: String) async throws -> (status: String, user: User?, token: String?) {
        let p: PairStatusPayload = try await get("/api/pair/status?code=\(code)", as: PairStatusPayload.self)
        return (p.status ?? "pending", p.user, p.token)
    }

    /// 已登录的这台设备去确认别人（网页版点「微信授权登录」出的那个数字）
    @discardableResult
    func pairApprove(code: String) async -> String? {
        do {
            struct ApprovePayload: Decodable { var approved: Bool? }
            let _: ApprovePayload = try await post("/api/pair/approve", ["code": code], as: ApprovePayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "确认失败" }
    }

    func loginPhone(phone: String, code: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/login/phone",
                                                   ["phone": phone, "code": code],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    func session() async throws -> (ok: Bool, user: User?) {
        let payload: SessionPayload = try await get("/api/session", as: SessionPayload.self)
        return (payload.authenticated ?? false, payload.user)
    }

    func logout() async {
        _ = try? await request("POST", "/api/logout", body: [:])
        clearToken()
    }

    func me() async throws -> User? {
        let payload: MePayload = try await get("/api/me", as: MePayload.self)
        return payload.user
    }

    /// 个人名片要的完整资料（带 relation / online / phone / momentCount）
    func user(id: String) async throws -> User {
        let payload: UserPayload = try await get("/api/users/\(id)", as: UserPayload.self)
        guard let user = payload.user else { throw APIError.message("用户不存在") }
        return user
    }

    /* ---------------------------------------------------------- 附近的人 */

    /// 上报自己的位置（进「附近的人」页时调一次）；visible=false 就是隐身，不上榜
    func nearbyReport(lat: Double, lng: Double, visible: Bool = true) async throws {
        _ = try await request("POST", "/api/nearby", body: [
            "lat": lat, "lng": lng, "visible": visible
        ])
    }

    /// 附近的人名单（按距离排）
    func nearby(lat: Double?, lng: Double?, gender: String = "all", maxKm: Double = 5)
        async throws -> (people: [NearbyPerson], wider: Int, maxKm: Double) {
        var path = "/api/nearby?gender=\(gender)&maxKm=\(maxKm)"
        if let lat = lat, let lng = lng { path += "&lat=\(lat)&lng=\(lng)" }
        let payload: NearbyPayload = try await get(path, as: NearbyPayload.self)
        return (payload.people, payload.wider ?? 0, payload.maxKm ?? maxKm)
    }

    /// 打招呼：给对方发一条消息（会话就出来了）
    func nearbyHello(userId: String, text: String) async throws -> String {
        let payload: NearbyHelloPayload = try await post("/api/nearby/hello",
                                                         ["userId": userId, "text": text],
                                                         as: NearbyHelloPayload.self)
        return payload.chatId ?? ""
    }

    /// 清除自己的位置（从附近的人里消失，和微信的「清除位置信息并退出」一样）
    func nearbyClear() async throws {
        _ = try await request("DELETE", "/api/nearby")
    }

    /* ---------------------------------------------------------- 直播专场 */

    func liveRooms() async throws -> [LiveRoom] {
        let p: LivePayload = try await get("/api/live", as: LivePayload.self)
        return p.rooms
    }
    func liveJoin(_ id: String) async throws -> Int {
        let p: LiveJoinPayload = try await post("/api/live/\(id)/join", [:], as: LiveJoinPayload.self)
        return p.watching ?? 0
    }
    func liveLeave(_ id: String) async {
        _ = try? await request("POST", "/api/live/\(id)/leave", body: [:])
    }
    func liveDanmaku(_ id: String, text: String) async throws {
        _ = try await request("POST", "/api/live/\(id)/danmaku", body: ["text": text])
    }
    func liveLike(_ id: String) async throws -> Int {
        let p: LiveLikePayload = try await post("/api/live/\(id)/like", [:], as: LiveLikePayload.self)
        return p.likes ?? 0
    }

    /* ---------------------------------------------------------- 游戏页 */

    func games() async throws -> [MiniGame] {
        let p: GamesPayload = try await get("/api/games", as: GamesPayload.self)
        return p.items
    }

    /* ---------------------------------------------------------- 视频号 */

    func feedItems() async throws -> [FeedItem] {
        let p: FeedPayload = try await get("/api/feed", as: FeedPayload.self)
        return p.items
    }
    /// 只看自己发布的作品（「我 → 作品」那一页用）
    func myFeedItems() async throws -> [FeedItem] {
        let p: FeedPayload = try await get("/api/feed?mine=1", as: FeedPayload.self)
        return p.items
    }
    /// 列表 + 后台配的样式和开关
    /// tab: recommend 推荐（抖音那套）/ follow 关注 / friends 朋友
    func feed(tab: String = "recommend") async throws -> (items: [FeedItem], style: FeedStyle, flags: FeedFlags) {
        let p: FeedPayload = try await get("/api/feed?tab=\(tab)", as: FeedPayload.self)
        return (p.items, p.style ?? FeedStyle(), p.flags ?? FeedFlags())
    }
    func feedLike(_ id: String) async throws -> (liked: Bool, likes: Int) {
        let p: FeedLikePayload = try await post("/api/feed/like", ["id": id], as: FeedLikePayload.self)
        return (p.liked ?? false, p.likes ?? 0)
    }
    func feedComment(_ id: String, text: String) async throws -> Int {
        let p: FeedCommentPayload = try await post("/api/feed/comment", ["id": id, "text": text],
                                                   as: FeedCommentPayload.self)
        return p.comments ?? 0
    }
    func feedPublish(video: String, desc: String, music: String) async throws -> String {
        let p: FeedPublishPayload = try await post("/api/feed/publish",
                                                   ["video": video, "desc": desc, "music": music],
                                                   as: FeedPublishPayload.self)
        return p.id ?? ""
    }
    func feedDelete(_ id: String) async {
        _ = try? await request("DELETE", "/api/feed/\(id)")
    }
    /// 剪水印：把带水印的那条边裁掉，返回新视频地址（服务端 ffmpeg 处理）
    func feedTrim(_ url: String, top: Double, bottom: Double, left: Double, right: Double) async throws -> String {
        let p: FeedTrimPayload = try await post("/api/feed/trim",
                                                ["url": url, "top": top, "bottom": bottom,
                                                 "left": left, "right": right, "fill": true],
                                                as: FeedTrimPayload.self)
        return p.url ?? url
    }

    /* ---------------------------------------------------------- 摇一摇 */

    /// 摇一下：把自己「正在摇」报上去，服务器把同时摇的人配给我
    func shake(lat: Double?, lng: Double?) async throws -> ShakeResult {
        var body: [String: Any] = [:]
        if let lat = lat, let lng = lng { body["lat"] = lat; body["lng"] = lng }
        return try await post("/api/shake", body, as: ShakeResult.self)
    }

    /// 通话诊断：连不上时把 ICE 状态报回服务器（写进 call-trace.log）
    func callDiag(_ text: String) async {
        _ = try? await request("POST", "/api/call-diag", body: ["text": text])
    }

    func chats() async throws -> [Chat] {
        let payload: ChatsPayload = try await get("/api/chats", as: ChatsPayload.self)
        return payload.chats
    }

    /// 按「微信号 / 手机号」精确找人（转账页填收款账号用）
    func findUserByAccount(_ q: String) async throws -> User? {
        let payload: UsersPayload = try await get("/api/users?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)", as: UsersPayload.self)
        return payload.users.first
    }

    /// 拿一对一会话（转账需要 chatId）；不是好友会报错
    func directChat(userId: String) async throws -> Chat {
        let payload: ChatPayload = try await post("/api/chats/direct", ["userId": userId], as: ChatPayload.self)
        guard let chat = payload.chat else { throw APIError.message("会话创建失败") }
        return chat
    }

    func messages(chatId: String, limit: Int = 40, before: Int? = nil) async throws -> (chat: Chat?, messages: [Message], hasMore: Bool) {
        var path = "/api/chats/\(chatId)/messages?limit=\(limit)"
        if let before = before { path += "&before=\(before)" }
        let payload: MessagesPayload = try await get(path, as: MessagesPayload.self)
        return (payload.chat, payload.messages, payload.hasMore ?? false)
    }

    func send(chatId: String, text: String) async throws -> Message? {
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     ["kind": "text", "content": text],
                                                     as: MessagePayload.self)
        return payload.message
    }

    /* 群聊信息页：群成员资料（顺序和九宫格群头像一致，群主排第一） */
    func chatMembers(chatId: String) async throws -> (members: [User], ownerId: String, createdAt: String) {
        let p: ChatMembersPayload = try await get("/api/chats/\(chatId)/members", as: ChatMembersPayload.self)
        return (p.members ?? [], p.ownerId ?? "", p.createdAt ?? "")
    }

    /* 置顶聊天 / 取消置顶（群聊信息页那一行） */
    @discardableResult
    func setPinned(chatId: String, pinned: Bool) async -> Bool {
        let p: PinPayload? = try? await post("/api/chats/\(chatId)/pin",
                                             ["pinned": pinned], as: PinPayload.self)
        return p?.pinned ?? pinned
    }

    /* ---------------- 群管理（对应功能清单里的群名称/群公告/群屏蔽/踢人/解散）---------------- */

    /// 改群名称 / 群公告（只有群主）。返回错误文案，nil = 成功
    @discardableResult
    func updateChatInfo(chatId: String, name: String, announce: String) async -> String? {
        do {
            let _: ChatInfoPayload = try await patch("/api/chats/\(chatId)/info",
                                                     ["name": name, "announce": announce], as: ChatInfoPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "保存失败" }
    }

    /// 消息免打扰（群屏蔽）：每个人自己设
    @discardableResult
    func setMuted(chatId: String, muted: Bool) async -> Bool {
        let p: MutePayload? = try? await post("/api/chats/\(chatId)/mute", ["muted": muted], as: MutePayload.self)
        return p?.muted ?? muted
    }

    /// 群主把某个成员移出群聊
    @discardableResult
    func kickMember(chatId: String, userId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/kick",
                                                       ["userId": userId], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "移出失败" }
    }

    /// 群二维码：拿到邀请码和二维码 SVG
    /// 我的二维码（每个人一张，扫了能加好友）
    /* ---------------- 隐私 / 消息通知 ---------------- */
    func privacy() async -> PrivacySettings {
        struct Payload: Decodable {
            var privacy: Raw?; var notify: Raw?
            struct Raw: Decodable {
                var needVerify: Bool?; var strangerMoments: Bool?
                var addByWx: Bool?; var addByPhone: Bool?; var addByGroup: Bool?; var addByQR: Bool?
            }
        }
        guard let p: Payload = try? await get("/api/me/privacy", as: Payload.self), let r = p.privacy
        else { return PrivacySettings() }
        var s = PrivacySettings()
        s.needVerify = r.needVerify ?? true
        s.strangerMoments = r.strangerMoments ?? false
        s.addByWx = r.addByWx ?? true
        s.addByPhone = r.addByPhone ?? true
        s.addByGroup = r.addByGroup ?? true
        s.addByQR = r.addByQR ?? true
        return s
    }

    func setPrivacy(_ key: String, _ value: Bool) async {
        _ = try? await request("PATCH", "/api/me/privacy", body: [key: value])
    }

    func notifySettings() async -> NotifySettings {
        struct Payload: Decodable {
            var notify: Raw?
            struct Raw: Decodable {
                var on: Bool?; var sound: Bool?; var vibrate: Bool?; var showDetail: Bool?
                var muteStart: String?; var muteEnd: String?
            }
        }
        guard let p: Payload = try? await get("/api/me/privacy", as: Payload.self), let r = p.notify
        else { return NotifySettings() }
        var s = NotifySettings()
        s.on = r.on ?? true
        s.sound = r.sound ?? true
        s.vibrate = r.vibrate ?? true
        s.showDetail = r.showDetail ?? true
        s.muteStart = r.muteStart ?? ""
        s.muteEnd = r.muteEnd ?? ""
        return s
    }

    func setNotify(_ fields: [String: Any]) async {
        _ = try? await request("PATCH", "/api/me/notify", body: fields)
    }

    func myQRCode() async -> (code: String, url: String, rows: [String], user: User?) {
        struct MyQRPayload: Decodable {
            var code: String?; var url: String?; var rows: [String]?; var user: User?
        }
        guard let p: MyQRPayload = try? await get("/api/me/qrcode", as: MyQRPayload.self)
        else { return ("", "", [], nil) }
        return (p.code ?? "", p.url ?? "", p.rows ?? [], p.user)
    }

    /// 扫到别人的个人二维码：加好友。返回 (提示文案, 对方)
    func addByCode(_ code: String) async -> (message: String, user: User?) {
        struct AddPayload: Decodable {
            var sent: Bool?; var already: Bool?; var pending: Bool?; var accepted: Bool?; var user: User?
        }
        do {
            let p: AddPayload = try await post("/api/add-by-code", ["code": code], as: AddPayload.self)
            let msg = p.already == true ? "你们已经是好友了"
                : (p.pending == true ? "已经发过申请了，等对方通过"
                   : (p.accepted == true ? "对方之前加过你，现在已经是好友" : "好友申请已发出"))
            return (msg, p.user)
        } catch {
            return ((error as? APIError)?.errorDescription ?? "加好友失败", nil)
        }
    }

    func groupInvite(chatId: String) async -> (code: String, url: String, rows: [String]) {
        struct InvitePayload: Decodable { var code: String?; var url: String?; var svg: String?; var rows: [String]? }
        guard let p: InvitePayload = try? await post("/api/chats/\(chatId)/invite", [:], as: InvitePayload.self)
        else { return ("", "", []) }
        return (p.code ?? "", p.url ?? "", p.rows ?? [])
    }

    /// 扫码（打开链接）进群
    @discardableResult
    func joinByInvite(code: String) async -> String? {
        do {
            _ = try await post("/api/join", ["code": code], as: SendPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "进群失败" }
    }

    /// 全员禁言（群主）
    @discardableResult
    func setMuteAll(chatId: String, on: Bool) async -> String? {
        do {
            struct MuteAllPayload: Decodable { var muteAll: Bool? }
            let _: MuteAllPayload = try await post("/api/chats/\(chatId)/muteall", ["on": on], as: MuteAllPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "设置失败" }
    }

    /// 禁言 / 取消禁言某个群成员（群主）
    @discardableResult
    func setMemberMuted(chatId: String, userId: String, muted: Bool) async -> String? {
        do {
            _ = try await post("/api/chats/\(chatId)/mutemember",
                               ["userId": userId, "muted": muted], as: SendPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "设置失败" }
    }

    /// 退出群聊（群主退群会自动把群主交给下一个人）
    @discardableResult
    func leaveGroup(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/leave", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "退群失败" }
    }

    /// 解散群聊（只有群主）
    @discardableResult
    func dismissGroup(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/dismiss", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "解散失败" }
    }

    /// 清空聊天记录（只清自己这边）
    @discardableResult
    func clearChat(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/clear", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "清空失败" }
    }

    /// 查找聊天记录：在服务器上翻整个会话的历史
    func searchMessages(chatId: String, query: String) async -> [FoundMessage] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let p: SearchPayload = try? await get("/api/chats/\(chatId)/search?q=\(q)", as: SearchPayload.self)
        else { return [] }
        return p.messages
    }

    /* ---------------- 银行卡 ---------------- */

    func bankCards() async -> [BankCard] {
        let p: BankCardsPayload? = try? await get("/api/me/bankcards", as: BankCardsPayload.self)
        return p?.cards ?? []
    }

    @discardableResult
    func addBankCard(bank: String, number: String, holder: String) async -> String? {
        do {
            let _: BankCardsPayload = try await post("/api/me/bankcards",
                                                     ["bank": bank, "number": number, "holder": holder],
                                                     as: BankCardsPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "绑定失败" }
    }

    @discardableResult
    func deleteBankCard(id: String) async -> String? {
        do {
            _ = try await request("DELETE", "/api/me/bankcards/\(id)")
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "解绑失败" }
    }

    /* ---------------- 意见反馈 / 密码找回 ---------------- */

    @discardableResult
    func sendFeedback(content: String, contact: String) async -> String? {
        do {
            let _: SendPayload = try await post("/api/feedback",
                                                ["content": content, "contact": contact, "platform": "iOS"],
                                                as: SendPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "提交失败" }
    }

    /// 密码找回：手机号 + 验证码 + 新密码。
    /// 成功后返回这个账号的用户名（App 用用户名+新密码再登一次，就进 App 了）
    func resetPassword(phone: String, code: String, newPassword: String) async -> (username: String, error: String?) {
        do {
            let p: LoginPayload = try await post("/api/login/reset",
                                                 ["phone": phone, "code": code, "newPassword": newPassword],
                                                 as: LoginPayload.self)
            return (p.user?.username ?? "", nil)
        } catch { return ("", (error as? APIError)?.errorDescription ?? "重置失败") }
    }

    func markRead(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/read", body: [:])
    }

    func markUnread(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/unread", body: [:])
    }

    /// 清空聊天记录 + 从列表里移除（微信的「删除」）。返回错误文案，nil = 成功
    @discardableResult
    func deleteChat(chatId: String) async -> String? {
        await deleteChat(path: "/api/chats/\(chatId)?clear=1")
    }

    /// 不显示该聊天：只从自己的列表里移除，对方不受影响。返回错误文案，nil = 成功
    @discardableResult
    func hideChat(chatId: String) async -> String? {
        await deleteChat(path: "/api/chats/\(chatId)")
    }

    private func deleteChat(path: String) async -> String? {
        do {
            _ = try await request("DELETE", path)
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "操作失败"
        }
    }

    func openDirect(userId: String) async throws -> Chat? {
        let payload: ChatPayload = try await post("/api/chats/direct", ["userId": userId], as: ChatPayload.self)
        return payload.chat
    }

    func contacts() async throws -> [User] {
        let payload: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return payload.friends
    }

    func contactsFull() async throws -> (friends: [User], incoming: [User]) {
        let payload: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return (payload.friends, payload.incoming ?? [])
    }

    private struct BadgeCountsPayload: Decodable { var friendRequests: Int?; var momentUnread: Int? }
    /// 红点数字（很轻的接口）：回到前台 / 定时兜底查一下，防止漏推送
    func badgeCounts() async -> (friendRequests: Int, momentUnread: Int)? {
        guard let p = try? await get("/api/badge-counts", as: BadgeCountsPayload.self) else { return nil }
        return (p.friendRequests ?? 0, p.momentUnread ?? 0)
    }

    func respondFriend(_ requestId: String, accept: Bool) async {
        _ = try? await request("POST", "/api/friends/respond",
                               body: ["requestId": requestId, "accept": accept])
    }

    func createGroup(name: String, memberIds: [String]) async throws -> Chat? {
        let payload: ChatPayload = try await post("/api/chats/group",
                                                  ["name": name, "memberIds": memberIds],
                                                  as: ChatPayload.self)
        return payload.chat
    }

    func recharge(_ amount: Double) async throws -> Double {
        struct RechargePayload: Decodable { var balance: Double? }
        let payload: RechargePayload = try await post("/api/me/recharge",
                                                      ["amount": amount],
                                                      as: RechargePayload.self)
        return payload.balance ?? 0
    }

    func claimTransfer(_ id: String) async {
        _ = try? await request("POST", "/api/transfers/\(id)/claim", body: [:])
    }

    func favorites() async -> [[String: Any]] {
        guard let any = try? await request("GET", "/api/favorites"),
              let dict = any as? [String: Any],
              let list = dict["favorites"] as? [[String: Any]] else { return [] }
        return list
    }

    /// 收藏一条聊天内容（长按消息 → 收藏）
    @discardableResult
    func addFavorite(kind: String, content: String, title: String = "", from: String = "") async -> Bool {
        let ok = try? await request("POST", "/api/favorites", body: [
            "kind": kind, "content": content, "title": title, "from": from
        ])
        return ok != nil
    }

    func changeBackground(_ path: String) async {
        await updateMe(["chatBackground": path])
    }

    func moments(limit: Int = 20, userId: String? = nil) async throws -> [Moment] {
        var path = "/api/moments?limit=\(limit)"
        if let userId = userId, !userId.isEmpty { path += "&userId=\(userId)" }
        let payload: MomentsPayload = try await get(path, as: MomentsPayload.self)
        return payload.moments
    }

    /// 朋友圈首页要的完整信息：列表 + 有没有新的（「发现」上的小红点）+ 还有没有更多
    ///（before = 上一页最后一条的时间，用来往下翻页）
    func momentsFeed(limit: Int = 20, before: String? = nil, beforeId: String? = nil, userId: String? = nil)
        async throws -> (moments: [Moment], unread: Int, total: Int, hasMore: Bool) {
        var path = "/api/moments?limit=\(limit)"
        if let before = before, !before.isEmpty { path += "&before=\(before)" }
        if let beforeId = beforeId, !beforeId.isEmpty { path += "&beforeId=\(beforeId)" }
        if let userId = userId, !userId.isEmpty { path += "&userId=\(userId)" }
        let payload: MomentsPayload = try await get(path, as: MomentsPayload.self)
        return (payload.moments, payload.unread ?? 0, payload.total ?? payload.moments.count, payload.hasMore ?? false)
    }

    /* ---------------------------------------------------------- 更多接口 */

    func plusPanel() async throws -> [PlusItem] {
        let payload: PlusPayload = try await get("/api/plus-panel", as: PlusPayload.self)
        return (payload.items ?? []).filter { $0.enabled != false }
    }

    func gifts() async throws -> [Gift] {
        let payload: GiftsPayload = try await get("/api/gifts", as: GiftsPayload.self)
        return payload.gifts ?? []
    }

    func stickerPacks() async throws -> [StickerPack] {
        let payload: StickersPayload = try await get("/api/stickers", as: StickersPayload.self)
        return payload.packs ?? []
    }

    func statusCategories() async throws -> [StatusCategory] {
        let payload: StatusesPayload = try await get("/api/statuses", as: StatusesPayload.self)
        return payload.categories ?? []
    }

    /// 发现页那几行（后台配的，网页版和 App 共用一份）
    func discover() async throws -> [DiscoverItem] {
        let payload: DiscoverPayload = try await get("/api/discover", as: DiscoverPayload.self)
        return payload.items.filter { $0.enabled != false }
    }

    /// 我页下面那几行（同样是后台配的）
    func mePage() async throws -> [DiscoverItem] {
        let payload: DiscoverPayload = try await get("/api/me-page", as: DiscoverPayload.self)
        return payload.items.filter { $0.enabled != false }
    }

    /// 服务页整页配置（后台「服务页」模块配的，网页版和 App 共用一份）
    func serviceConfig() async throws -> ServiceConfig {
        try await get("/api/service", as: ServiceConfig.self)
    }

    /// 钱包页整页配置（后台「钱包页」模块配的；零钱那一行的数值是现算的余额）
    func walletConfig() async throws -> WalletConfig {
        try await get("/api/wallet", as: WalletConfig.self)
    }

    /// 安全分（微信「支付分」那套：550~850 · 身份特质 / 支付行为 / 守约历史）
    func securityScore() async throws -> CreditScore {
        try await get("/api/me/score", as: CreditScorePayload.self).score
    }

    /// 账单：这个人所有的转账（wallet 页右上角「账单」用），可按月筛
    func bills(month: String? = nil) async throws -> BillsPayload {
        var path = "/api/bills"
        if let m = month, !m.isEmpty {
            path += "?month=" + m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        }
        return try await get(path, as: BillsPayload.self)
    }

    /// 零钱页（钱包页点「零钱」进来）
    func balancePage() async throws -> BalancePageConfig {
        try await get("/api/balance-page", as: BalancePageConfig.self)
    }

    /// 设置/清除「状态」（对应后台配的那些状态）
    func setMood(_ item: StatusItem?) async {
        if let item = item {
            await updateMe([
                "moodText": item.label ?? "",
                "moodIcon": item.icon ?? "",
                "moodColor": item.color ?? "",
                "moodColor2": item.color2 ?? ""
            ])
        } else {
            await updateMe(["moodText": "", "moodIcon": "", "moodColor": "", "moodColor2": ""])
        }
    }

    /// 图片压完再传：返回服务器上的 /uploads/xxx.jpg
    func upload(image: UIImage) async throws -> String {
        let data = image.resizedJPEG(maxSide: 1600, quality: 0.82)
        return try await uploadData(data)
    }

    /// 聊天背景：比头像清楚得多（长边 2048、画质 0.95）。
    /// 视频/大文件走二进制直传（不再 base64，少传 25%，手机上快一截）
    /// 给播放器的资源：带上鉴权头，让 AVPlayer 自己边下边播（服务器已支持 Range 分片）
    func streamingAsset(_ path: String) -> AVURLAsset? {
        guard let u = assetURL(path) else { return nil }
        let headers: [String: String] = token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
        return AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func uploadBinary(_ data: Data, mime: String) async throws -> String {
        guard let url = URL(string: base + "/api/upload/raw") else { throw APIError.message("服务器地址不正确") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (d, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.message("上传失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        struct RawUpload: Decodable { var url: String? }
        let parsed = try? JSONDecoder().decode(RawUpload.self, from: d)
        if let u = parsed?.url, !u.isEmpty { return u }
        /* 服务器返回的是 {ok,data:{url}} 这种包装，兜底再解一层 */
        struct Wrapper: Decodable { struct D: Decodable { var url: String? }; var data: D? }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: d), let u = w.data?.url, !u.isEmpty { return u }
        throw APIError.message("上传返回异常")
    }

    /// 注意别设太大：一张 4800 万的相册原图直接按 4096 重绘会把内存打爆闪退。
    func uploadOriginal(image: UIImage) async throws -> String {
        let data = image.resizedJPEG(maxSide: 2048, quality: 0.95)
        return try await uploadData(data)
    }

    private func uploadData(_ data: Data?) async throws -> String {
        guard let data = data else {
            throw APIError.message("图片处理失败")
        }
        let b64 = data.base64EncodedString()
        let payload: UploadPayload = try await post("/api/upload",
                                                    ["dataUrl": "data:image/jpeg;base64," + b64,
                                                     "filename": "photo.jpg"],
                                                    as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return url
    }

    func send(chatId: String, kind: String, content: String) async throws -> Message? {
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     ["kind": kind, "content": content],
                                                     as: MessagePayload.self)
        return payload.message
    }

    func recall(chatId: String, messageId: String) async {
        _ = try? await request("POST", "/api/messages/\(messageId)/recall", body: ["chatId": chatId])
    }

    func likeMoment(id: String) async {
        _ = try? await request("POST", "/api/moments/\(id)/like", body: [:])
    }

    /// 打开朋友圈 = 看过了，「发现」上的红点清掉
    func markMomentsSeen() async {
        _ = try? await request("POST", "/api/moments/seen", body: [:])
    }

    func commentMoment(id: String, text: String) async {
        _ = try? await request("POST", "/api/moments/\(id)/comments", body: ["content": text])
    }

    func deleteMoment(id: String) async {
        _ = try? await request("DELETE", "/api/moments/\(id)")
    }

    /// 发朋友圈：谁可以看（public 公开 / private 仅自己 / partial 部分可见 / exclude 不给谁看）
    func postMoment(content: String, images: [String],
                    visibility: String = "public",
                    visibleTo: [String] = [], hiddenFrom: [String] = []) async throws {
        _ = try await request("POST", "/api/moments", body: [
            "content": content, "images": images,
            "visibility": visibility, "visibleTo": visibleTo, "hiddenFrom": hiddenFrom
        ])
    }

    func updateMe(_ fields: [String: Any]) async {
        _ = try? await request("PATCH", "/api/me", body: fields)
    }

    func addFriend(username: String, from: String = "") async throws {
        var body: [String: Any] = ["username": username]
        if !from.isEmpty { body["from"] = from }
        _ = try await request("POST", "/api/friends/request", body: body)
    }

    func rawUpload(_ body: [String: Any]) async throws -> (url: String, name: String, bytes: Int) {
        let payload: UploadPayload = try await post("/api/upload", body, as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return (url, payload.name ?? "", payload.bytes ?? 0)
    }

    func transfer(chatId: String, amount: Double, note: String,
                  method: String, password: String, face: Bool = false) async throws {
        _ = try await request("POST", "/api/pay/transfer", body: [
            "chatId": chatId,
            "amount": amount,
            "note": note,
            "method": method,
            "password": password,
            "face": face
        ])
    }

    func hasPayPassword() async -> Bool {
        guard let any = try? await request("GET", "/api/me/paypassword"),
              let dict = any as? [String: Any],
              let has = dict["has"] as? Bool else { return false }
        return has
    }

    /// 校验支付密码（转账确认用）
    func verifyPayPassword(_ password: String) async throws {
        _ = try await request("POST", "/api/me/paypassword/verify", body: ["password": password])
    }

    /// 设置 / 修改支付密码（6 位数字；已经设过的要带上原密码）
    func setPayPassword(_ password: String, current: String = "") async throws {
        var body: [String: Any] = ["password": password]
        if !current.isEmpty { body["current"] = current }
        _ = try await request("POST", "/api/me/paypassword", body: body)
    }

    /// 举报某人（后台「举报处理」里能看到）
    func report(userId: String, chatId: String, reason: String, content: String) async {
        _ = try? await request("POST", "/api/reports", body: [
            "targetUserId": userId,
            "chatId": chatId,
            "reason": reason,
            "content": content
        ])
    }
}

extension UIImage {
    /// 上传前压一下：长边最多 maxSide，JPEG 质量 quality
    func resizedJPEG(maxSide: CGFloat, quality: CGFloat) -> Data? {
        let long = max(size.width, size.height)
        var target = size
        if long > maxSide {
            let k = maxSide / long
            target = CGSize(width: size.width * k, height: size.height * k)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let out = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: quality)
    }
}

