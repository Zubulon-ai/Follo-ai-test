import SwiftUI

struct AssistantsView: View {
    struct Assistant: Identifiable { let id = UUID(); let name: String; let status: String; let busy: Bool }
    private let assistants: [Assistant] = [
        .init(name: "佳琛的日程助手", status: "与佳琛的下次会议时间定…", busy: true),
        .init(name: "淑梓的日程助手", status: "淑梓给您发送了日程…", busy: false),
        .init(name: "昕恺的日程助手", status: "昕恺上次与您聊的节…", busy: false),
        .init(name: "恒宇的日程助手", status: "恒宇上次与您聊的节…", busy: true)
    ]

    var body: some View {
        List(assistants) { a in
            NavigationLink(destination: AssistantChatView(assistantDisplayName: a.name, recipientName: parseRecipient(from: a.name))) {
                HStack(spacing: 12) {
                    Image(systemName: a.busy ? "person.fill.badge.minus" : "person.fill.badge.checkmark")
                        .foregroundColor(a.busy ? .orange : .green)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.headline)
                        Text(a.status).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Circle().fill(a.busy ? Color.orange : Color.green).frame(width: 8, height: 8)
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("协作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func parseRecipient(from displayName: String) -> String {
        // 简单从"X 的日程助手"中抽取 X
        if let range = displayName.range(of: "的日程助手") {
            return String(displayName[..<range.lowerBound])
        }
        return displayName
    }
}

