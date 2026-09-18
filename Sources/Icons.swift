import SwiftUI

/// 图标全部从网页版 m.html 里原样抄过来，保证和手机微信/网页版长得一样
enum I {

    // ---------------- 导航 / 搜索 ----------------
    static let plusRing = """
    <svg data-key="i.plusRing" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.45" stroke-linecap="round"><circle cx="12" cy="12" r="9.15"/><path d="M12 7.7v8.6M7.7 12h8.6"/></svg>
    """

    static let searchSmall = """
    <svg data-key="i.searchSmall" viewBox="3.4 3.4 17.4 17.4" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.3"/><path d="M15.3 15.3l4.3 4.3"/></svg>
    """

    static let searchBig = """
    <svg data-key="i.searchBig" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="6.4"/><path d="M15.8 15.8L20.5 20.5"/></svg>
    """

    // ---------------- 通讯录顶部几个功能 ----------------
    static let newFriends = """
    <svg data-key="i.newFriends" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="10.4" cy="8.6" r="3.4"/><path d="M4.4 19c0-3 2.7-5 6-5s6 2 6 5"/><path d="M18.4 8.4v4.6M16.1 10.7h4.6"/></svg>
    """
    static let chatOnly = """
    <svg data-key="i.chatOnly" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M19.6 12c0 3.4-3.4 6.2-7.6 6.2-.8 0-1.6-.1-2.4-.3l-3.7 1.7 1.1-3.1C5.6 15.2 4.4 13.7 4.4 12c0-3.4 3.4-6.2 7.6-6.2s7.6 2.8 7.6 6.2z"/></svg>
    """
    static let tag = """
    <svg data-key="i.tag" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M11.4 4.4h6.2a2 2 0 0 1 2 2v6.2l-8.4 8.4a2 2 0 0 1-2.8 0L4 16.6a2 2 0 0 1 0-2.8z"/><circle cx="15.4" cy="8.6" r="1.3" fill="#fff" stroke="none"/></svg>
    """
    static let service = """
    <svg data-key="i.service" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.4"/><path d="M8.6 12.6l2.4 2.4 4.6-5"/></svg>
    """
    static let workMate = """
    <svg data-key="i.workMate" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="9.4" r="3.4"/><path d="M5.6 19.4c0-3.2 2.9-5.4 6.4-5.4s6.4 2.2 6.4 5.4"/></svg>
    """
    static let myWork = """
    <svg data-key="i.myWork" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4.4" y="8.4" width="15.2" height="10.4" rx="2.2"/><path d="M9.4 8.4V6.6h5.2v1.8M12 11.6v3.6M10.2 13.4h3.6"/></svg>
    """

    // ---------------- 发现页 ----------------
    static let moments = """
    <svg data-key="i.moments" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="3.3"/><circle cx="4.6" cy="6.2" r="2.05"/><circle cx="19.4" cy="6.2" r="2.05"/><circle cx="4.6" cy="17.8" r="2.05"/><circle cx="19.4" cy="17.8" r="2.05"/></svg>
    """
    static let channels = """
    <svg data-key="i.channels" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="5.4" width="17.6" height="13.2" rx="2.8"/><path d="M10.4 9.4l4.6 2.6-4.6 2.6z"/></svg>
    """
    static let live = """
    <svg data-key="i.live" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M6.6 6.6a7.6 7.6 0 0 0 0 10.8M17.4 17.4a7.6 7.6 0 0 0 0-10.8M3.9 3.9a11.4 11.4 0 0 0 0 16.2M20.1 20.1a11.4 11.4 0 0 0 0-16.2"/></svg>
    """
    static let scan = """
    <svg data-key="i.scan" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8.6V6a2 2 0 0 1 2-2h2.6M15.4 4H18a2 2 0 0 1 2 2v2.6M20 15.4V18a2 2 0 0 1-2 2h-2.6M8.6 20H6a2 2 0 0 1-2-2v-2.6"/><path d="M4 12h16"/></svg>
    """
    static let shake = """
    <svg data-key="i.shake" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="7.4" y="3.6" width="9.2" height="16.8" rx="2.4"/><path d="M12 7.2v3M4.6 9.6v4.8M19.4 9.6v4.8"/></svg>
    """
    static let look = """
    <svg data-key="i.look" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M2.6 12S6 6.4 12 6.4 21.4 12 21.4 12 18 17.6 12 17.6 2.6 12 2.6 12z"/><circle cx="12" cy="12" r="2.8"/></svg>
    """
    static let searchRow = """
    <svg data-key="i.searchRow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><circle cx="11" cy="11" r="6.4"/><path d="M15.8 15.8L20.5 20.5"/></svg>
    """
    static let nearby = """
    <svg data-key="i.nearby" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21.2s6.6-5.9 6.6-10.4A6.6 6.6 0 0 0 5.4 10.8c0 4.5 6.6 10.4 6.6 10.4z"/><circle cx="12" cy="10.6" r="2.5"/></svg>
    """
    static let game = """
    <svg data-key="i.game" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.8" y="7.2" width="18.4" height="9.6" rx="4.2"/><path d="M7.4 10.4v3.2M5.8 12h3.2M15.6 11.2h.01M17.8 13.4h.01"/></svg>
    """
    static let miniApp = """
    <svg data-key="i.miniApp" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M7.8 14.8c1.6-2.8 3-4.5 5-6.2M16.2 9.2c-1.6 2.8-3 4.5-5 6.2"/></svg>
    """

    // ---------------- 我页 ----------------
    static let qr = """
    <svg data-key="i.qr" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.4" y="3.4" width="6.4" height="6.4" rx="1.4"/><rect x="14.2" y="3.4" width="6.4" height="6.4" rx="1.4"/><rect x="3.4" y="14.2" width="6.4" height="6.4" rx="1.4"/><path d="M14.2 14.2h3.2v3.2h-3.2zM20.6 14.2v6.4M17.4 20.6h3.2"/></svg>
    """
    static let wallet = """
    <svg data-key="i.wallet" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="5.6" width="17.6" height="12.8" rx="2.6"/><path d="M3.6 9.6h16.8"/><path d="M9.4 12.6l2.6 2.6 2.6-2.6M12 10.8v4.4"/></svg>
    """
    static let star = """
    <svg data-key="i.star" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6.6 4.6h10.8v15.2L12 16.4l-5.4 3.4z"/><path d="M12 7.4l1.2 2.4 2.6.4-1.9 1.8.5 2.6-2.4-1.3-2.4 1.3.5-2.6-1.9-1.8 2.6-.4z"/></svg>
    """
    static let album = """
    <svg data-key="i.album" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M12 3.4v17.2M3.4 12h17.2"/><circle cx="12" cy="12" r="3.2"/></svg>
    """
    static let works = """
    <svg data-key="i.works" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.4" y="5" width="17.2" height="14" rx="2.6"/><path d="M10.4 9.6l4.4 2.8-4.4 2.8z"/></svg>
    """
    static let sticker = """
    <svg data-key="i.sticker" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M8.6 14.2a4.4 4.4 0 0 0 6.8 0"/><circle cx="9.2" cy="9.8" r="0.95" fill="currentColor" stroke="none"/><circle cx="14.8" cy="9.8" r="0.95" fill="currentColor" stroke="none"/></svg>
    """
    static let gear = """
    <svg data-key="i.gear" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.1"/><path d="M12 3.4v2.2M12 18.4v2.2M4.8 7.6l1.9 1.1M17.3 15.3l1.9 1.1M4.8 16.4l1.9-1.1M17.3 8.7l1.9-1.1"/></svg>
    """

    // ---------------- 聊天输入栏 ----------------
    static let voice = """
    <svg data-key="i.voice" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10.8"/><rect x="9.8" y="5.9" width="4.4" height="7.4" rx="2.2"/><path d="M8.5 11.3a3.5 3.5 0 0 0 7 0"/><path d="M12 15.2v2.1"/></svg>
    """
    static let smile = """
    <svg data-key="i.smile" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10.8"/><path d="M8.4 14.2a4.2 4.2 0 0 0 7.2 0"/><circle cx="9.3" cy="9.5" r="1.1" fill="currentColor" stroke="none"/><circle cx="14.7" cy="9.5" r="1.1" fill="currentColor" stroke="none"/></svg>
    """
    static let plusCircle = """
    <svg data-key="i.plusCircle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="10.8"/><path d="M12 7.5v9M7.5 12h9"/></svg>
    """
    static let speaker = """
    <svg data-key="i.speaker" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4.4 9.6h3.1L12 5.5v13L7.5 14.4H4.4z"/><path d="M15.6 9.7a3.5 3.5 0 0 1 0 4.6"/><path d="M18.2 7.5a7.1 7.1 0 0 1 0 9"/></svg>
    """
    static let deleteKey = """
    <svg data-key="i.deleteKey" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9.2 5.4h9.3a2.6 2.6 0 0 1 2.6 2.6v8a2.6 2.6 0 0 1-2.6 2.6H9.2L2.9 12z"/><path d="M12.7 9.6l4.8 4.8M17.5 9.6l-4.8 4.8"/></svg>
    """

    // ---------------- 朋友圈 ----------------
    static let backCover = """
    <svg data-key="i.backCover" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M16.2 4.1L8.9 12l7.3 7.9"/></svg>
    """
    static let camera = """
    <svg data-key="i.camera" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3.4 8.9a2.1 2.1 0 0 1 2.1-2.1h1.8l1.3-1.9h6.8l1.3 1.9h1.8a2.1 2.1 0 0 1 2.1 2.1v7.6a2.1 2.1 0 0 1-2.1 2.1H5.5a2.1 2.1 0 0 1-2.1-2.1z"/><circle cx="12" cy="12.5" r="3.4"/></svg>
    """

    // ---------------- 通用 ----------------
    static let tick = """
    <svg data-key="i.tick" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.2"/></svg>
    """

    // 我页推荐位那张小图（可乐罐）
    static let coke = """
    <svg data-key="i.coke" viewBox="0 0 40 60"><path d="M14 6h12v6H14z" fill="#8e1c1c"/><path d="M11 12h18c2.2 0 4 1.8 4 4v34c0 2.2-1.8 4-4 4H11c-2.2 0-4-1.8-4-4V16c0-2.2 1.8-4 4-4z" fill="#e02020"/><path d="M7 30c6 3 20 3 26 0v10c-6 3-20 3-26 0z" fill="#fff"/><path d="M12 33c5 2 11 2 16 0v5c-5 2-11 2-16 0z" fill="#e02020"/></svg>
    """

    // ---------------- 「＋」面板 / 礼物面板 ----------------
    static let plusIcons: [String: String] = [
        "photo": #"<svg data-key="plus.photo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="4.8" width="17.6" height="14.4" rx="2.4"/><circle cx="8.6" cy="9.8" r="1.7"/><path d="M3.6 16.6l4.6-4.2 3.5 3.1 3-2.7 5.7 5"/></svg>"#,
        "camera": #"<svg data-key="plus.camera" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.2 8.6a2.2 2.2 0 0 1 2.2-2.2h2.1l1.4-2.1h6.2l1.4 2.1h2.1a2.2 2.2 0 0 1 2.2 2.2v8.4a2.2 2.2 0 0 1-2.2 2.2H5.4a2.2 2.2 0 0 1-2.2-2.2z"/><circle cx="12" cy="12.6" r="3.6"/></svg>"#,
        "video": #"<svg data-key="plus.video" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.8" y="6" width="12.6" height="12" rx="2.6"/><path d="M15.4 12.2l5.8-3.6v6.8l-5.8-3.2z"/></svg>"#,
        "location": #"<svg data-key="plus.location" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21.2s6.6-5.9 6.6-10.4A6.6 6.6 0 0 0 5.4 10.8c0 4.5 6.6 10.4 6.6 10.4z"/><circle cx="12" cy="10.6" r="2.5"/></svg>"#,
        "redpacket": #"<svg data-key="plus.redpacket" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="7.6" width="16" height="11.6" rx="2.2"/><path d="M4 7.6h16L12 13z"/><path d="M11 15.6h2M12 15.6v1.6"/></svg>"#,
        "gift": #"<svg data-key="plus.gift" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.6" y="9.6" width="16.8" height="10.8" rx="2.2"/><path d="M3.6 13.6h16.8M12 9.6v10.8"/><path d="M9.4 9.6c-1.9 0-2.9-1-2.9-2.2S7.6 5 9.1 5c1.9 0 2.9 2 2.9 4.6.1-2.6 1.1-4.6 3-4.6 1.5 0 2.6.6 2.6 1.8s-1 2.2-2.9 2.2z"/></svg>"#,
        "transfer": #"<svg data-key="plus.transfer" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 9.6h13.2l-3.2-3.4M20.4 14.4H7.2l3.2 3.4"/></svg>"#,
        "voice": #"<svg data-key="plus.voice" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="9.2" y="3.4" width="5.6" height="10.4" rx="2.8"/><path d="M5.8 11.4a6.2 6.2 0 0 0 12.4 0M12 17.8v2.8"/></svg>"#,
        "favorite": #"<svg data-key="plus.favorite" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.4l2.4 4.9 5.4.8-3.9 3.8.9 5.3-4.8-2.5-4.8 2.5.9-5.3-3.9-3.8 5.4-.8z"/></svg>"#,
        "card": #"<svg data-key="plus.card" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.4" y="4.6" width="17.2" height="14.8" rx="2.4"/><circle cx="9.2" cy="10.6" r="2"/><path d="M6.2 16.4c.5-1.7 1.7-2.6 3-2.6s2.5.9 3 2.6M14.6 10h3.6M14.6 13.4h3.6"/></svg>"#,
        "file": #"<svg data-key="plus.file" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6.4 3.6h7.2l4.4 4.4v12.4H6.4z"/><path d="M13.4 3.8v4.4h4.4"/></svg>"#,
        "music": #"<svg data-key="plus.music" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9.2 17.4V6.2l9.2-1.8v11"/><circle cx="6.9" cy="17.8" r="2.3"/><circle cx="16.1" cy="15.6" r="2.3"/></svg>"#,
        "coupon": #"<svg data-key="plus.coupon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 7.6h16.8v3a2.4 2.4 0 0 0 0 4.8v3H3.6v-3a2.4 2.4 0 0 0 0-4.8z"/><path d="M9.6 8.4v9.2"/></svg>"#,
        "chain": #"<svg data-key="plus.chain" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10.2 13.8a3.6 3.6 0 0 0 5.1 0l3-3a3.6 3.6 0 0 0-5.1-5.1l-1 1"/><path d="M13.8 10.2a3.6 3.6 0 0 0-5.1 0l-3 3a3.6 3.6 0 0 0 5.1 5.1l1-1"/></svg>"#,
        "vote": #"<svg data-key="plus.vote" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5.4 19.6V10M12 19.6V4.8M18.6 19.6v-6.2"/></svg>"#,
        "screen": #"<svg data-key="plus.screen" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="12" rx="2.2"/><path d="M9 20h6"/></svg>"#,
        "star": #"<svg data-key="plus.star" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.4l2.4 4.9 5.4.8-3.9 3.8.9 5.3-4.8-2.5-4.8 2.5.9-5.3-3.9-3.8 5.4-.8z"/></svg>"#,
        "heart": #"<svg data-key="plus.heart" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20s-7.2-4.4-7.2-9.4A4.2 4.2 0 0 1 12 7.8a4.2 4.2 0 0 1 7.2 2.8C19.2 15.6 12 20 12 20z"/></svg>"#,
        "link": #"<svg data-key="plus.link" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10.6 13.4a4 4 0 0 0 5.6 0l2.4-2.4a4 4 0 0 0-5.6-5.6"/><path d="M13.4 10.6a4 4 0 0 0-5.6 0l-2.4 2.4a4 4 0 0 0 5.6 5.6"/></svg>"#,
        "none": #"<svg data-key="plus.none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="12" cy="12" r="8.4"/><path d="M8.6 12h6.8"/></svg>"#
    ]

    static func plus(_ name: String?) -> String {
        plusIcons[name ?? ""] ?? plusIcons["star"] ?? ""
    }
}

/// 通讯录顶部那 6 个彩色方块
struct FuncIcon: View {
    let markup: String
    let bg: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg)
            SVGIcon(markup: markup, size: 22, color: .white)
        }
        .frame(width: size, height: size)
    }
}
