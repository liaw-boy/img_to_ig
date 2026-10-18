import SwiftUI
import IGPubCore

/// One frame for every main-window screen: fixed 240 pt sidebar (logo row on top) + content area.
struct AppShell<Side: View, Main: View>: View {
    @ViewBuilder var sidebar: Side
    @ViewBuilder var main: Main

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                LogoRow()
                sidebar
            }
            .padding(.top, Theme.Space.xl)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)
            .frame(width: Theme.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.sidebarLine).frame(width: 1)
            main.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.canvas)
    }
}

private struct LogoRow: View {
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            AppLogo()
            VStack(alignment: .leading, spacing: 0) {
                Text("img_to_ig").font(Theme.Font.bodyStrong).foregroundStyle(Theme.ink)
                Text("Instagram 發佈工具").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            }
        }
        .frame(height: Theme.logoRowHeight, alignment: .leading)
    }
}

/// The visible size of the page's scrolling area, for content that should fill the window (the step 3 preview).
private struct PageViewportKey: EnvironmentKey { static let defaultValue: CGSize = .zero }
extension EnvironmentValues {
    var pageViewport: CGSize {
        get { self[PageViewportKey.self] }
        set { self[PageViewportKey.self] = newValue }
    }
}

/// Header (fixed) + scrolling content column + pinned footer bar.
struct PageScaffold<Content: View, Footer: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var wide = false          // fill the window width (photo grids) instead of the 720 pt reading column
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow).font(Theme.Font.eyebrow).foregroundStyle(Theme.accentText).lineLimit(1)
                Text(title).font(Theme.Font.display).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(Theme.Font.body).lineSpacing(Theme.bodyLineSpacing).foregroundStyle(Theme.ink2)
                    .lineLimit(2, reservesSpace: true)       // one line on a wide window; the reserved second line keeps pages aligned
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.s)
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, 28)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { g in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) { content }
                        .padding(.horizontal, Theme.Space.xxl)
                        .padding(.bottom, Theme.Space.xxl)
                        .frame(maxWidth: wide ? .infinity : Theme.contentMaxWidth + 2 * Theme.Space.xxl, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.pageViewport, g.size)
            }
            FooterBar { footer }
        }
    }
}

/// 64 pt action bar pinned to the bottom of the content area.
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: Theme.Space.m) { content }
                .padding(.horizontal, Theme.Space.xxl)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.footerHeight - 1)
        }
        .background(Theme.canvas)
    }
}

/// Sidebar navigation row (44 pt): glyph slot 24 + label.
struct SidebarNavRow: View {
    let symbol: String
    let mark: String       // darkroom glyph
    let title: String
    var selected = false
    @Environment(\.iconStyle) private var style
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Group {
                if style == .darkroom {
                    Text(mark).font(Theme.Font.monoStrong)
                } else {
                    Image(systemName: symbol).font(.system(size: Theme.navIconSize))
                }
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(selected ? Theme.accentText : Theme.ink2)
            .accessibilityHidden(true)
            Text(title).font(selected ? Theme.Font.label : Theme.Font.callout).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.controlHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface)
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Wizard steps: symbols = badge list; darkroom = vertical film strip. Same 56 pt rows and container padding.
struct WizardSteps: View {
    struct Item { let title: String; let short: String; let summary: String }
    let items: [Item]
    let current: Int
    let done: Set<Int>
    let select: (Int) -> Void
    @Environment(\.iconStyle) private var style

    var body: some View {
        let dark = style == .darkroom
        VStack(spacing: Theme.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                let isCurrent = i == current
                let isDone = done.contains(i) && !isCurrent
                Button { select(i) } label: {
                    HStack(spacing: Theme.Space.m) {
                        Group {
                            if dark {
                                Text(String(format: "%02d", i + 1)).font(Theme.Font.monoStrong)
                                    .foregroundStyle(isCurrent ? Theme.filmAccentCurrent : isDone ? Theme.filmText : Theme.filmTextIdle)
                            } else {
                                StepBadge(number: i + 1, state: isCurrent ? .current : isDone ? .done : .upcoming)
                            }
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(dark ? "▸ \(it.short)" : it.title)
                                .font(isCurrent ? Theme.Font.label : Theme.Font.callout)
                                .foregroundStyle(dark ? (isCurrent ? Theme.filmInkCurrent : isDone ? Theme.filmText : Theme.filmTextIdle)
                                                      : Theme.ink)
                                .lineLimit(1)
                            Text(dark ? (isCurrent ? "EXPOSING" : isDone ? "DONE" : "—") : it.summary)
                                .font(dark ? Theme.Font.monoCaption : Theme.Font.caption)
                                .foregroundStyle(dark ? (isCurrent ? Theme.filmAccentCurrent : isDone ? Theme.filmOK : Theme.filmDash)
                                                      : Theme.ink3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: Theme.sidebarRowHeight)
                    .background {
                        if dark {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isCurrent ? Theme.filmFrameCurrent : isDone ? Theme.filmFrameDone : Theme.filmFrameIdle)
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: 2)
                            }
                        } else if isCurrent {
                            RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("步驟 \(i + 1)：\(it.title)\(isCurrent ? "，目前" : isDone ? "，已完成" : "")")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(Theme.Space.s)
        .background(dark ? Theme.film : Color.clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Token age / days left + refresh button (sidebar bottom). Fixed height in both styles.
struct TokenBlock: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    var body: some View {
        let warn = model.tokenWarn
        let left = model.tokenDaysLeft
        let used = model.tokenAgeDays
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if style == .darkroom {
                    StampLabel(text: "TOKEN \(used.map(String.init) ?? "?")/\(AppModel.tokenLifetimeDays) 天",
                               color: warn ? Theme.warn : Theme.ink3)
                } else {
                    Image(systemName: warn ? "exclamationmark.triangle.fill" : "key").font(Theme.Font.caption)
                        .accessibilityHidden(true)
                    Text("token 已使用 \(used.map(String.init) ?? "?") 天").font(Theme.Font.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(warn ? Theme.warnText : Theme.ink2)
            .frame(height: 24)
            Text(left.map { "約 \($0) 天後到期" } ?? "到期日未知")
                .font(Theme.Font.caption).foregroundStyle(warn ? Theme.warnText : Theme.ink3)
            Button(style == .darkroom ? "換發 token →" : "換發 token") { Task { await model.refreshToken() } }
                .buttonStyle(.igPlainSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!model.canRefreshToken)
                .help(model.refreshHelp)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warn ? Theme.warnSoft : Theme.sidebarCard, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(warn ? Theme.warn : Theme.lineStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("token 狀態")
    }
}
