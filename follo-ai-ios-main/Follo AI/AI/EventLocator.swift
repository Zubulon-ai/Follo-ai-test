//
//  EventLocator.swift
//  Follo AI
//
//  本地定位待修改/删除的日程：解析 ModifyParser 返回，筛选候选并产出确认用数据
//

import Foundation
import EventKit

// 可选：文本嵌入提供者，用于语义相似度召回与精排
protocol TextEmbeddingProvider {
    func embed(texts: [String]) async throws -> [[Double]]
}

// MARK: - Modify Parser 返回结构
struct ModifyParserResult: Codable {
    struct Locators: Codable {
        let time_phrase: String?
        let time_iso: String?
        struct TimeWindow: Codable { let start: String?; let end: String? }
        let time_window: TimeWindow?
        let title_hint: [String]?
        let attendee_names: [String]?
        let location_hint: String?
        let scope_hint: String? // single|series|following|unspecified
    }
    struct Changes: Codable {
        let startTime: String?
        let endTime: String?
        let location: String?
        let meeting_mode: String?
        let add_names: [String]?
        let remove_names: [String]?
        let title: String?
        let notes: String?
    }

    // 构造发给 Modify Resolver 的候选 JSON（编号1/2/3）
    func buildCandidateJSON(for candidates: [LocatedEventCandidate]) -> String {
        let limited = Array(candidates.prefix(3))
        var arr: [[String: Any]] = []
        for (idx, c) in limited.enumerated() {
            arr.append([
                "no": idx+1,
                "title": c.title,
                "start": c.start,
                "end": c.end,
                "isAllDay": c.isAllDay,
                "location": c.location ?? "",
                "calendar": c.calendarTitle,
                "attendees": c.attendees ?? []
            ])
        }
        let dict: [String: Any] = ["candidates": arr]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
    let action: String // DELETE|UPDATE
    let locators: Locators
    let changes: Changes?
    let missing: [String]?
}

// MARK: - 候选展示模型（供 UI 展示卡片）
struct LocatedEventCandidate: Identifiable, Codable {
    let id: String // 使用 EKEvent.eventIdentifier
    let title: String
    let start: String
    let end: String
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
    let attendees: [String]?
    let score: Double
}

// MARK: - 定位器
final class EventLocator {
    private let store: EKEventStore
    private let embeddingProvider: TextEmbeddingProvider?
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()
    private let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()

    init(store: EKEventStore = GlobalEventStore.shared.store, embeddingProvider: TextEmbeddingProvider? = nil) {
        self.store = store
        self.embeddingProvider = embeddingProvider
    }

    // 移除重复定义：保持单一定义的 buildCandidateJSON(for:)
    // 构造发给 Modify Resolver 的候选 JSON（编号1/2/3），字段顺序：no、title、start、end、location、其余
    func buildCandidateJSON(for candidates: [LocatedEventCandidate]) -> String {
        struct CandidateItem: Encodable {
            let no: Int
            let title: String
            let start: String
            let end: String
            let location: String
            let isAllDay: Bool
            let calendar: String
            let attendees: [String]?
            enum CodingKeys: String, CodingKey { case no, title, start, end, location, isAllDay, calendar, attendees }
        }
        struct Wrapper: Encodable { let candidates: [CandidateItem] }
        let items: [CandidateItem] = Array(candidates.prefix(3)).enumerated().map { (idx, c) in
            CandidateItem(
                no: idx+1,
                title: c.title,
                start: c.start,
                end: c.end,
                location: c.location ?? "",
                isAllDay: c.isAllDay,
                calendar: c.calendarTitle,
                attendees: c.attendees
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(Wrapper(candidates: items)) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    // 仅基于用户原始话语定位（无上游解析）
    func locateFromUtterance(_ utterance: String, maxK: Int = 3, debug: Bool = false) async -> [LocatedEventCandidate] {
        // 从话语中抽取时间窗口（绝对日期/相对“上午/下午/晚上”等），否则默认七天
        let windows = buildTimeWindowsFromUtterance(utterance)
        let parserLike = ModifyParserResult(action: "UPDATE", locators: .init(time_phrase: nil, time_iso: nil, time_window: windows.first.map { .init(start: iso8601.string(from: $0.start), end: iso8601.string(from: $0.end)) }, title_hint: extractTitleHints(from: utterance), attendee_names: extractPeople(from: utterance), location_hint: extractLocation(from: utterance), scope_hint: "unspecified"), changes: nil, missing: nil)
        return await locateCandidates(from: parserLike, originalUtterance: utterance, maxK: maxK, debug: debug)
    }

    private func buildTimeWindowsFromUtterance(_ utterance: String) -> [DateInterval] {
        var wins: [DateInterval] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 1) 绝对日期/时间
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = utterance as NSString
            for m in detector.matches(in: utterance, options: [], range: NSRange(location: 0, length: ns.length)) {
                if let d = m.date {
                    let start = cal.startOfDay(for: d)
                    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
                    wins.append(DateInterval(start: start, end: end))
                }
            }
        }

        // 2) 时段词窗口（无日期时映射到“今天”）
        let lower = utterance.lowercased()
        func windowForPeriod(_ startHour: Int, _ endHour: Int) -> DateInterval {
            let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: today) ?? today
            // 使用持续小时数构造 end，避免 end < start 触发 DateInterval 断言
            let raw = endHour - startHour
            let durationHours = raw > 0 ? raw : (raw == 0 ? 1 : raw + 24) // 0 小时至少给 1 小时；负数视为跨日
            let end = cal.date(byAdding: .hour, value: durationHours, to: start) ?? start.addingTimeInterval(TimeInterval(durationHours * 3600))
            return DateInterval(start: start, end: end)
        }
        if lower.contains("上午") || lower.contains("早上") || lower.contains("清晨") {
            wins.append(windowForPeriod(9, 12))
        }
        if lower.contains("中午") || lower.contains("午间") {
            wins.append(windowForPeriod(12, 13))
        }
        if lower.contains("下午") || lower.contains("午后") {
            wins.append(windowForPeriod(13, 18))
        }
        if lower.contains("傍晚") || lower.contains("晚上") || lower.contains("今晚") || lower.contains("夜里") || lower.contains("深夜") {
            wins.append(windowForPeriod(17, 24))
        }
        if lower.contains("凌晨") || lower.contains("半夜") {
            wins.append(windowForPeriod(0, 6))
        }

        if wins.isEmpty { wins = [defaultSevenDayWindow()] }
        return wins
    }

    private func extractTitleHints(from utterance: String) -> [String]? {
        // 简单规则：提取中文/英文的连续字母数字串长度>=2
        let tokens = tokenize(utterance.lowercased()).filter { $0.count >= 2 }
        return tokens.isEmpty ? nil : Array(tokens.prefix(5))
    }

    private func extractPeople(from utterance: String) -> [String]? {
        // 朴素：
        // 1) 中文连接词后 2-4 个中文名
        // 2) 中文连接词后 英文名（1-3 段，字母/连字符/点/撇）
        // 3) 英文连接短语（with/meet/call… with <Name>）
        let patterns = [
            "与([\\u4e00-\\u9fa5]{2,4})",
            "和([\\u4e00-\\u9fa5]{2,4})",
            "跟([\\u4e00-\\u9fa5]{2,4})",
            // 中文连接词 + 英文名（可无空格）
            "(?:与|和|跟)\\s*([A-Za-z][A-Za-z\\-\\.'']{1,20}(?:\\s+[A-Za-z][A-Za-z\\-\\.'']{1,20}){0,2})",
        ]
        var ordered: [String] = []
        var seen = Set<String>()
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let ns = utterance as NSString
                for m in r.matches(in: utterance, range: NSRange(location: 0, length: ns.length)) {
                    if m.numberOfRanges > 1 {
                        let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                        if !raw.isEmpty && !seen.contains(raw) {
                            ordered.append(raw)
                            seen.insert(raw)
                        }
                    }
                }
            }
        }
        return ordered.isEmpty ? nil : ordered
    }

    private func extractLocation(from utterance: String) -> String? {
        // 朴素：匹配“会议室X/咖啡/线上”等关键词
        let lowers = utterance.lowercased()
        if lowers.contains("线上") || lowers.contains("zoom") || lowers.contains("teams") || lowers.contains("meet") { return "线上" }
        if lowers.contains("会议室") { return "会议室" }
        if lowers.contains("咖啡") { return "咖啡" }
        return nil
    }
    // 入口：根据 ModifyParserResult 与用户原始话语，返回 Top-K 候选
    func locateCandidates(from parser: ModifyParserResult, originalUtterance: String, maxK: Int = 6, debug: Bool = false) async -> [LocatedEventCandidate] {
        var logs: [String] = []
        func log(_ s: String) { if debug { logs.append(s) } }
        log("[EventLocator] ==== Begin ====")
        log("action=? (used by caller), utterance=\(originalUtterance)")
        // 是否包含明确时间词/日期提示（用于权重调节）
        let hasTimeHint = hasExplicitTimeHint(in: originalUtterance)
        // 1) 推导时间窗口
        let windows = buildTimeWindows(from: parser)
        // 若无时间，则使用默认 7 天窗口（今天±3 天）
        let usedDefaultWindow = windows.isEmpty
        let timeWindows = usedDefaultWindow ? [defaultSevenDayWindow()] : windows
        if debug {
            for (i, w) in timeWindows.enumerated() {
                log("timeWindow[#\(i)]: \(iso8601.string(from: w.start)) ~ \(iso8601.string(from: w.end))")
            }
        }

        // 2) 拉取并去重
        var seen = Set<String>()
        var pool: [EKEvent] = []
        for win in timeWindows {
            let predicate = store.predicateForEvents(withStart: win.start, end: win.end, calendars: nil)
            for ev in store.events(matching: predicate) {
                if let id = ev.eventIdentifier, !seen.contains(id) {
                    seen.insert(id)
                    pool.append(ev)
                }
            }
        }
        log("pool_size=\(pool.count)")

        // 3) 打分（规则 + 语义相似度）——相似度严格以“用户本次话语 utterance”为查询
        let loweredUtter = originalUtterance.lowercased()
        let titleMustRaw = (parser.locators.title_hint ?? []).map { $0.lowercased() }
        let titleMust = expandWithSynonyms(Set(titleMustRaw))
        let attendees = Set((parser.locators.attendee_names ?? []).map { $0.lowercased() })
        let locationHint = parser.locators.location_hint?.lowercased()

        func timeCenter() -> Date? {
            if let tw = parser.locators.time_window,
               let s = parseISO(tw.start), let e = parseISO(tw.end) { return Date(timeIntervalSince1970: (s.timeIntervalSince1970 + e.timeIntervalSince1970)/2) }
            if let iso = parser.locators.time_iso, let t = parseISO(iso) { return t }
            return nil
        }
        let center = timeCenter()

        // 语义相似度：尽量批量计算，避免频繁网络开销
        var semanticScores: [String: Double] = [:]
        if let provider = embeddingProvider, !pool.isEmpty {
            log("embedding_provider=ON, texts_count=\(pool.count+1)")
            let texts: [String] = [loweredUtter] + pool.map { ev in
                let title = ev.title ?? ""
                let notes = ev.notes ?? ""
                let loc = ev.location ?? ""
                return [title, notes, loc].joined(separator: "\n")
            }
            if let vecs = try? await provider.embed(texts: texts), vecs.count == texts.count {
                let q = vecs.first!
                log("embedding_dim=\(q.count)")
                for (idx, ev) in pool.enumerated() {
                    let v = vecs[idx+1]
                    let sim = cosine(q, v)
                    if let id = ev.eventIdentifier { semanticScores[id] = sim }
                }
                log("embedding_success=true")
                // 打印按语义相似度 Top-5（原始余弦）
                let topSem = pool.compactMap { ev -> (String, Double)? in
                    guard let id = ev.eventIdentifier else { return nil }
                    let sim = semanticScores[id] ?? -1
                    return ((ev.title ?? "(无标题)"), sim)
                }.sorted { $0.1 > $1.1 }.prefix(5)
                for (rank, item) in topSem.enumerated() {
                    log(String(format: "sem_top#%d cos=%.4f title='%@'", rank+1, item.1, item.0))
                }
            } else if let vecs = try? await provider.embed(texts: texts) {
                log("embedding_mismatch expected=\(texts.count) got=\(vecs.count)")
            } else {
                log("embedding_failed=true")
            }
        }

        // 当没有明确时间提示时，用语义分先粗筛，减少候选规模
        if (!hasTimeHint || usedDefaultWindow), !pool.isEmpty, !semanticScores.isEmpty {
            let sortedBySem: [EKEvent] = pool.sorted {
                let a = semanticScores[$0.eventIdentifier ?? ""] ?? -1
                let b = semanticScores[$1.eventIdentifier ?? ""] ?? -1
                return a > b
            }
            let cap = min(40, sortedBySem.count)
            pool = Array(sortedBySem.prefix(cap))
            log("semantic_prefilter=ON cap=\(cap)")
        }

        func score(_ ev: EKEvent) -> Double {
            var s: Double = 0
            let title = (ev.title ?? "").lowercased()
            let notes = (ev.notes ?? "").lowercased()
            var compMust = 0.0, compTokens = 0.0, compAtt = 0.0, compLocScore = 0.0, compTime = 0.0, compAllDay = 0.0, compSem = 0.0
            // 标题 must 词
            if !titleMust.isEmpty {
                let hitAll = titleMust.allSatisfy { title.contains($0) || notes.contains($0) }
                compMust = hitAll ? 2.0 : 0.0
                s += compMust
            }
            // 话语 token 命中（含同义词扩展）
            for token in expandWithSynonyms(Set(tokenize(loweredUtter))) {
                guard token.count >= 2 else { continue }
                if title.contains(token) { compTokens += 0.8 }
                if notes.contains(token) { compTokens += 0.4 }
            }
            s += compTokens
            // 参与者匹配：使用事件参与者列表（组织者+与会者）与话语中的人名进行对齐
            if !attendees.isEmpty {
                var eventNames: [String] = []
                if let org = ev.organizer?.name, !org.isEmpty { eventNames.append(org.lowercased()) }
                if let atts = ev.attendees { eventNames.append(contentsOf: atts.compactMap { $0.name?.lowercased() }.filter { !$0.isEmpty }) }
                let uniqueEventNames = Array(Set(eventNames))
                var matchCount = 0
                for q in attendees {
                    for en in uniqueEventNames {
                        if en.contains(q) || q.contains(en) { matchCount += 1; break }
                    }
                }
                if matchCount > 0 {
                    // 每个匹配 +1 分，最多加到 2 分
                    compAtt = min(2.0, Double(matchCount))
                    s += compAtt
                }
            }
            // 地点
            if let lh = locationHint, !lh.isEmpty {
                if (ev.location ?? "").lowercased().contains(lh) { compLocScore = 0.6; s += compLocScore }
            }
            // 时间接近度（若无明确时间提示，则不计入时间得分）
            if hasTimeHint, let c = center, let evStart = ev.startDate {
                let hours = abs(evStart.timeIntervalSince(c)) / 3600.0
                compTime = max(0, 3.0 - hours / 2.0) // 距离中心每 2 小时扣 1 分，最多 3 分
                s += compTime
            }
            // 全天匹配
            if parser.locators.time_phrase?.contains("全天") == true {
                if ev.isAllDay { compAllDay = 0.5; s += compAllDay } else { compAllDay = -0.2; s += compAllDay }
            }
            // 语义相似度（权重：默认 3.0；无明确时间提示时 10.0）
            var semRaw: Double = -1
            var semNorm: Double = 0
            if let id = ev.eventIdentifier, let sem = semanticScores[id] {
                semRaw = sem
                // 将 [-1,1] 的余弦映射到 [0,1] 再乘权重
                let normalized = max(0.0, (sem + 1.0) / 2.0)
                semNorm = normalized
                let semanticWeight = (!hasTimeHint) ? 20.0 : (usedDefaultWindow ? 6.0 : 10.0)
                compSem = normalized * semanticWeight
                s += compSem
            }
            if debug {
                let sStr = iso8601.string(from: ev.startDate ?? Date())
                let eStr = iso8601.string(from: ev.endDate ?? Date())
                let titleShow = (ev.title ?? "(无标题)")
                log(String(format: "ev[%.2f] '%@' %@~%@ | must=%.2f tokens=%.2f att=%.2f loc=%.2f time=%.2f allDay=%.2f sem_raw=%.4f sem_norm=%.4f sem_comp=%.2f (hasTimeHint=%@)", s, titleShow, sStr, eStr, compMust, compTokens, compAtt, compLocScore, compTime, compAllDay, semRaw, semNorm, compSem, hasTimeHint ? "Y" : "N"))
            }
            return s
        }

        let rankedArray: [(EKEvent, Double)] = pool
            .map { (ev: EKEvent) -> (EKEvent, Double) in (ev, score(ev)) }
            .sorted { $0.1 > $1.1 }
            .prefix(maxK)
            .map { $0 }

        // 过滤 0 分候选，避免展示无关项
        let scoreThreshold = 0.00001
        let filteredRanked = rankedArray.filter { $0.1 > scoreThreshold }
        if debug {
            log("score_threshold=\(scoreThreshold) before=\(rankedArray.count) after=\(filteredRanked.count)")
        }

        let result: [LocatedEventCandidate] = filteredRanked.compactMap { pair in
            let (ev, sc) = pair
            guard let id = ev.eventIdentifier, let s = ev.startDate, let e = ev.endDate else { return nil }
            // 提取参与者姓名（包括组织者）
            var names: [String] = []
            if let org = ev.organizer?.name, !org.isEmpty { names.append(org) }
            if let atts = ev.attendees { names.append(contentsOf: atts.compactMap { $0.name }.filter { !$0.isEmpty }) }
            let uniqueNames = Array(Set(names))
            return LocatedEventCandidate(
                id: id,
                title: ev.title ?? "",
                start: iso8601.string(from: s),
                end: iso8601.string(from: e),
                isAllDay: ev.isAllDay,
                location: ev.location,
                calendarTitle: ev.calendar.title,
                attendees: uniqueNames.isEmpty ? nil : uniqueNames,
                score: sc
            )
        }
        if debug {
            log("Top-\(result.count) candidates:")
            for (i, c) in result.enumerated() {
                log(String(format: "#%d [%.2f] '%@' %@~%@", i+1, c.score, c.title, c.start, c.end))
            }
            logs.forEach { print($0) }
            print("[EventLocator] ==== End ====")
        }
        return result
    }

    // 解析 ModifyApp 返回 JSON 文本为模型
    func decodeParserResult(from text: String) -> ModifyParserResult? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        if let data = json.data(using: .utf8) {
            return try? JSONDecoder().decode(ModifyParserResult.self, from: data)
        }
        let cleaned = json.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8) {
            return try? JSONDecoder().decode(ModifyParserResult.self, from: data2)
        }
        return nil
    }

    // MARK: - Helpers
    private func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso8601.date(from: s) { return d }
        if let d2 = iso8601NoFraction.date(from: s) { return d2 }
        // 仅时间 ISO（如 T16:00:00+08:00）：补今日日期
        if s.hasPrefix("T") {
            let today = Calendar.current.startOfDay(for: Date())
            if let full = iso8601.date(from: iso8601.string(from: today).prefix(10) + s) { return full }
        }
        return nil
    }

    private func defaultSevenDayWindow() -> DateInterval {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -3, to: today) ?? today.addingTimeInterval(-3*86400)
        let end = cal.date(byAdding: .day, value: 3, to: today) ?? today.addingTimeInterval(3*86400)
        return DateInterval(start: start, end: end)
    }

    private func buildTimeWindows(from parser: ModifyParserResult) -> [DateInterval] {
        var wins: [DateInterval] = []
        // 优先使用 time_window
        if let tw = parser.locators.time_window,
           let s = parseISO(tw.start), let e = parseISO(tw.end), e > s {
            wins.append(DateInterval(start: s, end: e))
        }
        // 精确时刻：扩展默认 60 分钟窗口
        if let iso = parser.locators.time_iso, let t = parseISO(iso) {
            let end = Calendar.current.date(byAdding: .minute, value: 60, to: t) ?? t.addingTimeInterval(3600)
            wins.append(DateInterval(start: t, end: end))
        }
        return wins
    }

    private func tokenize(_ text: String) -> [String] {
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
    }

    private func expandWithSynonyms(_ tokens: Set<String>) -> Set<String> {
        if tokens.isEmpty { return tokens }
        var expanded = tokens
        let clusters: [[String]] = [
            ["会议","会","meeting","讨论","sync","例会","同步","standup"],
            ["评审","review","评估","审查"],
            ["电话","通话","call","电话会议","语音","语音通话"],
            ["面试","访谈","interview"],
            ["约会","见面","会面","约","咖啡","coffee"],
            ["讨论会","研讨","seminar","workshop"],
            ["客户","客户会","sales","售前","商务"],
            ["远程","线上","online","zoom","teams","meet"],
            ["线下","现场","in_person","办公室"]
        ]
        var index: [String: Set<String>] = [:]
        for set in clusters {
            let s = Set(set.map { $0.lowercased() })
            for t in s { index[t, default: []].formUnion(s) }
        }
        for t in tokens {
            let key = t.lowercased()
            if let syns = index[key] { expanded.formUnion(syns) }
        }
        return expanded
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        if denom == 0 { return 0 }
        return dot / denom
    }

    // 检测话语中是否存在明确时间提示（绝对日期/具体时间/“上午下午晚上”等时段词）
    private func hasExplicitTimeHint(in utterance: String) -> Bool {
        let lower = utterance.lowercased()
        // 1) 语义时段词
        let periodHints = ["上午","早上","清晨","中午","午间","下午","午后","傍晚","晚上","今晚","夜里","深夜","凌晨","半夜"]
        if periodHints.contains(where: { lower.contains($0) }) { return true }
        // 2) 绝对日期/时间（用 NSDataDetector）
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = utterance as NSString
            let found = detector.matches(in: utterance, options: [], range: NSRange(location: 0, length: ns.length)).contains { $0.date != nil }
            if found { return true }
        }
        // 3) ISO 时间片段如 "T16:00" 或常见 HH:mm
        if lower.contains("t") && lower.contains(":") { return true }
        let hhmm = try? NSRegularExpression(pattern: "\\b([01]?[0-9]|2[0-3]):[0-5][0-9]\\b")
        if let r = hhmm {
            let ns = utterance as NSString
            if r.firstMatch(in: utterance, options: [], range: NSRange(location: 0, length: ns.length)) != nil { return true }
        }
        return false
    }
}


