//
//  EventEditView.swift
//  Follo AI
//
//  Created by GitHub Copilot on 2025/9/4.
//

import SwiftUI
import EventKit
import UIKit

@available(iOS 16.0, *)
struct EventEditView: View {
    enum Action { case saved, deleted, cancelled }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var provider: CalendarEventProvider
    @ObservedObject private var timeZoneManager = TimeZoneManager.shared
    @State var event: EKEvent

    var onComplete: (Action) -> Void

    // Local editing fields
    @State private var title: String = ""
    @State private var location: String = ""
    @State private var urlString: String = ""
    @State private var notes: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(3600)
    @State private var isAllDay: Bool = false
    @State private var color: Color = .blue

    // Predefined type colors; user can customize via picker
    private let colorChoices: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal, .indigo, .brown, .gray]

    init(provider: CalendarEventProvider, event: EKEvent, onComplete: @escaping (Action) -> Void) {
        self.provider = provider
        _event = State(initialValue: event)
        self.onComplete = onComplete
        // Initialize state from event
        _title = State(initialValue: event.title)
        _location = State(initialValue: event.location ?? "")
        _urlString = State(initialValue: event.url?.absoluteString ?? "")
    _notes = State(initialValue: stripColorTag(from: event.notes ?? ""))
        _startDate = State(initialValue: event.startDate)
        _endDate = State(initialValue: event.endDate)
        _isAllDay = State(initialValue: event.isAllDay)
    _color = State(initialValue: event.harvestNoteOverrideColor ?? event.harvestDisplayColor)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("标题")) {
                    TextField("请输入标题", text: $title)
                }

                Section(header: Text("位置或视频通话")) {
                    TextField("位置", text: $location)
                    TextField("视频/会议链接", text: $urlString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                }

                Section(header: Text("时间")) {
                    Toggle("全天", isOn: $isAllDay)
                        .onChange(of: isAllDay) { oldValue, newValue in
                            if newValue {
                                // snap to day range
                                let dayStart = timeZoneManager.currentCalendar().startOfDay(for: startDate)
                                startDate = dayStart
                                endDate = dayStart.addingTimeInterval(24*3600 - 60)
                            }
                        }
                    DatePicker("开始", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: startDate) { oldValue, newValue in
                            if endDate <= newValue { endDate = newValue.addingTimeInterval(30*60) }
                        }
                    DatePicker("结束", selection: $endDate, in: startDate..., displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    
                    // 显示时区信息
                    if !isAllDay {
                        HStack {
                            Text("时区")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(timeZoneManager.getTimeZoneInfo())
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }

                Section(header: Text("类型与颜色")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(colorChoices, id: \.self) { c in
                            Circle()
                                .fill(c)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(c == color ? 0.6 : 0.2), lineWidth: c == color ? 3 : 1)
                                )
                                .onTapGesture { color = c }
                        }
                    }
                }

                Section(header: Text("备注")) {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                }

                // 参与者（只读展示）
                Section(header: Text("参与者")) {
                    if let attendees = event.attendees, !attendees.isEmpty || event.organizer != nil {
                        if let org = event.organizer?.name, !org.isEmpty {
                            HStack {
                                Image(systemName: "person.text.rectangle")
                                Text("组织者：")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(org)
                            }
                        }
                        ForEach(attendees, id: \.self) { p in
                            HStack {
                                Image(systemName: "person")
                                Text(p.name ?? "未知")
                                Spacer()
                                Text(displayStatus(p.participantStatus))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("无参与者信息")
                            .foregroundColor(.secondary)
                    }
                }

                if event.harvestIsNew { EmptyView() } else {
                    Section {
                        Button(role: .destructive) { deleteEvent() } label: {
                            Label("删除日程", systemImage: "trash")
                        }
                    }
                }
        }
        .navigationTitle(event.harvestIsNew ? "新建日程" : "编辑日程")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 确保时区信息是最新的
            timeZoneManager.updateTimeZoneInfo()
        }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss(); onComplete(.cancelled) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { saveEvent() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveEvent() {
        // Apply fields back to EKEvent
        event.title = title
        event.location = location.isEmpty ? nil : location
        if let url = URL(string: urlString), !urlString.isEmpty { event.url = url } else { event.url = nil }
        // Upsert color tag into notes for custom type color
        let mergedNotes = upsertColorTag(color: color, into: notes)
        event.notes = mergedNotes.isEmpty ? nil : mergedNotes
        event.isAllDay = isAllDay
        event.startDate = startDate
        event.endDate = endDate
        // Persist color by choosing a calendar with closest color if possible
        if let targetCal = provider.calendar(closestTo: color, current: event.calendar) {
            event.calendar = targetCal
        }
        do {
            try provider.save(event: event)
            dismiss()
            onComplete(.saved)
        } catch {
            // Basic alert fallback
            // In a real app, present an Alert. Here we just dismiss.
            dismiss()
            onComplete(.cancelled)
        }
    }

    private func deleteEvent() {
        do {
            try provider.delete(event: event)
            dismiss()
            onComplete(.deleted)
        } catch {
            dismiss()
            onComplete(.cancelled)
        }
    }
}

extension EKEvent {
    var harvestIsNew: Bool { self.eventIdentifier == nil }
    // Namespaced to avoid conflicts with SDK
    var harvestDisplayColor: Color {
        if let override = self.harvestNoteOverrideColor { return override }
        if let cg = self.calendar?.cgColor { return Color(cgColor: cg) }
        return .blue
    }
    // If notes contain our tag, use it as the color
    var harvestNoteOverrideColor: Color? {
        guard let notes = self.notes else { return nil }
        if let hex = extractColorHex(from: notes), let ui = UIColor(harvestHex: hex) {
            return Color(uiColor: ui)
        }
        return nil
    }
}

@available(iOS 16.0, *)
private func displayStatus(_ status: EKParticipantStatus) -> String {
    switch status {
    case .accepted: return "已接受"
    case .declined: return "已拒绝"
    case .tentative: return "待定"
    case .unknown: return "未知"
    case .pending: return "待处理"
    @unknown default: return "未知"
    }
}

// Note helpers and color encoding/decoding
private let colorTagPrefix = "[harvest-color="

private func extractColorHex(from notes: String) -> String? {
    guard let range = notes.range(of: colorTagPrefix) else { return nil }
    let rest = notes[range.upperBound...]
    guard let end = rest.firstIndex(of: "]") else { return nil }
    let value = rest[..<end]
    let hex = String(value)
    if hex.hasPrefix("#") { return hex }
    return "#" + hex
}

// Remove any [harvest-color=#RRGGBB] tag occurrences from notes for clean editing UI
private func stripColorTag(from notes: String) -> String {
    var text = notes
    while let start = text.range(of: colorTagPrefix) {
        let rest = text[start.upperBound...]
        if let end = rest.firstIndex(of: "]") {
            let tagRange = start.lowerBound..<text.index(after: end)
            text.removeSubrange(tagRange)
            // Remove a single trailing newline if present (when tag was on its own line)
            if text.first == "\n" { text.removeFirst() }
            // Also trim redundant leading/trailing whitespace lines left by removal
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            break
        }
    }
    return text
}

private func upsertColorTag(color: Color, into notes: String) -> String {
    let hex = color.toHexString()
    let tag = "\(colorTagPrefix)\(hex)]"
    var text = notes
    if let existingHex = extractColorHex(from: notes) {
        text = notes.replacingOccurrences(of: "\(colorTagPrefix)\(existingHex)]", with: tag)
    } else {
        // Prepend tag on first line
        if notes.isEmpty {
            text = tag
        } else {
            text = tag + "\n" + notes
        }
    }
    return text
}

private extension Color {
    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(r * 255)), gi = Int(round(g * 255)), bi = Int(round(b * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

private extension UIColor {
    convenience init?(harvestHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
