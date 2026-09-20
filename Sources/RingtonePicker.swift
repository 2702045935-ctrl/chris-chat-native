import SwiftUI

/// 来电铃声选择：一行一个，点右边喇叭试听（放 4 秒自己停），点一行就是选中
struct RingtonePicker: View {
    @ObservedObject private var ring = Ringtone.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Ringtone.all) { tone in
                        Button {
                            ring.current = tone.id
                            ring.preview(tone.id)          // 选中顺便试听一下
                        } label: {
                            HStack(spacing: 10) {
                                Text(tone.name).foregroundColor(C.label)
                                Spacer()
                                if ring.previewing == tone.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(C.green)
                                }
                                if ring.current == tone.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(C.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("来电铃声")
                } footer: {
                    Text("点一下切换并试听；铃声是 App 里合成的，声音走外放，手机静音键也听得见。")
                }
            }
            .navigationTitle("来电铃声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        ring.stop()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { ring.stop() }
    }
}
