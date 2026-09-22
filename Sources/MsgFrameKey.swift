import SwiftUI

/// 每条消息在屏幕上的位置（长按弹的小方框靠它贴到那条消息旁边）
struct MsgFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
}
