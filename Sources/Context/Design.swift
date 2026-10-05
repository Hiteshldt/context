import SwiftUI
import AppKit

// MARK: - Theme

/// One visual language for the whole app: warm paper surfaces, high-contrast ink, and a vivid colour per project.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

    // Surfaces
    static let background = dynamic(light: rgb(251, 250, 247), dark: rgb(19, 19, 21))
    static let sidebar = dynamic(light: rgb(243, 241, 236), dark: rgb(25, 25, 28))
    static let card = dynamic(light: rgb(255, 255, 255), dark: rgb(30, 30, 34))
    static let raised = dynamic(light: rgb(240, 238, 232), dark: rgb(40, 40, 46))
    static let border = dynamic(light: rgb(0, 0, 0, 0.09), dark: rgb(255, 255, 255, 0.1))
    static let hover = dynamic(light: rgb(0, 0, 0, 0.045), dark: rgb(255, 255, 255, 0.06))

    // Ink: chosen for comfortable contrast, including secondary text.
    static let ink = dynamic(light: rgb(24, 24, 27), dark: rgb(244, 244, 246))
    static let ink2 = dynamic(light: rgb(82, 80, 76), dark: rgb(176, 176, 184))
    static let ink3 = dynamic(light: rgb(134, 131, 124), dark: rgb(124, 124, 133))

    // Brand and signal colours
    static let accent = dynamic(light: rgb(84, 80, 222), dark: rgb(150, 150, 255))
    static let overdue = dynamic(light: rgb(206, 52, 62), dark: rgb(255, 118, 124))
    static let today = dynamic(light: rgb(196, 110, 12), dark: rgb(255, 178, 84))
    static let upcoming = dynamic(light: rgb(36, 110, 214), dark: rgb(120, 172, 255))
    static let success = dynamic(light: rgb(16, 140, 100), dark: rgb(74, 214, 164))
    static let muted = ink3

    static let projectColors: [(id: String, name: String)] = [
        ("sage", "Emerald"), ("blue", "Blue"), ("orange", "Orange"), ("purple", "Violet"),
        ("rose", "Rose"), ("gold", "Amber"), ("teal", "Teal"), ("slate", "Slate"),
    ]

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": return dynamic(light: rgb(41, 112, 238), dark: rgb(110, 166, 255))
        case "orange": return dynamic(light: rgb(232, 104, 34), dark: rgb(255, 154, 96))
        case "purple": return dynamic(light: rgb(126, 82, 238), dark: rgb(178, 152, 255))
        case "rose": return dynamic(light: rgb(222, 62, 114), dark: rgb(255, 128, 168))
        case "gold": return dynamic(light: rgb(202, 138, 4), dark: rgb(244, 200, 80))
        case "teal": return dynamic(light: rgb(12, 148, 162), dark: rgb(84, 210, 222))
        case "slate": return dynamic(light: rgb(88, 102, 126), dark: rgb(160, 176, 200))
        default: return dynamic(light: rgb(14, 150, 110), dark: rgb(66, 214, 164)) // "sage"
        }
    }

    static func status(_ status: ProjectStatus) -> Color {
        switch status {
        case .active: return success
        case .planning: return upcoming
        case .paused: return today
        case .maintenance: return color("teal")
        case .done: return ink3
        }
    }
}

/// Type scale. Display uses the system serif (New York) for a warmer, more editorial feel.
enum T {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static let h1 = Font.system(size: 22, weight: .semibold)
    static let h2 = Font.system(size: 17, weight: .semibold)
    static let h3 = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14.5)
    static let bodyMedium = Font.system(size: 14.5, weight: .medium)
    static let small = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let label = Font.system(size: 11, weight: .semibold)
}

private struct TintKey: EnvironmentKey { static let defaultValue: Color = Theme.accent }
extension EnvironmentValues {
    /// The colour of the project being viewed; the app accent elsewhere.
    var pageTint: Color { get { self[TintKey.self] } set { self[TintKey.self] = newValue } }
}

// MARK: - Navigation plumbing

enum Route: Hashable { case home, tasks, client(UUID), project(UUID) }

enum SheetRoute: Identifiable {
    case project(Project), client(Client), entry(Entry), task(WorkTask), content(ContentItem)
    case quickLook(URL), markdown(URL), backup
    var id: String {
        switch self {
        case .project(let p): return "project-\(p.id)"
        case .client(let c): return "client-\(c.id)"
        case .entry(let e): return "entry-\(e.id)"
        case .task(let t): return "task-\(t.id)"
        case .content(let c): return "content-\(c.id)"
        case .quickLook(let url): return "ql-\(url.path)"
        case .markdown(let url): return "md-\(url.path)"
        case .backup: return "backup"
        }
    }
}

struct PresentAction { var action: (SheetRoute) -> Void = { _ in }; func callAsFunction(_ route: SheetRoute) { action(route) } }
struct NavigateAction { var action: (Route) -> Void = { _ in }; func callAsFunction(_ route: Route) { action(route) } }
private struct PresentKey: EnvironmentKey { static let defaultValue = PresentAction() }
private struct NavigateKey: EnvironmentKey { static let defaultValue = NavigateAction() }
extension EnvironmentValues {
    var present: PresentAction { get { self[PresentKey.self] } set { self[PresentKey.self] = newValue } }
    var navigate: NavigateAction { get { self[NavigateKey.self] } set { self[NavigateKey.self] = newValue } }
}

// MARK: - Buttons

/// Filled, high-emphasis action. (Environment values are read in a child view so the style
/// also works when wrapped in `AnyButtonStyle`.)
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, compact: compact) }
    struct Styled: View {
        @Environment(\.pageTint) var tint
        @Environment(\.isEnabled) var enabled
        let configuration: Configuration
        let compact: Bool
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 5.5 : 7.5)
                .background(tint.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

/// Quiet, filled action.
struct SoftButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, compact: compact) }
    struct Styled: View {
        @Environment(\.isEnabled) var enabled
        let configuration: Configuration
        let compact: Bool
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
                .foregroundStyle(enabled ? Theme.ink : Theme.ink3)
                .padding(.horizontal, compact ? 10 : 13).padding(.vertical, compact ? 5.5 : 7.5)
                .background(configuration.isPressed ? Theme.border : Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

/// A square icon button with a hover background.
struct IconButton: View {
    let icon: String
    var help: String
    var size: CGFloat = 28
    var tint: Color = Theme.ink2
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(help).accessibilityLabel(help)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}
extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softCompact: SoftButtonStyle { SoftButtonStyle(compact: true) }
}

/// The label for a menu that should look like one of our buttons.
struct MenuLabel: View {
    @Environment(\.pageTint) var tint
    let title: String
    var icon: String? = nil
    var primary = false
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: compact ? 11 : 12, weight: .semibold)) }
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .font(.system(size: compact ? 12.5 : 13.5, weight: primary ? .semibold : .medium))
        .foregroundStyle(primary ? Color.white : Theme.ink)
        .padding(.horizontal, compact ? 10 : 13).padding(.vertical, compact ? 5.5 : 7.5)
        .background(primary ? tint : Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Building blocks

struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 38
    var body: some View {
        let tint = Theme.color(project.color)
        Text(String(project.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ClientIcon: View {
    let name: String
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Theme.ink2)
            .frame(width: size, height: size)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(name)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .offset(y: hovering ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.1 : 0), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
    }
}
extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

/// A list row background that responds to hover.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = 9
    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
extension View { func hoverRow(radius: CGFloat = 9) -> some View { modifier(HoverRow(radius: radius)) } }

/// Small uppercase label used above groups.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.ink3
    var body: some View {
        Text(text.uppercased()).font(T.label).tracking(1.1).foregroundStyle(color)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var icon: String? = nil
    var tint: Color = Theme.ink
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint) }
            Text(title).font(T.h2).foregroundStyle(Theme.ink)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.raised, in: Capsule())
            }
            Spacer()
            trailing
        }
    }
}
extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, icon: String? = nil, tint: Color = Theme.ink) {
        self.init(title: title, count: count, icon: icon, tint: tint) { EmptyView() }
    }
}

struct EmptyState: View {
    @Environment(\.pageTint) var tint
    let icon: String
    let title: String
    let message: String
    var compact = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: icon).font(.system(size: compact ? 18 : 26, weight: .regular)).foregroundStyle(tint)
                .frame(width: compact ? 40 : 60, height: compact ? 40 : 60)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous))
            if !title.isEmpty { Text(title).font(compact ? T.bodyMedium : T.h2).foregroundStyle(Theme.ink) }
            if !message.isEmpty {
                Text(message).font(compact ? T.small : T.body).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.primary).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, compact ? 20 : 40)
    }
}

struct Pill: View {
    let text: String
    var icon: String? = nil
    var color: Color = Theme.ink2
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// A row of selectable chips. Chips wrap when space is tight but never break a label.
struct ChipPicker<Value: Hashable>: View {
    @Environment(\.pageTint) var tint
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 11).padding(.vertical, 5.5)
                        .foregroundStyle(selected ? Color.white : Theme.ink2)
                        .background(selected ? tint : Theme.raised, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// A compact two- or three-way switch.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String, icon: String?)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        if let icon = option.icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                        Text(option.label)
                    }
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(selected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A keyboard hint such as ⌘K.
struct KeyHint: View {
    let keys: String
    var body: some View {
        Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.ink3)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}

/// Wraps children onto new lines when they run out of horizontal room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A page's scrolling column with consistent margins.
struct Page<Content: View>: View {
    var maxWidth: CGFloat = 1120
    var spacing: CGFloat = 26
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 40)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Dates

enum DueText {
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> (text: String, color: Color) {
        let time = date.formatted(date: .omitted, time: .shortened)
        if date < now {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if days == 0 { return ("Due \(time)", Theme.overdue) }
            return (days == 1 ? "Yesterday" : "\(days) days overdue", Theme.overdue)
        }
        if calendar.isDateInToday(date) { return ("Today \(time)", Theme.today) }
        if calendar.isDateInTomorrow(date) { return ("Tomorrow \(time)", Theme.upcoming) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 7 { return (date.formatted(.dateTime.weekday(.wide).hour().minute()), Theme.ink2) }
        return (date.formatted(.dateTime.month(.abbreviated).day().hour().minute()), Theme.ink2)
    }

    /// "today", "yesterday", "3 days ago", "2 weeks ago" — for how long since a project was last opened.
    static func ago(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }
}

enum Buckets {
    static func endOfToday(_ now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
    }
    static func overdue(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        tasks.filter { !$0.isComplete && !$0.isSnoozed(at: now) && ($0.due ?? .distantFuture) < Calendar.current.startOfDay(for: now) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    /// Due today (including earlier today and already passed times).
    static func today(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        let start = Calendar.current.startOfDay(for: now), end = endOfToday(now)
        return tasks.filter { !$0.isComplete && !$0.isSnoozed(at: now) && ($0.due.map { $0 >= start && $0 < end } ?? false) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    static func upcoming(_ tasks: [WorkTask], days: Int = 7, now: Date = Date()) -> [WorkTask] {
        let start = endOfToday(now)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        return tasks.filter { !$0.isComplete && !$0.isSnoozed(at: now) && ($0.due.map { $0 >= start && $0 < end } ?? false) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    static func snoozed(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        tasks.filter { $0.isSnoozed(at: now) }.sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }
    static func needsAttention(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        overdue(tasks, now: now) + today(tasks, now: now)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
