import SwiftUI
import AppKit

struct CircularGaugeView: View {
    let provider: AIProvider
    let primaryPercent: Int
    let primaryLimitReached: Bool
    let showsPrimaryMetric: Bool
    let secondaryPercent: Int
    let secondaryLimitReached: Bool
    let showsSecondaryMetric: Bool
    let isLoading: Bool
    let label: String
    let primaryLabel: String   // e.g. "5h" or "7d"
    let secondaryLabel: String // e.g. "7d" or "Build"
    let resetAt: Date?
    let weeklyResetAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    private var baseAccent: Color {
        provider.primaryAccent
    }

    private var statusColor: Color {
        if (showsPrimaryMetric && primaryLimitReached) || (showsSecondaryMetric && secondaryLimitReached) {
            return .critical
        }
        let worst = max(showsPrimaryMetric ? primaryPercent : 0, showsSecondaryMetric ? secondaryPercent : 0)
        if worst >= 95 { return .critical }
        if worst >= 85 { return .warningAmber }
        return baseAccent
    }

    private var primaryFill: Double { Double(max(0, min(100, primaryPercent))) / 100.0 }
    private var secondaryFill: Double { Double(max(0, min(100, secondaryPercent))) / 100.0 }

    private var secondaryOpacity: Double {
        let worst = max(showsPrimaryMetric ? primaryPercent : 0, showsSecondaryMetric ? secondaryPercent : 0)
        return worst >= 85 ? 0.65 : 0.45
    }

    private var secondaryTextOpacity: Double {
        let worst = max(showsPrimaryMetric ? primaryPercent : 0, showsSecondaryMetric ? secondaryPercent : 0)
        return worst >= 85 ? 0.75 : 0.65
    }

    private var primaryCaptionColor: Color {
        let worst = max(showsPrimaryMetric ? primaryPercent : 0, showsSecondaryMetric ? secondaryPercent : 0)
        if (showsPrimaryMetric && primaryLimitReached) || (showsSecondaryMetric && secondaryLimitReached) || worst >= 95 {
            return .critical
        }
        if worst >= 85 { return .warningAmber }
        return baseAccent.opacity(0.9)
    }

    private let outerLw: CGFloat = 9
    private let innerLw: CGFloat = 7
    private var innerPad: CGFloat { outerLw / 2 + 2 + innerLw / 2 }

    private var trackColor: Color {
        Color.secondary.opacity(0.18)
    }

    var body: some View {
        VStack(spacing: 6) {
            arcs
            caption
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Arcs

    private var arcs: some View {
        ZStack {
            // Outer track
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(trackColor, style: StrokeStyle(lineWidth: outerLw, lineCap: .butt))
                .rotationEffect(.degrees(135))

            // Outer fill (Primary)
            if showsPrimaryMetric {
                Circle()
                    .trim(from: 0, to: 0.75 * primaryFill)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: outerLw, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                    .animation(.easeInOut(duration: 0.4), value: primaryFill)
            }

            // Inner track
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(trackColor, style: StrokeStyle(lineWidth: innerLw, lineCap: .butt))
                .rotationEffect(.degrees(135))
                .padding(innerPad)

            // Inner fill (Secondary)
            if showsSecondaryMetric {
                Circle()
                    .trim(from: 0, to: 0.75 * secondaryFill)
                    .stroke(statusColor.opacity(secondaryOpacity), style: StrokeStyle(lineWidth: innerLw, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                    .padding(innerPad)
                    .animation(.easeInOut(duration: 0.4), value: secondaryFill)
            }

            // Center content
            VStack(spacing: 4) {
                Image(systemName: provider.iconSystemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)

                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    VStack(spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(showsPrimaryMetric ? "\(primaryPercent)%" : "—")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(showsPrimaryMetric ? statusColor : Color.secondary.opacity(0.6))
                            Text(primaryLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(showsPrimaryMetric ? statusColor : Color.secondary.opacity(0.6))
                        }
                        if showsSecondaryMetric {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(secondaryPercent)%")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(statusColor.opacity(secondaryTextOpacity))
                                Text(secondaryLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(statusColor.opacity(secondaryTextOpacity))
                            }
                        }
                    }
                }
            }

            // Refresh button in bottom arc opening
            VStack {
                Spacer()
                ZStack {
                    RefreshButton(action: onRefresh)
                        .opacity(isRefreshing ? 0 : 1)
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                        .opacity(isRefreshing ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.15), value: isRefreshing)
                .padding(.bottom, 2)
                .offset(y: 3)
            }
        }
        .frame(width: 114, height: 114)
    }

    // MARK: - Caption & Reset Countdown

    private var caption: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(Color.primary)

            VStack(spacing: 1) {
                if showsPrimaryMetric {
                    Text(primaryCountdownText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(primaryCaptionColor)
                } else if !isLoading {
                    Text("No \(primaryLabel) limit")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }

                if let reset = weeklyResetAt ?? resetAt, reset > Date() {
                    let seconds = Int(reset.timeIntervalSince(Date()))
                    Text("in \(CountdownTextFormatter.duration(seconds, style: .compact))")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(primaryCaptionColor.opacity(0.85))
                }
            }
        }
    }

    private var primaryCountdownText: String {
        ResetTimeTextFormatter.compactWindowCaption(primaryLabel, resetAt: resetAt ?? weeklyResetAt)
    }
}

// MARK: - Refresh Button
private struct RefreshButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary.opacity(0.7))
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovering ? Color.secondary.opacity(0.2) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
