import SwiftUI
import AppKit

// Design tokens ("樣式規格 · 暗房" + the unified-layout rules). Views use only these values.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A color that resolves per appearance (light / dark) without an asset catalog.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Two glyph languages the user can compare. Switching only swaps glyphs and labels — never a metric.
enum IconStyle: String, CaseIterable, Identifiable {
    case darkroom, symbols
    static let key = "iconStyle"
    var id: String { rawValue }
    var label: String { self == .darkroom ? "暗房（文字與裁切線）" : "系統圖示（SF Symbols）" }
}

private struct IconStyleKey: EnvironmentKey { static let defaultValue: IconStyle = .symbols }
extension EnvironmentValues {
    var iconStyle: IconStyle {
        get { self[IconStyleKey.self] }
        set { self[IconStyleKey.self] = newValue }
    }
}

enum Theme {
    // surfaces
    static let canvas = Color(light: 0xF4F2EE, dark: 0x161513)
    static let sidebar = Color(light: 0xECE8E1, dark: 0x1E1C1A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x24221F)
    static let surfaceMuted = Color(light: 0xFAF8F5, dark: 0x1E1C1A)
    static let sidebarCard = Color(light: 0xFFFFFF, dark: 0x302D29)
    static let segment = Color(light: 0xE7E2D9, dark: 0x2E2B27)
    static let line = Color(light: 0xE2DED6, dark: 0x3A3732)
    static let lineSoft = Color(light: 0xEFECE6, dark: 0x2E2B27)
    static let sidebarLine = Color(light: 0xDCD7CE, dark: 0x34312C)
    static let lineStrong = Color(light: 0xCFC9BE, dark: 0x4A463F)
    static let dash = Color(light: 0xBDB6A9, dark: 0x5A554C)
    static let badgeRing = Color(light: 0x8A847A, dark: 0x8A847A)

    // text
    static let ink = Color(light: 0x1B1A18, dark: 0xF2EFE9)
    static let ink2 = Color(light: 0x3D3A35, dark: 0xCDC8BF)
    static let ink3 = Color(light: 0x5E5A54, dark: 0xA29C92)
    static let onInk = Color(light: 0xFFFFFF, dark: 0x161513)

    // accent (forward / publish only)
    static let accent = Color(light: 0xC2410C, dark: 0xE0652A)
    static let accentSoft = Color(light: 0xFBEADF, dark: 0x3A2416)
    static let accentText = Color(light: 0xA8380A, dark: 0xF08A55)
    static let accentDeep = Color(light: 0x6B2A08, dark: 0xF3B48F)

    // status (always paired with a glyph or stamp)
    static let success = Color(light: 0x1F6F4A, dark: 0x4CAF7D)
    static let successSoft = Color(light: 0xE3F1E9, dark: 0x1D3328)
    static let warn = Color(light: 0x9A5B00, dark: 0xE0A84A)
    static let warnSoft = Color(light: 0xFFF4DC, dark: 0x3A2E15)
    static let warnText = Color(light: 0x6E4100, dark: 0xF2C879)
    static let danger = Color(light: 0xB42318, dark: 0xF0705F)
    static let dangerSoft = Color(light: 0xFDF1EF, dark: 0x3A1E1B)
    static let dangerText = Color(light: 0x8A1A12, dark: 0xF59A8C)
    static let disabledFill = Color(light: 0xD9D4CB, dark: 0x3A3732)

    // darkroom film strip (stays dark in both appearances)
    static let film = Color(light: 0x1B1A18, dark: 0x0B0A09)
    static let filmFrameDone = Color(hex: 0x3A3732)
    static let filmFrameIdle = Color(hex: 0x2A2825)
    static let filmFrameCurrent = Color(hex: 0xF4F2EE)
    static let filmInkCurrent = Color(hex: 0x1B1A18)
    static let filmAccentCurrent = Color(hex: 0xA8380A)
    static let filmText = Color(hex: 0xB9B2A6)
    static let filmTextIdle = Color(hex: 0x8A847A)
    static let filmDash = Color(hex: 0x6F695F)
    static let filmOK = Color(hex: 0x8FD1AE)

    /// Type scale — the only sizes used in the app.
    enum Font {
        static let display = SwiftUI.Font.system(size: 28, weight: .bold)
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15)
        static let bodyStrong = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let callout = SwiftUI.Font.system(size: 13)
        static let label = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let eyebrow = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 12)
        static let mono = SwiftUI.Font.system(size: 13, design: .monospaced)
        static let monoStrong = SwiftUI.Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let monoCaption = SwiftUI.Font.system(size: 12, weight: .semibold, design: .monospaced)
    }
    static let bodyLineSpacing: CGFloat = 6
    static let calloutLineSpacing: CGFloat = 4

    /// Spacing scale — the only paddings / gaps used.
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    static let navIconSize: CGFloat = 18
    static let paragraphMaxWidth: CGFloat = 560
    static let contentMaxWidth: CGFloat = 720
    static let sidebarWidth: CGFloat = 240
    static let sidebarRowHeight: CGFloat = 56
    static let logoRowHeight: CGFloat = 40
    static let footerHeight: CGFloat = 64
    static let controlHeight: CGFloat = 44
    static let controlHeightSmall: CGFloat = 36
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 24
    static let cardPaddingCompact: CGFloat = 16
    static let statusSlot = CGSize(width: 64, height: 24)
}

extension View {
    /// Body text: 15 pt, CJK-friendly line height, paragraph width cap.
    func igBody(_ color: Color = Theme.ink2) -> some View {
        font(Theme.Font.body).lineSpacing(Theme.bodyLineSpacing).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.paragraphMaxWidth, alignment: .leading)
    }
    func igCallout(_ color: Color = Theme.ink2) -> some View {
        font(Theme.Font.callout).lineSpacing(Theme.calloutLineSpacing).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: buttons (metrics identical in both icon styles)

/// Accent orange. At most one per screen (下一步、發佈).
struct IGPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyStrong)
            .foregroundStyle(enabled ? Color.white : Theme.ink3)
            .padding(.horizontal, Theme.Space.xl)
            .frame(minHeight: Theme.controlHeight)
            .background(enabled ? Theme.accent : Theme.disabledFill, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Ink black (存入鑰匙圈、開啟網頁).
struct IGSecondaryButtonStyle: ButtonStyle {
    var small = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? Theme.Font.label : Theme.Font.body)
            .foregroundStyle(enabled ? Theme.onInk : Theme.ink3)
            .padding(.horizontal, small ? Theme.Space.m : Theme.Space.l)
            .frame(minHeight: small ? Theme.controlHeightSmall : Theme.controlHeight)
            .background(enabled ? Theme.ink : Theme.disabledFill, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// Bordered, neutral (上一步、重新測試、加入照片).
struct IGPlainButtonStyle: ButtonStyle {
    var small = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? Theme.Font.callout : Theme.Font.body)
            .foregroundStyle(enabled ? Theme.ink : Theme.ink3)
            .padding(.horizontal, small ? Theme.Space.m : Theme.Space.l)
            .frame(minHeight: small ? Theme.controlHeightSmall : Theme.controlHeight)
            .background(configuration.isPressed ? Theme.sidebar : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.lineStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
            .contentShape(Rectangle())
    }
}

/// Borderless text button (清空、移除).
struct IGTextButtonStyle: ButtonStyle {
    var color: Color = Theme.ink3
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.callout)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: Theme.controlHeightSmall)
            .opacity(configuration.isPressed || !enabled ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

/// Destructive filled (移除所有資料).
struct IGDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyStrong)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.controlHeight)
            .background(Theme.danger, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == IGPrimaryButtonStyle {
    static var igPrimary: IGPrimaryButtonStyle { IGPrimaryButtonStyle() }
}
extension ButtonStyle where Self == IGSecondaryButtonStyle {
    static var igSecondary: IGSecondaryButtonStyle { IGSecondaryButtonStyle() }
    static var igSecondarySmall: IGSecondaryButtonStyle { IGSecondaryButtonStyle(small: true) }
}
extension ButtonStyle where Self == IGPlainButtonStyle {
    static var igPlain: IGPlainButtonStyle { IGPlainButtonStyle() }
    static var igPlainSmall: IGPlainButtonStyle { IGPlainButtonStyle(small: true) }
}
extension ButtonStyle where Self == IGTextButtonStyle {
    static var igText: IGTextButtonStyle { IGTextButtonStyle() }
}
extension ButtonStyle where Self == IGDangerButtonStyle {
    static var igDanger: IGDangerButtonStyle { IGDangerButtonStyle() }
}

// MARK: card, fields

struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.cardPadding
    var fill: Color = Theme.surface
    var border: Color = Theme.line
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(border, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding, fill: Color = Theme.surface, border: Color = Theme.line) -> some View {
        modifier(CardModifier(padding: padding, fill: fill, border: border))
    }

    /// 44 pt input; `valid` colors the border (nil = neutral).
    func igField(valid: Bool? = nil, mono: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(mono ? Theme.Font.mono : Theme.Font.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.controlHeight)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(valid == true ? Theme.success : valid == false ? Theme.danger : Theme.lineStrong,
                              lineWidth: valid == nil ? 1 : 1.5))
    }
}

// MARK: glyph slots (same frame in both styles)

enum StatusKind { case ok, failed, pending, running, idle, published }

/// Status glyph in a fixed 64×24 slot: SF Symbol circle (symbols) or rubber stamp (darkroom).
struct StatusSlot: View {
    let kind: StatusKind
    @Environment(\.iconStyle) private var style

    var body: some View {
        Group {
            if style == .darkroom {
                StampLabel(text: stampText, color: color)
            } else {
                symbol.frame(width: 24, height: 24)
            }
        }
        .frame(width: Theme.statusSlot.width, height: Theme.statusSlot.height, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(a11y)
    }

    private var stampText: String {
        switch kind {
        case .ok: return "OK"
        case .failed: return "FAILED"
        case .pending: return "PENDING"
        case .running: return "WAIT"
        case .idle: return "—"
        case .published: return "已發佈"
        }
    }
    private var a11y: String {
        switch kind {
        case .ok: return "通過"
        case .failed: return "失敗"
        case .pending: return "尚未完成"
        case .running: return "進行中"
        case .idle: return "等待中"
        case .published: return "已發佈"
        }
    }
    private var color: Color {
        switch kind {
        case .ok, .published: return Theme.success
        case .failed: return Theme.danger
        case .pending: return Theme.warn
        case .running: return Theme.accentText
        case .idle: return Theme.ink3
        }
    }
    @ViewBuilder private var symbol: some View {
        switch kind {
        case .ok, .published:
            Circle().fill(Theme.success)
                .overlay(Image(systemName: "checkmark").font(Theme.Font.monoCaption).foregroundStyle(.white))
        case .failed:
            Circle().fill(Theme.danger)
                .overlay(Image(systemName: "xmark").font(Theme.Font.monoCaption).foregroundStyle(.white))
        case .pending:
            Image(systemName: "clock").font(Theme.Font.bodyStrong).foregroundStyle(Theme.warn)
        case .running:
            ProgressView().controlSize(.small)
        case .idle:
            Circle().strokeBorder(Theme.line, lineWidth: 2)
        }
    }
}

/// Rubber-stamp label: bordered monospaced caps, slightly rotated.
struct StampLabel: View {
    let text: String
    var color: Color = Theme.ink2
    var body: some View {
        Text(text)
            .font(Theme.Font.monoCaption)
            .tracking(1)
            .foregroundStyle(color)
            .lineLimit(1).fixedSize()
            .padding(.vertical, 2).padding(.horizontal, 6)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1.5))
            .rotationEffect(.degrees(-2))
    }
}

/// Inline validation line: glyph in a fixed 16 pt slot + text.
struct StatusLine: View {
    let ok: Bool
    let text: String
    @Environment(\.iconStyle) private var style
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Group {
                if style == .darkroom {
                    Text(ok ? "OK" : "ERR").font(Theme.Font.monoCaption)
                } else {
                    Image(systemName: ok ? "checkmark" : "exclamationmark.circle.fill").font(Theme.Font.caption)
                }
            }
            .frame(width: 28, alignment: .leading)
            .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(ok ? Theme.success : Theme.danger)
        .accessibilityElement(children: .combine)
    }
}

/// Caution note on accent-soft background; glyph slot 28 wide.
struct CautionNote: View {
    let text: String
    @Environment(\.iconStyle) private var style
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Group {
                if style == .darkroom {
                    Text("NOTE").font(Theme.Font.monoCaption)
                } else {
                    Image(systemName: "exclamationmark.circle").font(Theme.Font.label)
                }
            }
            .frame(width: 40, alignment: .leading)
            .accessibilityHidden(true)
            Text(text).igCallout(Theme.accentDeep)
        }
        .foregroundStyle(Theme.accentDeep)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Small pill / chip.
struct Chip: View {
    let text: String
    var fill: Color = Theme.sidebar
    var color: Color = Theme.ink2
    var bold = false
    var mono = false
    var body: some View {
        Text(text)
            .font(mono ? Theme.Font.mono : (bold ? Theme.Font.label : Theme.Font.caption))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Theme.Space.xs).padding(.horizontal, Theme.Space.s)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: logo + darkroom shapes

/// Four L-shaped corner marks (optionally without the bottom-right one).
struct CornerMarks: Shape {
    var length: CGFloat = 10
    var skipBottomRight = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 2, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
        if !skipBottomRight {
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        }
        return p
    }
}

struct BottomRightMark: Shape {
    var length: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - length, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - length))
        return p
    }
}

/// Darkroom logo: crop-mark frame with "IGP"; the bottom-right mark in accent.
struct CropMarkLogo: View {
    var body: some View {
        ZStack {
            CornerMarks(length: 10, skipBottomRight: true).stroke(Theme.ink, lineWidth: 2)
            BottomRightMark(length: 10).stroke(Theme.accent, lineWidth: 2)
            Text("IGP").font(Theme.Font.monoCaption).foregroundStyle(Theme.ink)
        }
        .frame(width: 40, height: 30)
    }
}

/// Logo in a fixed 40×40 slot in both styles.
struct AppLogo: View {
    @Environment(\.iconStyle) private var style
    var body: some View {
        Group {
            if style == .darkroom {
                CropMarkLogo()
            } else {
                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.ink)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "camera").font(Theme.Font.bodyStrong).foregroundStyle(Theme.canvas))
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityElement()
        .accessibilityLabel("img_to_ig")
    }
}

/// Symbols-style step badge: 完成＝綠底勾，目前＝橘底數字，未到＝空心數字.
struct StepBadge: View {
    let number: Int
    let state: StepBadgeState
    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.success)
                Image(systemName: "checkmark").font(Theme.Font.monoCaption).foregroundStyle(.white)
            case .current:
                Circle().fill(Theme.accent)
                Text("\(number)").font(Theme.Font.label).foregroundStyle(.white)
            case .upcoming:
                Circle().strokeBorder(Theme.badgeRing, lineWidth: 1.5)
                Text("\(number)").font(Theme.Font.callout).foregroundStyle(Theme.ink3)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

enum StepBadgeState { case done, current, upcoming }

/// Drop zone / empty-state frame: dashed border (symbols) or four corner brackets (darkroom). Same metrics.
struct DropFrame<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content
    @Environment(\.iconStyle) private var style
    var body: some View {
        content
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
            .background(highlighted ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                if style == .darkroom {
                    CornerMarks(length: 18).stroke(highlighted ? Theme.accent : Theme.badgeRing, lineWidth: 2).padding(1)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(highlighted ? Theme.accent : Theme.dash, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
    }
}
