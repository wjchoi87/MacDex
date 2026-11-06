import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MacDroid 데스크톱 — 우리만의 DeX 셸.
/* 정책: 배경화면·상태표시줄(기기·연결·배터리·시계)·작업표시줄(내비 버튼·독)·앱 서랍·최근 창·바탕화면 아이콘은
   전부 MacDroid가 그린다. 삼성 런처/작업표시줄은 쓰지 않는다(가상 디스플레이에 시스템 장식 없음).
   앱은 이 창 안에서 MacDroid 제목줄이 달린 창으로 뜬다 — 내용은 DesktopSession의 단일 스트림에서 잘라 그린다.
   영향 범위: '데스크톱' 창(기기별 1개). 창을 닫으면 세션이 끝나고 그 위 앱 창도 닫힌다. */
struct DesktopView: View {
    @Environment(AppState.self) private var appState
    let serial: String

    var body: some View {
        Group {
            if let session = appState.desktops[serial] {
                DesktopShell(session: session, device: appState.device(for: serial))
            } else {
                Color.black.onAppear { _ = appState.desktop(for: serial) }
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .navigationTitle("MacDroid 데스크톱 · \(appState.device(for: serial)?.displayModel ?? serial)")
        .onDisappear { appState.endDesktop(serial: serial) }
    }
}

private struct DesktopShell: View {
    let session: DesktopSession
    let device: Device?

    @State private var launcherOpen = false
    @State private var recentsOpen = false
    @State private var selection: Set<String> = []
    @State private var marquee: CGRect?
    @State private var openFolder: String?
    @State private var activePanel: StatusPanel?
    @State private var panelAnchors: [StatusPanel: CGRect] = [:]
    @State private var keyMonitor = DesktopKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(session: session, device: device, activePanel: $activePanel)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Wallpaper(session: session, selection: $selection, marquee: $marquee,
                              openLauncher: { launcherOpen = true })
                    DesktopIcons(session: session, selection: $selection, openFolder: $openFolder)
                    if let marquee {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .overlay(Rectangle().strokeBorder(.white.opacity(0.6)))
                            .frame(width: marquee.width, height: marquee.height)
                            .offset(x: marquee.minX, y: marquee.minY)
                            .allowsHitTesting(false)
                    }
                    ForEach(session.windows.reversed()) { window in
                        AppWindow(session: session, window: window, isFront: window.id == session.windows.first?.id)
                    }
                    if let preview = session.snapPreview {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                            .padding(4)
                            .frame(width: preview.width, height: preview.height)
                            .offset(x: preview.minX, y: preview.minY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    PhaseOverlay(session: session)
                    if session.phase == .running && session.phoneAsleep {
                        PhoneAsleepBanner(session: session)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if session.phase == .running && session.showIMEHint && !session.phoneAsleep {
                        IMEHintBanner(session: session)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let openFolder, session.folders[openFolder] != nil {
                        FolderOverlay(session: session, folderID: openFolder, isOpen: $openFolder)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    if launcherOpen {
                        AppDrawer(session: session, isOpen: $launcherOpen)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    if recentsOpen {
                        RecentsOverlay(session: session, isOpen: $recentsOpen)
                            .transition(.opacity)
                    }
                    // 떠 있는 독(가운데)과 내비 버튼(왼쪽) — 앱 서랍 위에도 보이게 맨 위
                    FloatingDock(session: session, launcherOpen: $launcherOpen, recentsOpen: $recentsOpen)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                        .allowsHitTesting(true)
                    NavPill(session: session, launcherOpen: $launcherOpen, recentsOpen: $recentsOpen)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 12)
                        .padding(.bottom, 14)
                }
                .coordinateSpace(name: "canvas")
                .clipped()
                .onAppear { session.canvasChanged(geometry.size, backingScale: backingScale) }
                .onChange(of: geometry.size) { _, size in
                    session.canvasChanged(size, backingScale: backingScale)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // 상태표시줄을 창 제목줄 자리(신호등 옆)에
        .background(Color.black)
        .coordinateSpace(name: "shell")
        .onPreferenceChange(PanelAnchorKey.self) { panelAnchors = $0 }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let panel = activePanel, let anchor = panelAnchors[panel] {
                    // 바깥을 누르면 닫힌다
                    Color.black.opacity(0.001)
                        .onTapGesture { activePanel = nil }
                    StatusPanelView(session: session, panel: panel, active: $activePanel,
                                    anchor: anchor, bounds: geometry.size)
                }
            }
        }
        .onAppear {
            let launcher = $launcherOpen, recents = $recentsOpen, folder = $openFolder
            let panel = $activePanel, selected = $selection
            keyMonitor.install(back: {
                if panel.wrappedValue != nil { panel.wrappedValue = nil; return true }
                if folder.wrappedValue != nil { folder.wrappedValue = nil; return true }
                guard launcher.wrappedValue || recents.wrappedValue else { return false }
                launcher.wrappedValue = false
                recents.wrappedValue = false
                return true
            }, delete: {
                guard !selected.wrappedValue.isEmpty, folder.wrappedValue == nil,
                      !launcher.wrappedValue else { return false }
                session.removeDesktopItems(selected.wrappedValue)
                selected.wrappedValue = []
                return true
            }, enter: {
                // 바탕화면에서 고른 아이콘을 Enter로 열기(폴더는 하나만 골랐을 때 연다)
                guard !selected.wrappedValue.isEmpty, folder.wrappedValue == nil,
                      !launcher.wrappedValue, panel.wrappedValue == nil else { return false }
                let items = session.desktopPackages.filter { selected.wrappedValue.contains($0) }
                if items.count == 1, let only = items.first, DesktopSession.isFolder(only) {
                    folder.wrappedValue = only
                } else {
                    for item in items where !DesktopSession.isFolder(item) { session.activate(item) }
                }
                selected.wrappedValue = []
                return true
            })
        }
        .onDisappear { keyMonitor.remove() }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: launcherOpen)
        .animation(.easeOut(duration: 0.18), value: recentsOpen)
        .animation(.easeOut(duration: 0.15), value: activePanel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: openFolder)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: session.snapPreview)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: session.phoneAsleep)
    }

    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}

// MARK: - 상태표시줄

/* 정책: 상태표시줄 항목은 눌러서 바로 조작한다.
   - MacDroid 로고: 메뉴(폰 설정 앱 열기 / MacDroid 설정 / 앱 서랍)
   - 알림: 폰 알림 목록(누르면 그 앱을 데스크톱에서 연다), 개수 배지
   - Wi-Fi: 폰 Wi-Fi 설정 화면을 데스크톱 창으로(네트워크 선택·비밀번호 입력은 안드로이드 화면 그대로)
   - 밝기·소리: 슬라이더(폰 화면 밝기·미디어 볼륨 — 소리는 폰에서 난다)
   - 날짜·시간: 맥 메뉴막대 시계 설정(날짜·요일·초·24시간·오전/오후)과 언어를 따른다, 누르면 미니 달력 */
private struct StatusBar: View {
    let session: DesktopSession
    let device: Device?
    @Binding var activePanel: StatusPanel?

    var body: some View {
        HStack(spacing: 4) {
            // 창 신호등 자리(hiddenTitleBar)
            Color.clear.frame(width: 64, height: 1)
            panelItem(.menu, help: String(localized: "설정")) {
                Image(systemName: "dock.rectangle")
                Text("MacDroid").fontWeight(.semibold)
            }
            Text(device?.displayModel ?? session.serial)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.leading, 8)
            Spacer()
            if !session.minimized.isEmpty {
                Label("\(session.minimized.count)", systemImage: "rectangle.on.rectangle")
                    .foregroundStyle(.white.opacity(0.7))
                    .help("최소화된 창")
                    .padding(.horizontal, 6)
            }
            panelItem(.notifications, help: String(localized: "알림")) {
                Image(systemName: session.notifications.isEmpty ? "bell" : "bell.badge")
                if !session.notifications.isEmpty {
                    Text("\(session.notifications.count)").monospacedDigit()
                }
            }
            StatusItem(help: device?.isUSB == true ? String(localized: "USB 연결 · 폰 Wi-Fi 설정 열기") : String(localized: "폰 Wi-Fi 설정 열기")) {
                activePanel = nil
                session.openSystemPage("android.settings.WIFI_SETTINGS")
            } label: {
                Image(systemName: device?.isUSB == true ? "cable.connector" : "wifi")
            }
            panelItem(.brightness, help: String(localized: "밝기")) { Image(systemName: "sun.max") }
            panelItem(.volume, help: String(localized: "소리")) { Image(systemName: "speaker.wave.2") }
            StatusItem(help: session.bluetoothOn == false ? String(localized: "블루투스 꺼짐 · 블루투스 설정 열기") : String(localized: "블루투스 설정 열기")) {
                activePanel = nil
                session.openSystemPage("android.settings.BLUETOOTH_SETTINGS")
            } label: {
                BluetoothGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 13)
                    .opacity(session.bluetoothOn == false ? 0.4 : 1)
            }
            if let level = device?.batteryLevel {
                StatusItem(help: String(localized: "배터리 설정 열기")) {
                    activePanel = nil
                    session.openSystemPage("android.intent.action.POWER_USAGE_SUMMARY", package: "com.samsung.android.lool")
                } label: {
                    Image(systemName: batterySymbol(level, charging: device?.isCharging ?? false))
                    Text("\(level)%").monospacedDigit()
                }
            }
            panelItem(.calendar, help: String(localized: "달력")) { SystemClock() }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.black.opacity(0.82))
    }

    /// 누르면 패널을 여닫는 항목 — 위치를 PanelAnchorKey로 알려 패널이 그 아래에 뜬다.
    private func panelItem<L: View>(_ panel: StatusPanel, help: String, @ViewBuilder label: () -> L) -> some View {
        StatusItem(help: help, active: activePanel == panel) {
            activePanel = activePanel == panel ? nil : panel
        } label: {
            label()
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelAnchorKey.self, value: [panel: proxy.frame(in: .named("shell"))])
        })
    }

    private func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { MenuRowLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain)
    }
}

private struct MenuRowLabel: View {
    let title: String
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(hovering ? 0.8 : 0)))
            .foregroundStyle(hovering ? .white : .primary)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// 상태표시줄 버튼(맥 메뉴막대처럼 누르면 살짝 밝아짐).
private struct StatusItem<Label: View>: View {
    let help: String
    var active = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { label }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(active ? 0.22 : hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 맥 메뉴막대 시계 설정을 따르는 날짜·시간.
/* 정책: com.apple.menuextra.clock(ShowDate 0/1=표시·2=숨김, ShowDayOfWeek, ShowSeconds, ShowAMPM)과
   전역 AppleICUForce24HourTime, 선호 언어(AppleLanguages 첫 항목)로 형식을 만든다 — 앱에 한국어 리소스가 없어도
   시스템 언어로 표시. 30초마다 설정을 다시 읽는다. */
private struct SystemClock: View {
    @State private var format = ClockFormat.current()

    var body: some View {
        TimelineView(.periodic(from: .now, by: format.showsSeconds ? 1 : 15)) { context in
            Text(format.formatter.string(from: context.date))
                .monospacedDigit()
                .onChange(of: Int(context.date.timeIntervalSince1970) / 30) { _, _ in
                    let fresh = ClockFormat.current()
                    if fresh.pattern != format.pattern { format = fresh }
                }
        }
    }
}

struct ClockFormat {
    let formatter: DateFormatter
    let pattern: String
    let showsSeconds: Bool

    static var locale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    static func current() -> ClockFormat {
        let clock = UserDefaults(suiteName: "com.apple.menuextra.clock")
        let showDate = (clock?.object(forKey: "ShowDate") as? Int ?? 0) != 2
        let showWeekday = clock?.object(forKey: "ShowDayOfWeek") as? Bool ?? true
        let showSeconds = clock?.bool(forKey: "ShowSeconds") ?? false
        let showAMPM = clock?.object(forKey: "ShowAMPM") as? Bool ?? true
        let force24 = UserDefaults.standard.bool(forKey: "AppleICUForce24HourTime")
        var template = ""
        if showDate { template += "MMMd" }
        if showWeekday { template += "EEE" }
        template += force24 ? "HHmm" : (showAMPM ? "hmma" : "hmm")
        if showSeconds { template += "ss" }
        let locale = locale
        let pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? "HH:mm"
        let formatter = DateFormatter()
        formatter.locale = locale
        // 템플릿이 오전/오후를 강제로 넣는 언어도 있어, 꺼 두었으면 빼 준다
        formatter.dateFormat = (!force24 && !showAMPM)
            ? pattern.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
            : pattern
        return ClockFormat(formatter: formatter, pattern: formatter.dateFormat, showsSeconds: showSeconds)
    }
}

/// 상태표시줄 패널 종류.
enum StatusPanel: Hashable {
    case menu, notifications, brightness, volume, calendar

    var width: CGFloat {
        switch self {
        case .menu: 220
        case .notifications: 360
        case .brightness, .volume: 280
        case .calendar: 340
        }
    }
}

struct PanelAnchorKey: PreferenceKey {
    static let defaultValue: [StatusPanel: CGRect] = [:]
    static func reduce(value: inout [StatusPanel: CGRect], nextValue: () -> [StatusPanel: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 상태표시줄 패널 — 시스템 팝오버 대신 데스크톱 창 안에 반투명으로 그린다.
/* 변경 전 정책: NSPopover(불투명, 창 밖으로 삐져나갈 수 있음).
   변경 후 정책: 데스크톱 창 안 오버레이 — 반투명 흐림 배경, 누른 항목 아래에 뜨되 창 가장자리 8pt 안으로 맞추고
     높이도 창 아래 끝을 넘지 않는다. 바깥 클릭·Esc·마우스 뒤로 버튼으로 닫힌다.
   이유: 반투명 요청, 캘린더를 키워도 창을 벗어나지 않게. 영향 범위: 상태표시줄 메뉴·알림·밝기·소리·달력. */
private struct StatusPanelView: View {
    let session: DesktopSession
    let panel: StatusPanel
    @Binding var active: StatusPanel?
    let anchor: CGRect
    let bounds: CGSize

    var body: some View {
        let width = min(panel.width, bounds.width - 16)
        let x = min(max(anchor.midX - width / 2, 8), bounds.width - width - 8)
        let y = anchor.maxY + 6
        content
            .frame(width: width)
            .frame(maxHeight: max(bounds.height - y - 8, 120), alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.18)))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .environment(\.colorScheme, .dark)
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .offset(y: -4)))
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .menu:
            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: String(localized: "폰 설정 열기"), symbol: "gearshape") {
                    active = nil
                    session.activate("com.android.settings")
                }
                SettingsLink {
                    MenuRowLabel(title: String(localized: "MacDroid 설정…"), symbol: "macwindow")
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { active = nil })
            }
            .padding(6)
        case .notifications:
            NotificationList(session: session) { active = nil }
        case .brightness:
            BrightnessControl(serial: session.serial)
        case .volume:
            VolumeControl(serial: session.serial)
        case .calendar:
            MonthCalendar { date in
                active = nil
                session.openCalendar(at: date)
            }
        }
    }
}

/// 미니 달력 — 날짜를 누르면 그 날짜로 폰 캘린더 앱을 연다(제목을 누르면 오늘).
private struct MonthCalendar: View {
    let open: (Date) -> Void
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = ClockFormat.locale
        c.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return c
    }

    private var days: [Date?] {
        let c = calendar
        guard let range = c.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = c.component(.weekday, from: month)
        let lead = (weekday - c.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for day in range {
            cells.append(c.date(byAdding: .day, value: day - 1, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    var body: some View {
        let c = calendar
        let symbols = c.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(c.firstWeekday - 1)...] + symbols[..<(c.firstWeekday - 1)])
        VStack(spacing: 10) {
            HStack {
                Button { open(Date()) } label: {
                    Text(month.formatted(Date.FormatStyle().year().month(.wide).locale(ClockFormat.locale)))
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("캘린더 앱 열기")
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).help("이전 달")
                Button("오늘") {
                    month = c.date(from: c.dateComponents([.year, .month], from: Date()))!
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).help("다음 달")
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { index, symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(weekendColor(column: index, calendar: c).opacity(0.7))
                        .frame(height: 22)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if let day {
                        DayCell(date: day, isToday: c.isDateInToday(day),
                                color: weekendColor(column: index % 7, calendar: c)) {
                            open(day)
                        }
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .padding(14)
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }

    /// 일요일 빨강, 토요일 파랑(한국 달력 관례).
    private func weekendColor(column: Int, calendar: Calendar) -> Color {
        let weekday = (calendar.firstWeekday - 1 + column) % 7 + 1
        return weekday == 1 ? .red : weekday == 7 ? .blue : .primary
    }
}

private struct DayCell: View {
    let date: Date
    let isToday: Bool
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 13, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? .white : color)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Circle()
                        .fill(isToday ? Color.accentColor : Color.white.opacity(hovering ? 0.14 : 0))
                        .frame(width: 32, height: 32)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("캘린더에서 열기")
    }
}

/// 블루투스 기호(SF Symbols에 없어 직접 그린다).
private struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.27))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.73))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.27))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.73))
        return p
    }
}

private struct BrightnessControl: View {
    let serial: String
    @State private var value: Double = 128
    @State private var auto = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("폰 화면 밝기").font(.headline)
            HStack {
                Image(systemName: "sun.min")
                Slider(value: $value, in: 1...255) { editing in
                    guard !editing else { return }
                    auto = false
                    Task { await ADB.setBrightness(serial: serial, Int(value)) }
                }
                Image(systemName: "sun.max.fill")
            }
            .disabled(!loaded)
            Toggle("자동 밝기", isOn: $auto)
                .disabled(!loaded)
                .onChange(of: auto) { _, on in
                    guard loaded else { return }
                    Task { await ADB.setAutoBrightness(serial: serial, on) }
                }
        }
        .padding(14)
        .task {
            if let current = await ADB.brightness(serial: serial) {
                value = Double(current.value)
                auto = current.auto
            }
            loaded = true
        }
    }
}

private struct VolumeControl: View {
    let serial: String
    @State private var value: Double = 0
    @State private var maxValue: Double = 15
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("미디어 볼륨").font(.headline)
            HStack {
                Button {
                    value = 0
                    Task { await ADB.setMediaVolume(serial: serial, 0) }
                } label: {
                    Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.fill")
                }
                .buttonStyle(.plain)
                .help("음소거")
                Slider(value: $value, in: 0...maxValue, step: 1) { editing in
                    guard !editing else { return }
                    Task { await ADB.setMediaVolume(serial: serial, Int(value)) }
                }
                Image(systemName: "speaker.wave.3.fill")
            }
            .disabled(!loaded)
            Text("소리는 폰 스피커로 나옵니다").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .task {
            if let current = await ADB.mediaVolume(serial: serial) {
                maxValue = Double(max(current.max, 1))
                value = Double(current.value)
            }
            loaded = true
        }
    }
}

private struct NotificationList: View {
    let session: DesktopSession
    let close: () -> Void
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("알림").font(.headline)
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("새로고침")
            }
            .padding(12)
            Divider()
            if session.notifications.isEmpty {
                Text(refreshing ? String(localized: "불러오는 중…") : String(localized: "알림이 없습니다"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.notifications) { item in
                            NotificationRow(session: session, item: item) {
                                close()
                                session.activate(item.package)
                            }
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .frame(maxHeight: 440)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        refreshing = true
        await session.refreshNotifications()
        refreshing = false
    }
}

/// 알림 한 줄 — 누르면 앱 열기, 마우스를 올리면 닫기 버튼.
private struct NotificationRow: View {
    let session: DesktopSession
    let item: ADB.PhoneNotification
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) { row }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(hovering ? 0.06 : 0))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button {
                        session.dismiss(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.background).padding(2))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("알림 닫기")
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            IconImage(session: session, package: item.package, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.label(for: item.package)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let posted = item.posted {
                        Text(posted.formatted(.relative(presentation: .named).locale(ClockFormat.locale)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !item.title.isEmpty {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                if !item.text.isEmpty {
                    Text(item.text).font(.system(size: 12)).lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

}

// MARK: - 배경화면

private struct Wallpaper: View {
    let session: DesktopSession
    @Binding var selection: Set<String>
    @Binding var marquee: CGRect?
    let openLauncher: () -> Void

    var body: some View {
        Group {
            if let path = session.wallpaperPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.20),
                                        Color(red: 0.14, green: 0.22, blue: 0.52),
                                        Color(red: 0.36, green: 0.42, blue: 0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .bottomTrailing) {
                        Text("MacDroid")
                            .font(.system(size: 84, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.07))
                            .padding(40)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            selection = []
            releaseAppKeyboardFocus()
        }
        // 바탕화면에서 끌면 사각형으로 여러 아이콘 선택(⌘를 누르고 끌면 기존 선택에 더함)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    if marquee == nil { releaseAppKeyboardFocus() }
                    let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                      y: min(value.startLocation.y, value.location.y),
                                      width: abs(value.location.x - value.startLocation.x),
                                      height: abs(value.location.y - value.startLocation.y))
                    marquee = rect
                    let cell = DesktopSession.iconCell
                    let hits = session.iconLayout(in: session.canvasSize).filter { _, origin in
                        CGRect(origin: origin, size: cell).insetBy(dx: 10, dy: 6).intersects(rect)
                    }.map(\.key)
                    let base = NSEvent.modifierFlags.contains(.command) ? selection : []
                    selection = base.union(hits)
                }
                .onEnded { _ in marquee = nil }
        )
        .contextMenu {
            Button("앱 서랍 열기", action: openLauncher)
            Button("새 폴더") { session.createFolder(at: lastClickPoint()) }
            Divider()
            Button("배경화면 변경…") { chooseWallpaper() }
            if session.wallpaperPath != nil {
                Button("기본 배경화면으로") { session.setWallpaper(nil) }
            }
            if !session.desktopPackages.isEmpty {
                Divider()
                Button("아이콘 정렬") { session.resetIconPositions() }
            }
        }
    }

    /// 지금 마우스 자리(캔버스 좌표) — 새 폴더를 우클릭한 자리 근처에 놓는다.
    private func lastClickPoint() -> CGPoint? {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
        let p = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let y = content.isFlipped ? p.y : content.bounds.height - p.y
        // 캔버스는 상태표시줄(28pt) 아래에서 시작한다
        let cell = DesktopSession.iconCell
        return CGPoint(x: max(p.x - cell.width / 2, 0), y: max(y - 28 - cell.height / 2, 0))
    }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "배경화면으로 사용")
        if panel.runModal() == .OK, let url = panel.url {
            session.setWallpaper(url)
        }
    }
}

// MARK: - 바탕화면 아이콘

/// 바탕화면을 누르면 앱 창이 잡고 있던 키보드 포커스를 놓는다 — Enter·Delete가 앱이 아니라 바탕화면 아이콘에 가게.
@MainActor
private func releaseAppKeyboardFocus() {
    if let window = NSApp.keyWindow, window.firstResponder is DesktopVideoView {
        window.makeFirstResponder(nil)
    }
}

private struct DesktopIcons: View {
    let session: DesktopSession
    @Binding var selection: Set<String>
    @Binding var openFolder: String?

    /// 끌고 있는 항목들과 이동량(선택된 항목을 끌면 선택 전체가 함께 움직인다).
    @State private var dragItems: Set<String> = []
    @State private var dragOffset: CGSize = .zero

    private let cell = DesktopSession.iconCell

    var body: some View {
        GeometryReader { geometry in
            let positions = session.iconLayout(in: geometry.size)
            ForEach(session.desktopPackages, id: \.self) { item in
                let origin = positions[item] ?? .zero
                let offset = dragItems.contains(item) ? dragOffset : .zero
                itemView(item)
                    .frame(width: cell.width - 6, height: cell.height - 6)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selection = []
                        open(item)
                    }
                    .onTapGesture {
                        releaseAppKeyboardFocus()
                        if NSEvent.modifierFlags.contains(.command) {
                            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
                        } else {
                            selection = [item]
                        }
                    }
                    .contextMenu { menu(for: item) }
                    .opacity(offset == .zero ? 1 : 0.85)
                    .offset(x: origin.x + offset.width, y: origin.y + offset.height)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if dragItems.isEmpty {
                                    if !selection.contains(item) { selection = [item] }
                                    dragItems = selection
                                }
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                let moving = dragItems.isEmpty ? [item] : dragItems
                                dragItems = []
                                dragOffset = .zero
                                drop(moving, dragged: item, translation: value.translation,
                                     positions: positions, size: geometry.size)
                            }
                    )
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: String) -> some View {
        if DesktopSession.isFolder(item), let folder = session.folders[item] {
            FolderIcon(session: session, folder: folder, selected: selection.contains(item))
        } else {
            AppIcon(session: session, package: item, size: 52, labelColor: .white, selected: selection.contains(item))
        }
    }

    private func open(_ item: String) {
        if DesktopSession.isFolder(item) { openFolder = item } else { session.activate(item) }
    }

    /// 놓기: 앱을 폴더 위에 놓으면 폴더에 넣고, 아니면 끈 만큼 옮긴다(캔버스 안으로).
    private func drop(_ items: Set<String>, dragged: String, translation: CGSize,
                      positions: [String: CGPoint], size: CGSize) {
        if let origin = positions[dragged] {
            let center = CGPoint(x: origin.x + translation.width + cell.width / 2,
                                 y: origin.y + translation.height + cell.height / 2)
            if let target = positions.first(where: { key, point in
                DesktopSession.isFolder(key) && !items.contains(key)
                    && CGRect(origin: point, size: cell).insetBy(dx: 14, dy: 10).contains(center)
            })?.key {
                session.addToFolder(target, items: Array(items))
                selection = []
                return
            }
        }
        for item in items {
            guard let origin = positions[item] else { continue }
            let x = min(max(origin.x + translation.width, 0), size.width - cell.width)
            let y = min(max(origin.y + translation.height, 0), size.height - cell.height)
            session.setIconPosition(item, CGPoint(x: x, y: y))
        }
    }

    @ViewBuilder
    private func menu(for item: String) -> some View {
        let group: Set<String> = selection.contains(item) && selection.count > 1 ? selection : [item]
        if group.count > 1 {
            Button("선택한 \(group.count)개 열기") { group.forEach(open) }
            Button("선택 항목으로 새 폴더") {
                let ordered = session.desktopPackages.filter { group.contains($0) }
                session.createFolder(with: ordered)
                selection = []
            }
            Divider()
            Button("선택한 \(group.count)개 바탕화면에서 제거") {
                session.removeDesktopItems(group)
                selection = []
            }
        } else if DesktopSession.isFolder(item) {
            Button("열기") { openFolder = item }
            Button("폴더 해제") { session.ungroupFolder(item) }
            Divider()
            Button("바탕화면에서 제거") { session.removeDesktopItems([item]) }
        } else {
            Button("열기") { session.activate(item) }
            Button("새 창으로 열기") { session.launch(session.app(for: item), newInstance: true) }
            Divider()
            Button(session.isPinned(item) ? String(localized: "독에서 제거") : String(localized: "독에 고정")) { session.togglePin(item) }
            Button("바탕화면에서 제거") { session.removeDesktopItems([item]) }
        }
    }
}

/// 폴더 아이콘 — 안의 앱 아이콘 최대 4개 미리보기.
private struct FolderIcon: View {
    let session: DesktopSession
    let folder: DesktopFolder
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.12)))
                .frame(width: 52, height: 52)
                .overlay {
                    LazyVGrid(columns: [GridItem(.fixed(19), spacing: 4), GridItem(.fixed(19), spacing: 4)], spacing: 4) {
                        ForEach(Array(folder.packages.prefix(4)), id: \.self) { package in
                            IconImage(session: session, package: package, size: 19)
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .environment(\.colorScheme, .dark)
            Text(folder.name)
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.22 : 0)))
    }
}

/// 열린 폴더 — 이름 바꾸기, 앱 열기, 폴더에서 빼기.
private struct FolderOverlay: View {
    let session: DesktopSession
    let folderID: String
    @Binding var isOpen: String?
    @State private var name = ""

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .onTapGesture { close() }
            VStack(spacing: 16) {
                TextField("폴더 이름", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .onSubmit { session.renameFolder(folderID, to: name) }
                let packages = session.folders[folderID]?.packages ?? []
                if packages.isEmpty {
                    Text("앱 아이콘을 바탕화면의 이 폴더 위로 끌어다 놓으세요")
                        .foregroundStyle(.secondary)
                        .padding(30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 14) {
                        ForEach(packages, id: \.self) { package in
                            AppIcon(session: session, package: package, size: 54, labelColor: .white)
                                .frame(width: 92)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    close()
                                    session.activate(package)
                                }
                                .contextMenu {
                                    Button("열기") {
                                        close()
                                        session.activate(package)
                                    }
                                    Button("폴더에서 빼기") { session.removeFromFolder(folderID, package: package) }
                                }
                        }
                    }
                }
            }
            .padding(22)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.2)))
            )
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
        }
        .onAppear { name = session.folders[folderID]?.name ?? "" }
    }

    private func close() {
        session.renameFolder(folderID, to: name)
        isOpen = nil
    }
}

/// 아이콘 + 이름(바탕화면·앱 서랍 공용).
private struct AppIcon: View {
    let session: DesktopSession
    let package: String
    let size: CGFloat
    var labelColor: Color = .primary
    var selected = false

    var body: some View {
        VStack(spacing: 6) {
            IconImage(session: session, package: package, size: size)
            Text(session.label(for: package))
                .font(.system(size: 11.5))
                .foregroundStyle(labelColor)
                .shadow(color: .black.opacity(labelColor == .white ? 0.7 : 0), radius: 2, y: 1)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.22 : 0)))
    }
}

private struct IconImage: View {
    let session: DesktopSession
    let package: String
    let size: CGFloat

    var body: some View {
        if let image = session.icon(for: package) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(Color.accentColor.gradient)
                .frame(width: size, height: size)
                .overlay(Text(String(session.label(for: package).prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white))
        }
    }
}

// MARK: - 앱 창

private struct AppWindow: View {
    let session: DesktopSession
    let window: ADB.DesktopWindow
    let isFront: Bool

    @State private var hovering = false
    @State private var dragBase: CGRect?

    private let bar = DesktopSession.titleBarHeight

    var body: some View {
        let frame = session.contentFrame(window)
        // 제목줄은 반투명, 창 그림자·테두리는 앱 내용에만
        VStack(spacing: 0) {
            titleBar
                .frame(width: frame.width, height: bar)
            DesktopVideo(session: session, windowID: window.id, crop: window.bounds)
                .frame(width: frame.width, height: frame.height)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                        .fill(Color(white: 0.1))
                        .shadow(color: .black.opacity(isFront ? 0.5 : 0.3), radius: isFront ? 18 : 10, y: 6)
                )
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .strokeBorder(.white.opacity(0.12)))
                .overlay(alignment: .bottomTrailing) { resizeHandle }
        }
        .offset(x: frame.minX, y: frame.minY - bar)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                TrafficLight(color: .red, symbol: "xmark", showSymbol: hovering) { session.close(window) }
                    .help("닫기")
                TrafficLight(color: .yellow, symbol: "minus", showSymbol: hovering) { session.minimize(window) }
                    .help("최소화")
                TrafficLight(color: .green, symbol: "arrow.up.left.and.arrow.down.right", showSymbol: hovering) {
                    session.toggleMaximize(window)
                }
                .help("최대화 / 이전 크기")
            }
            .onHover { hovering = $0 }
            Spacer(minLength: 4)
            IconImage(session: session, package: window.package, size: 16)
            Text(session.label(for: window.package))
                .font(.system(size: 12, weight: isFront ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isFront ? 0.95 : 0.65))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(1)
            Spacer(minLength: 4)
            // 오른쪽: 뒤로가기(왼쪽 신호등과 폭을 맞춰 제목이 가운데 오게)
            HStack {
                Spacer(minLength: 0)
                Button {
                    session.back(window)
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 24, height: 20)
                        .background(Circle().fill(.black.opacity(0.35)).frame(width: 22, height: 22))
                }
                .buttonStyle(.plain)
                .help("뒤로")
            }
            .frame(width: 54)
        }
        .padding(.horizontal, 10)
        // 배경이 제목줄 높이 전체를 채우게(패딩·프레임 안쪽에 칠하면 위아래가 비었다) — 반투명 흐림
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                    .fill(Color.black.opacity(isFront ? 0.25 : 0.4)))
                .environment(\.colorScheme, .dark)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.toggleMaximize(window) }
        .onTapGesture { session.focus(window) }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    if dragBase == nil {
                        // 스냅·최대화된 창을 끌면 원래 크기로 돌아가 포인터를 따라온다
                        dragBase = session.unsnappedFrame(window, grabbing: value.startLocation)
                            ?? session.contentFrame(window)
                        session.focus(window)
                    }
                    let base = dragBase ?? session.contentFrame(window)
                    session.dragFrames[window.id] = base.offsetBy(dx: value.translation.width,
                                                                   dy: value.translation.height)
                    let target = session.snapTarget(at: value.location)
                    if target != session.snapPreview { session.snapPreview = target }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let target = session.snapPreview {
                        session.snapPreview = nil
                        session.snap(window, to: target)
                    } else {
                        session.commitDrag(window)
                    }
                }
        )
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.white.opacity(0.35))
            .frame(width: 16, height: 16)
            .background(Color.black.opacity(0.001))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        let base = dragBase ?? session.contentFrame(window)
                        if dragBase == nil { dragBase = base }
                        session.dragFrames[window.id] = CGRect(
                            x: base.minX, y: base.minY,
                            width: max(base.width + value.translation.width, 280),
                            height: max(base.height + value.translation.height, 200))
                    }
                    .onEnded { _ in
                        dragBase = nil
                        session.commitDrag(window)
                    }
            )
            .help("크기 조절")
    }
}

private struct TrafficLight: View {
    let color: Color
    let symbol: String
    let showSymbol: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.gradient)
                .frame(width: 12, height: 12)
                .overlay {
                    if showSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 폰이 잠들었을 때

/// 폰 화면이 꺼져 데스크톱이 멈췄다는 안내 — 깨우기는 사용자가 눌렀을 때만(폰 본체 상태는 자동으로 바꾸지 않는다).
private struct PhoneAsleepBanner: View {
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("폰 화면이 꺼져 있어 데스크톱이 멈춰 있습니다").font(.system(size: 13, weight: .semibold))
                Text("폰을 켜면 바로 이어서 쓸 수 있어요").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("폰 깨우기") { session.wakePhone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18)))
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

/// 한글 입력에 폰 본체 잠금이 필요하다는 안내 — 잠그기는 사용자가 눌렀을 때만(폰 본체 상태는 자동으로 바꾸지 않는다).
/* 표시 조건은 DesktopSession.markKeyboardUsed — 키보드 입력이 있는데 본체가 깨어 있을 때만 뜬다. */
private struct IMEHintBanner: View {
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("폰 본체 화면이 켜져 있으면 한글이 입력되지 않아요").font(.system(size: 13, weight: .semibold))
                Text("본체를 잠그면 데스크톱에서 바로 한글(Shift+Space 한/영)이 됩니다").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("본체 잠그기") { session.lockPhoneNow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                session.dismissIMEHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("닫기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18)))
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

// MARK: - 상태 표시(준비 중·오류)

private struct PhaseOverlay: View {
    let session: DesktopSession

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .starting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("데스크톱 준비 중…")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            case .failed(let message):
                VStack(spacing: 10) {
                    Label("데스크톱 연결이 끊어졌습니다", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("다시 연결") { session.retry() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            case .running:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(session.phase != .starting && session.phase != .idle)
    }
}

// MARK: - 독(맥 스타일 플로팅) + 내비 버튼

/* 정책: 화면 아래를 꽉 채우던 검은 작업표시줄 대신 맥 독처럼 바탕화면 위에 떠 있는 독.
   - 반투명 흐림 둥근 판(바탕화면이 비쳐 보이게), 아래 여백 8pt, 가운데 정렬
   - 커서 거리에 따라 아이콘이 커지는 확대(최대 1.25배), 올리면 위에 앱 이름 말풍선, 실행 중이면 아래 점
   - 구역: 앱 서랍 | 고정·실행 중 앱 | 최소화된 창(누르면 복원)
   - 뒤로·홈·최근 창 내비 버튼은 왼쪽 아래 작은 떠 있는 판으로
   - 앱 창 최대화·분할은 독 높이만큼 비워 둔다(DesktopSession.dockReserve)
   영향 범위: 데스크톱 아래쪽 UI. 동작(실행·복원·우클릭 메뉴)은 기존과 같다. */
private struct FloatingDock: View {
    let session: DesktopSession
    @Binding var launcherOpen: Bool
    @Binding var recentsOpen: Bool

    @State private var mouseX: CGFloat?
    @State private var centers: [String: CGFloat] = [:]
    @State private var hovered: String?

    static let base: CGFloat = 46

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            item(key: "__drawer__", help: String(localized: "앱 서랍")) {
                recentsOpen = false
                launcherOpen.toggle()
            } content: { size in
                RoundedRectangle(cornerRadius: size * 0.23)
                    .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.26)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.white))
                    .frame(width: size, height: size)
            }
            divider
            ForEach(session.dockItems, id: \.self) { package in
                item(key: package, help: session.label(for: package),
                     running: session.isRunning(package),
                     launching: session.launching.contains(package)) {
                    launcherOpen = false
                    recentsOpen = false
                    session.activate(package)
                } content: { size in
                    IconImage(session: session, package: package, size: size)
                }
                .contextMenu {
                    Button(session.isRunning(package) ? String(localized: "보기") : String(localized: "열기")) { session.activate(package) }
                    Button("새 창으로 열기") { session.launch(session.app(for: package), newInstance: true) }
                    Divider()
                    Button(session.isPinned(package) ? String(localized: "독에서 제거") : String(localized: "독에 고정")) { session.togglePin(package) }
                    Button(session.isOnDesktop(package) ? String(localized: "바탕화면에서 제거") : String(localized: "바탕화면에 추가")) {
                        session.toggleDesktop(package)
                    }
                    if session.isRunning(package) {
                        Divider()
                        Button("모든 창 닫기") { session.closeAll(package) }
                    }
                }
            }
            if !session.minimized.isEmpty {
                divider
                ForEach(session.minimized) { entry in
                    item(key: "min:\(entry.id)", help: String(localized: "\(session.label(for: entry.package)) — 복원")) {
                        session.restore(entry)
                    } content: { size in
                        RoundedRectangle(cornerRadius: size * 0.2)
                            .fill(Color(white: 0.28))
                            .frame(width: size, height: size)
                            .overlay(IconImage(session: session, package: entry.package, size: size * 0.62))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.forward.square.fill")
                                    .font(.system(size: size * 0.26))
                                    .foregroundStyle(.white, Color(white: 0.15))
                                    .padding(2)
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 9)
        .coordinateSpace(name: "dock")
        .onPreferenceChange(DockCenterKey.self) { centers = $0 }
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.22)))
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .frame(height: Self.base + 16)
        }
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            switch phase {
            case .active(let location): mouseX = location.x
            case .ended: mouseX = nil
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: mouseX)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.22))
            .frame(width: 1, height: Self.base * 0.8)
            .padding(.horizontal, 3)
            .padding(.bottom, Self.base * 0.1)
    }

    /// 맥 독 확대: 커서와 아이콘 중심 거리로 배율(포물선 감쇠, 최대 1.25배 — 1.5배는 과하다는 피드백).
    private func scale(_ key: String) -> CGFloat {
        guard let mouseX, let center = centers[key] else { return 1 }
        let distance = abs(mouseX - center)
        guard distance < 120 else { return 1 }
        let t = 1 - distance / 120
        return 1 + 0.25 * t * t
    }

    private func item<C: View>(key: String, help: String, running: Bool = false, launching: Bool = false,
                               action: @escaping () -> Void,
                               @ViewBuilder content: @escaping (CGFloat) -> C) -> some View {
        let size = Self.base * scale(key)
        return Button(action: action) {
            content(size)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .offset(y: launching ? -10 : 0)
                .animation(launching ? .easeInOut(duration: 0.38).repeatForever(autoreverses: true) : .spring(response: 0.25),
                           value: launching)
                .frame(width: size, height: size)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(.white.opacity(running ? 0.85 : 0))
                        .frame(width: 4, height: 4)
                        .offset(y: 7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
        .overlay(alignment: .top) {
            if hovered == key {
                Text(help)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(white: 0.2)).overlay(Capsule().strokeBorder(.white.opacity(0.15))))
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: DockCenterKey.self, value: [key: proxy.frame(in: .named("dock")).midX])
        })
    }
}

private struct DockCenterKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 왼쪽 아래 내비 버튼(뒤로·홈·최근 창) — 독과 같은 재질의 작은 판.
private struct NavPill: View {
    let session: DesktopSession
    @Binding var launcherOpen: Bool
    @Binding var recentsOpen: Bool

    var body: some View {
        HStack(spacing: 2) {
            NavButton(symbol: "chevron.backward", help: String(localized: "뒤로")) {
                // 앱 서랍·최근 창이 열려 있으면 그것부터 닫는다(안드로이드 뒤로가기와 같은 동작)
                if launcherOpen || recentsOpen {
                    launcherOpen = false
                    recentsOpen = false
                } else {
                    session.back()
                }
            }
            // 홈 = 떠 있는 창을 모두 최소화하고 바탕화면 보기(안드로이드 홈과 같은 뜻 — 앱 서랍은 독 맨 왼쪽)
            NavButton(symbol: "circle", help: String(localized: "홈 — 모든 창 최소화")) {
                launcherOpen = false
                recentsOpen = false
                session.minimizeAll()
            }
            NavButton(symbol: "square.on.square", help: String(localized: "최근 창")) {
                launcherOpen = false
                recentsOpen.toggle()
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22)))
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        )
    }
}

private struct NavButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 34)
                .background(Capsule().fill(.white.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 앱 서랍

private struct AppDrawer: View {
    let session: DesktopSession
    @Binding var isOpen: Bool
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [AndroidApp] {
        let apps = session.apps.sorted { $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending }
        guard !search.isEmpty else { return apps }
        let query = search.lowercased()
        return apps.filter { $0.displayLabel.lowercased().contains(query) || $0.package.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .onTapGesture { isOpen = false }
            VStack(spacing: 18) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("앱 검색", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .frame(width: 240)
                        .onSubmit {
                            if let first = filtered.first { open(first) }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.14), in: Capsule())

                if session.apps.isEmpty {
                    Spacer()
                    if session.appsLoading || !session.appsLoaded {
                        ProgressView("앱 목록 불러오는 중…")
                    } else {
                        VStack(spacing: 10) {
                            Text("앱 목록을 가져오지 못했습니다").font(.headline)
                            Text("기기 연결을 확인한 뒤 다시 시도하세요.").foregroundStyle(.secondary)
                            Button("다시 시도") { session.reloadApps() }
                        }
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 18) {
                            ForEach(filtered) { app in
                                AppIcon(session: session, package: app.package, size: 58, labelColor: .white)
                                    .frame(width: 100)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(app) }
                                    .contextMenu {
                                        Button("열기") { open(app) }
                                        Button("새 창으로 열기") {
                                            isOpen = false
                                            session.launch(app, newInstance: true)
                                        }
                                        Button("다시 시작") {
                                            isOpen = false
                                            session.launch(app, restart: true)
                                        }
                                        Divider()
                                        Button(session.isPinned(app.package) ? String(localized: "독에서 제거") : String(localized: "독에 고정")) {
                                            session.togglePin(app.package)
                                        }
                                        Button(session.isOnDesktop(app.package) ? String(localized: "바탕화면에서 제거") : String(localized: "바탕화면에 추가")) {
                                            session.toggleDesktop(app.package)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(.top, 28)
            .foregroundStyle(.white)
        }
        .onAppear {
            searchFocused = true
            if session.apps.isEmpty, session.phase == .running { session.reloadApps() }
        }
        .onExitCommand { isOpen = false }
    }

    private func open(_ app: AndroidApp) {
        isOpen = false
        session.launch(app)
    }
}

// MARK: - 최근 창

private struct RecentsOverlay: View {
    let session: DesktopSession
    @Binding var isOpen: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.55))
                .onTapGesture { isOpen = false }
            if session.windows.isEmpty && session.minimized.isEmpty {
                Text("열린 창이 없습니다")
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 18)], spacing: 18) {
                        ForEach(session.windows) { window in
                            card(package: window.package, minimized: false) {
                                session.focus(window)
                            } close: {
                                session.close(window)
                            }
                        }
                        ForEach(session.minimized) { entry in
                            card(package: entry.package, minimized: true) {
                                session.restore(entry)
                            } close: {
                                session.restore(entry)
                            }
                        }
                    }
                    .padding(40)
                }
            }
        }
        .onExitCommand { isOpen = false }
    }

    private func card(package: String, minimized: Bool, open: @escaping () -> Void,
                      close: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            IconImage(session: session, package: package, size: 56)
            Text(session.label(for: package)).foregroundStyle(.white).lineLimit(1)
            if minimized {
                Text("최소화됨").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 180, height: 140)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.18)))
        .overlay(alignment: .topTrailing) {
            if !minimized {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("창 닫기")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isOpen = false
            open()
        }
    }
}

// MARK: - 키·마우스 단축(뒤로가기, 바탕화면 아이콘 지우기)

/// Esc·마우스 뒤로 버튼(3번) = 패널/폴더/앱 서랍/최근 창 닫기, Delete = 선택한 바탕화면 아이콘 지우기,
/// Enter = 선택한 바탕화면 아이콘 열기.
/* 정책: 오버레이·바탕화면은 SwiftUI라 앱 창(DesktopVideoView)의 키·마우스 처리를 거치지 않는다 — 창 단위
   로컬 이벤트 모니터로 받는다. 처리했을 때만 이벤트를 먹고, 아니면 그대로 흘려보낸다. Delete는 키 입력 대상이
   앱 창이나 글자 입력칸일 때는 건드리지 않는다(그때는 기기/입력칸의 지우기). */
@MainActor
final class DesktopKeyMonitor {
    private var token: Any?

    func install(back: @escaping @MainActor () -> Bool, delete: @escaping @MainActor () -> Bool,
                 enter: @escaping @MainActor () -> Bool) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            let isBack = (event.type == .keyDown && event.keyCode == 53)
                || (event.type == .otherMouseDown && event.buttonNumber == 3)
            let isDelete = event.type == .keyDown && (event.keyCode == 51 || event.keyCode == 117)
                && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let isEnter = event.type == .keyDown && (event.keyCode == 36 || event.keyCode == 76)
                && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard isBack || isDelete || isEnter else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                if isBack { return back() }
                let responder = event.window?.firstResponder
                if responder is DesktopVideoView || responder is NSText { return false }
                return isEnter ? enter() : delete()
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
