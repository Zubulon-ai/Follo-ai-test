import SwiftUI
import EventKit
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

// MARK: - 类别样式结构体
struct CategoryStyle {
    let color: Color
    let icon: String
}

struct StatusView: View {
    @StateObject private var provider = CalendarEventProvider()
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var openAI = OpenAIService()
    @StateObject private var userSession = UserSession()  // 添加UserSession
    @State private var isCollecting = false
    @State private var hasCollectedOnce = false
    @State private var isRefreshing = false
    @State private var showDebugPanel = false  // 调试面板开关

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 天气 + 下一日程（无小标题）
                    GeometryReader { geometry in
                        HStack(spacing: 12) {
                            WeatherCard(shouldRefresh: $isRefreshing)
                                .frame(width: geometry.size.width * 0.35)
                            NextEventCard(shouldRefresh: $isRefreshing)
                                .frame(width: geometry.size.width * 0.65 - 12)
                        }
                    }
                    .frame(height: 90)

                    // 同步状态显示
                    syncStatusCard
                    
                    // 🐛 调试面板（点击标题可展开）
                    DisclosureGroup(isExpanded: $showDebugPanel) {
                        DebugPanelView()
                    } label: {
                        HStack {
                            Image(systemName: "ant.circle.fill")
                                .foregroundColor(.orange)
                            Text("调试面板")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 4)

                    // 日程负担（占满整行）
                    Text("日程负担")
                        .font(.headline)
                    scheduleLoadView


                    // 模型建议（若有）
                    if let s = Optional(openAI.suggestionText.trimmingCharacters(in: .whitespacesAndNewlines)), !s.isEmpty {
                        NavigationLink(destination: VoiceChatView(titleOverride: "Follo", embedInNavigation: false, prefillSuggestion: s)) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "quote.bubble")
                                    .foregroundColor(.purple)
                                Text(s)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(12)
                        }
                    }

                    // Follo 商业化推荐（仅显示 name 与 category，按置信度排序）
                    folloRecommendationsSection
                }
                .padding()
                .padding(.bottom, 50) // 为底部TabView导航栏预留空间
            }
            .navigationTitle("状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        refreshAllData()
                    }) {
                        Text(isRefreshing ? "刷新中..." : "刷新")
                            .foregroundColor(.accentColor)
                            .font(.body)
                    }
                    .disabled(isRefreshing)
                }
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await provider.requestAccessIfNeeded()
            if provider.hasReadAccess {
                provider.ensureEventsLoaded(around: Date())
                provider.select(date: Date())
            }
        }
        .onAppear {
            // 仅在本次会话首次进入时自动采集一次
            if hasCollectedOnce == false {
                hasCollectedOnce = true
                // 确保音频监测先启动
                dataManager.ensureAudioMonitoringStarted()
                triggerAutoCollectAndAsk()
            }
        }
    }



    // MARK: - 同步状态
    private var syncStatusCard: some View {
        HStack(spacing: 12) {
            if userSession.eventSyncManager.isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(userSession.eventSyncManager.isSyncing ? "正在同步事件..." : "事件已同步")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if let lastSync = userSession.eventSyncManager.lastSyncTime {
                    Text("最后同步: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("等待首次同步...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if userSession.eventSyncManager.isSyncing {
                Text(userSession.eventSyncManager.syncStatusMessage)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(12)
    }

    // MARK: - 日程负担
    private var scheduleLoadView: some View {
        let loads = scheduleLoadNext7Days()
        let maxLoad = max(loads.max() ?? 1, 1)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let spacing: CGFloat = 8
                let count = loads.count
                let totalSpacing = spacing * CGFloat(max(count - 1, 0))
                let barWidth = max(8, (geo.size.width - totalSpacing) / CGFloat(max(count, 1)))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<loads.count, id: \.self) { i in
                        let h = CGFloat(loads[i]) / CGFloat(maxLoad) * 80
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.9))
                                .frame(width: barWidth, height: max(8, h))
                            Text(weekdaySymbol(offset: i))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(height: 110)
        }
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
    }

    private func scheduleLoadNext7Days() -> [Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var counts: [Int] = Array(repeating: 0, count: 7)
        for (comps, evs) in provider.eventsByDay {
            if let d = cal.date(from: comps) {
                let delta = cal.dateComponents([.day], from: today, to: d).day ?? -999
                if delta >= 0 && delta < 7 { counts[delta] += evs.count }
            }
        }
        return counts
    }

    private func weekdaySymbol(offset: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    // MARK: - Follo 商业化推荐卡片
    private var folloRecommendationsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Follo 推荐")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }
            if openAI.recommendations.isEmpty {
                // 无数据时显示占位
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂无推荐")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(12)
            } else {
            VStack(spacing: 8) {
                    ForEach(openAI.recommendations.prefix(3)) { item in
                        let name = item.recommendation_item?.name ?? ""
                        let location = item.recommendation_item?.location_context ?? ""
                        let persuasion = (item.persuasion_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let cta = (item.conversion_funnel?.call_to_action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let line1 = [name, location].filter { !$0.isEmpty }.joined(separator: name.isEmpty || location.isEmpty ? "" : " - ")
                        let stext = (item.suggestion_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let category = item.recommendation_item?.category ?? ""
                        let categoryStyle = getCategoryStyle(for: category)
                        NavigationLink(destination: VoiceChatView(
                            titleOverride: "Follo",
                            embedInNavigation: false,
                            prefillSuggestion: line1.isEmpty ? nil : line1,
                            prefillSecond: persuasion.isEmpty ? nil : persuasion,
                            prefillThird: cta.isEmpty ? nil : cta
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: categoryStyle.icon)
                                    .foregroundColor(categoryStyle.color)
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: 44)
                                    .background(categoryStyle.color.opacity(0.15))
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stext.isEmpty ? (line1.isEmpty ? "推荐" : line1) : stext)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    if !category.isEmpty {
                                        Text(category)
                                            .font(.caption2)
                                            .foregroundColor(categoryStyle.color)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(categoryStyle.color.opacity(0.12))
                                            .cornerRadius(6)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(16)
                            .background(categoryStyle.color.opacity(0.06))
                            .cornerRadius(14)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(16)
    }
    
    // MARK: - 类别样式工具函数
    private func getCategoryStyle(for category: String) -> CategoryStyle {
        switch category {
        case "餐饮":
            return CategoryStyle(color: .orange, icon: "fork.knife")
        case "购物":
            return CategoryStyle(color: .blue, icon: "bag")
        case "网页":
            return CategoryStyle(color: .purple, icon: "globe")
        case "娱乐":
            return CategoryStyle(color: .pink, icon: "play.circle")
        case "健身":
            return CategoryStyle(color: .green, icon: "figure.run")
        case "学习":
            return CategoryStyle(color: .indigo, icon: "book")
        case "景点":
            return CategoryStyle(color: .brown, icon: "location")
        default:
            return CategoryStyle(color: .gray, icon: "sparkles")
        }
    }
    

    private func triggerAutoCollectAndAsk() {
        isCollecting = true
        // 自动采集10次（排除网络状态），每次间隔约0.3s，加快完成
        Task {
            print("============================================================")
            print("🚀 开始App启动时的Context信息收集")
            print("============================================================")

            // 1. 收集用户环境数据
            print("\n📊 步骤1: 收集用户环境数据...")
            await dataManager.autoCollectThreeTimesExcludeNetwork { progress in
                print("  - 环境数据采集进度: \(progress)/1")
            }
            print("  ✅ 环境数据采集完成")

            // 2. 使用ContextCollector收集21个信号
            print("\n🎯 步骤2: 收集Context信号 (21个)...")
            let signals = await ContextCollector.shared.collectContext()
            print("  ✅ 成功收集 \(signals.count) 个信号:")
            for signal in signals {
                let valueStr = signal.value is String ? "\"\(signal.value)\"" : "\(signal.value)"
                print("    - \(signal.signal): \(valueStr)")
            }

            isCollecting = false
            // 采集完成后，向 API 发起 AI 建议请求
            let recent = dataManager.getLatest3StatusData()
            let events = collectAppCalendarEvents()

            print("\n🤖 步骤3: 调用HAR关怀接口...")
            print("  - 使用ContextCollector收集的21个信号")
            print("  - calendar events: \(events.count)个")

            // 并发触发 AI 建议与商业化推荐（显式 await 防止被自动取消）
            // 注意：传入已收集的 signals，避免重复收集
            async let aiSuggestionTask: Void = openAI.guessCurrentActivity(
                userInfo: UserInfo(age: "无", profession: "无", gender: "无"),
                recentStatusData: recent,
                appCalendarEvents: events,
                contextSignals: signals
            )
            async let recoTask: Void = openAI.fetchCommercialRecommendations(
                userInfo: UserInfo(age: "无", profession: "无", gender: "无"),
                recentStatusData: recent,
                appCalendarEvents: collectAppCalendarEventsForCommercial(),
                contextSignals: signals
            )
            _ = await (aiSuggestionTask, recoTask)

            print("\n✅ HAR关怀接口调用完成")
            print("  - AI建议已生成: \(openAI.suggestionText.isEmpty ? "暂无" : "已生成")")
            print("============================================================")
        }
    }

    private func collectAppCalendarEvents() -> [EKEvent] {
        var all: [EKEvent] = []
        for (_, evs) in provider.eventsByDay { all.append(contentsOf: evs) }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        // 关怀功能：今天往前3天到往后3天，总共7天
        let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
        let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        let filtered = all.filter { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return false }
            return (s <= end && e >= start)
        }
        return filtered
    }
    
    private func collectAppCalendarEventsForCommercial() -> [EKEvent] {
        var all: [EKEvent] = []
        for (_, evs) in provider.eventsByDay { all.append(contentsOf: evs) }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        // 商业化推荐：今天往前1天到往后3天，总共5天
        let start = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-1*86400)
        let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        let filtered = all.filter { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return false }
            return (s <= end && e >= start)
        }
        return filtered
    }
    
    // MARK: - 刷新功能
    private func refreshAllData() {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        
        Task {
            print("\n🔄 用户手动刷新数据")
            print("============================================================")

            // 1. 刷新日历数据
            print("\n📅 步骤1: 刷新日历数据...")
            await provider.requestAccessIfNeeded()
            if provider.hasReadAccess {
                provider.ensureEventsLoaded(around: Date())
                provider.select(date: Date())
            }
            print("  ✅ 日历数据已刷新")

            // 2. 重新采集数据并获取AI建议
            print("\n📊 步骤2: 重新收集环境数据...")
            await dataManager.autoCollectThreeTimesExcludeNetwork { _ in }
            print("  ✅ 环境数据收集完成")

            // 3. 使用ContextCollector收集21个信号
            print("\n🎯 步骤3: 重新收集Context信号...")
            let signals = await ContextCollector.shared.collectContext()
            print("  ✅ 成功收集 \(signals.count) 个信号")

            // 4. 重新获取AI建议
            let recent = dataManager.getLatest3StatusData()
            let events = collectAppCalendarEvents()
            print("\n🤖 步骤4: 重新调用HAR关怀接口...")

            // 并发触发 AI 建议与商业化推荐（显式 await 防止被自动取消）
            async let aiSuggestionTask: Void = openAI.guessCurrentActivity(
                userInfo: UserInfo(age: "无", profession: "无", gender: "无"),
                recentStatusData: recent,
                appCalendarEvents: events
            )
            async let recoTask: Void = openAI.fetchCommercialRecommendations(
                userInfo: UserInfo(age: "无", profession: "无", gender: "无"),
                recentStatusData: recent,
                appCalendarEvents: collectAppCalendarEventsForCommercial()
            )
            _ = await (aiSuggestionTask, recoTask)

            print("\n✅ HAR关怀接口调用完成")
            print("  - AI建议已更新: \(openAI.suggestionText.isEmpty ? "暂无" : "已生成")")
            print("============================================================")

            // 4. 已改为展示模型返回推荐，不再使用占位推荐类型

            // 5. 完成刷新
            await MainActor.run {
                isRefreshing = false
            }
        }
    }


// MARK: - Weather & Mood Cards
private struct CardContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.gray.opacity(0.06))
            .cornerRadius(12)
    }
}

private struct NextEventCard: View {
    @Binding var shouldRefresh: Bool
    @StateObject private var provider = CalendarEventProvider()
    
    var body: some View {
        Group {
            let next = findNextEvent()
            
            if let ev = next {
                NavigationLink(destination: CalendarScreen(showActionButtons: false).onAppear {
                    // 跳转到事件对应的日期，会自动显示今天的日期
                }) {
                    CardContainer {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ev.title.isEmpty ? "(无标题)" : ev.title)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .truncationMode(.tail)
                            Text(eventTimeOnly(ev))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if !Calendar.current.isDate(ev.startDate, inSameDayAs: Date()) {
                                Text(eventDateOnly(ev))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 70)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                CardContainer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无日程")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("休息时间")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 70)
                }
            }
        }
        .task {
            await provider.requestAccessIfNeeded()
            if provider.hasReadAccess {
                provider.ensureEventsLoaded(around: Date())
                provider.select(date: Date())
            }
        }
        .onChange(of: shouldRefresh) { oldValue, newValue in
            if newValue {
                // 刷新时重新加载日程数据
                Task {
                    await provider.requestAccessIfNeeded()
                    if provider.hasReadAccess {
                        provider.ensureEventsLoaded(around: Date())
                        provider.select(date: Date())
                    }
                }
            }
        }
    }
    
    private func findNextEvent() -> EKEvent? {
        var all: [EKEvent] = []
        for (_, evs) in provider.eventsByDay { all.append(contentsOf: evs) }
        let now = Date()
        return all
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }
    
    private func eventTimeOnly(_ ev: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(formatter.string(from: ev.startDate)) - \(formatter.string(from: ev.endDate))"
    }
    
    private func eventDateOnly(_ ev: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: ev.startDate)
    }
}

private struct WeatherCard: View {
    @Binding var shouldRefresh: Bool
    @State private var tempText: String = "--°"
    @State private var symbolName: String = "cloud"
    @State private var locationText: String = "定位中..."
    
    var body: some View {
        CardContainer {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: symbolName)
                        .foregroundColor(.blue)
                        .font(.system(size: 20))
                    Text(tempText)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                }
                Text(locationText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            .frame(minHeight: 70)
        }
            .task { await loadWeather() }
            .onChange(of: shouldRefresh) { oldValue, newValue in
                if newValue {
                    // 刷新时重新加载天气数据
                    Task {
                        await loadWeather()
                    }
                }
            }
        }
    
    // MARK: - Weather Loading Functions
    private func loadWeather() async {
        #if canImport(WeatherKit)
        if #available(iOS 16.0, *) {
            // 首先获取位置
            guard let loc = await currentLocation() else {
                await MainActor.run {
                    self.tempText = "--°"
                    self.symbolName = "cloud"
                    let auth = CLLocationManager().authorizationStatus
                    self.locationText = (auth == .denied || auth == .restricted) ? "定位未授权" : "无法获取位置"
                }
                return
            }
            
            let placeName = await fetchLocationName(for: loc)
            
            // 尝试使用WeatherKit
            do {
                let service = WeatherKit.WeatherService()
                print("尝试使用WeatherKit获取天气数据...")
                let w = try await service.weather(for: loc)
                let temp = Int(round(w.currentWeather.temperature.converted(to: .celsius).value))

                await MainActor.run {
                    self.tempText = "\(temp)°"
                    self.symbolName = w.currentWeather.symbolName
                    self.locationText = placeName
                }
                print("WeatherKit获取天气数据成功")
                return

            } catch {
                print("WeatherKit获取天气失败: \(error)")
                
                // 检查是否是JWT认证错误
                let weatherError = error as NSError
                print("错误域: \(weatherError.domain)")
                print("错误代码: \(weatherError.code)")
                print("错误描述: \(weatherError.localizedDescription)")
                
                // WeatherKit 失败，回退到 Open-Meteo
                print("回退到Open-Meteo API...")
                if let (temp, symbol) = await fetchOpenMeteoWeather(for: loc) {
                    await MainActor.run {
                        self.tempText = "\(temp)°"
                        self.symbolName = symbol
                        self.locationText = placeName + " (备用源)"
                    }
                    print("Open-Meteo获取天气数据成功")
                    return
                } else {
                    print("Open-Meteo获取天气数据也失败了")
                }
            }
        }
        #endif
        
        // 所有方法都失败时的回退
        await MainActor.run {
            self.tempText = "--°"
            self.symbolName = "cloud"
            self.locationText = "无法获取天气"
        }
    }

    // 更稳妥地获取一次定位：请求授权并请求一次定位结果
    @MainActor private func currentLocation() async -> CLLocation? {
        class Delegate: NSObject, CLLocationManagerDelegate {
            var cont: CheckedContinuation<CLLocation?, Never>?
            
            func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
                print("位置更新成功: \(locations)")
                if let location = locations.last {
                    cont?.resume(returning: location)
                    cont = nil
                }
            }
            
            func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
                print("位置获取失败: \(error)")
                cont?.resume(returning: nil)
                cont = nil
            }
            
            func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
                let status = manager.authorizationStatus
                print("位置权限状态改变: \(status.rawValue)")
                
                switch status {
                case .authorizedWhenInUse, .authorizedAlways:
                    print("位置权限已授权，开始请求位置")
                    manager.requestLocation()
                case .denied, .restricted:
                    print("位置权限被拒绝或受限")
                    cont?.resume(returning: nil)
                    cont = nil
                case .notDetermined:
                    print("位置权限未确定")
                    break
                @unknown default:
                    print("未知的位置权限状态")
                    cont?.resume(returning: nil)
                    cont = nil
                }
            }
        }

        let manager = CLLocationManager()
        let delegate = Delegate()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        let auth = manager.authorizationStatus
        print("当前位置权限状态: \(auth.rawValue)")
        
        if auth == .denied || auth == .restricted {
            print("位置权限已被拒绝")
            return nil
        } else if auth == .notDetermined {
            print("请求位置权限")
            manager.requestWhenInUseAuthorization()
        } else if auth == .authorizedWhenInUse || auth == .authorizedAlways {
            print("位置权限已授权，直接请求位置")
            manager.requestLocation()
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            delegate.cont = cont
            // 超时保护：若一定时间内未回调，结束等待，避免 UI 一直"定位中"
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 增加到10秒
                if delegate.cont != nil {
                    print("位置获取超时")
                    delegate.cont?.resume(returning: nil)
                    delegate.cont = nil
                }
            }
        }
    }

    private func fetchLocationName(for location: CLLocation) async -> String {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN"))
            if let p = placemarks.first {
                let candidates = [p.locality, p.subLocality, p.administrativeArea, p.name]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                if let name = candidates.first { return name }
            }
        } catch { }
        return "未知位置"
    }

    // MARK: - Open-Meteo 回退
    private struct OpenMeteoCurrentWeather: Decodable {
        let temperature: Double
        let weathercode: Int
        let is_day: Int?
    }
    private struct OpenMeteoResponse: Decodable {
        let current_weather: OpenMeteoCurrentWeather
    }

    private func fetchOpenMeteoWeather(for location: CLLocation) async -> (Int, String)? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true&timezone=auto") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let temp = Int(round(decoded.current_weather.temperature))
            let symbol = mapWeatherCodeToSymbol(decoded.current_weather.weathercode, isDay: (decoded.current_weather.is_day ?? 1) == 1)
            return (temp, symbol)
        } catch {
            return nil
        }
    }

    private func mapWeatherCodeToSymbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0:
            return isDay ? "sun.max" : "moon.stars"
        case 1,2,3:
            return isDay ? "cloud.sun" : "cloud.moon"
        case 45, 48:
            return "cloud.fog"
        case 51,53,55,56,57:
            return "cloud.drizzle"
        case 61,63,65,66,67,80,81,82:
            return "cloud.rain"
        case 71,73,75,77,85,86:
            return "cloud.snow"
        case 95,96,99:
            return "cloud.bolt.rain"
        default:
            return "cloud"
        }
        }
    }
}
