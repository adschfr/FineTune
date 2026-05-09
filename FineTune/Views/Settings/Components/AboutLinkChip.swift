// FineTune/Views/Settings/Components/AboutLinkChip.swift
import AppKit
import SwiftUI

/// Pill-shaped link button used on the redesigned About hero. Hover swaps
/// the SF Symbol to the filled variant in `hoverColor`, and the chip's
/// border brightens. Hover transition collapses to instant under reduced
/// motion.
@MainActor
struct AboutLinkChip: View {
    let label: String
    let icon: String
    let hoverIcon: String
    let hoverColor: Color
    let url: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isHovered ? hoverIcon : icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? hoverColor : DesignTokens.Colors.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(
                    isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Previews

#Preview("About Link Chip") {
    HStack(spacing: 8) {
        AboutLinkChip(
            label: "Star on GitHub",
            icon: "star",
            hoverIcon: "star.fill",
            hoverColor: .yellow,
            url: URL(string: "https://github.com/ronitsingh10/FineTune")!
        )
        AboutLinkChip(
            label: "Support FineTune",
            icon: "heart",
            hoverIcon: "heart.fill",
            hoverColor: .pink,
            url: DesignTokens.Links.support
        )
        AboutLinkChip(
            label: "GPL-3.0",
            icon: "doc.text",
            hoverIcon: "doc.text.fill",
            hoverColor: .blue,
            url: DesignTokens.Links.license
        )
    }
    .padding(24)
    .frame(width: 520, height: 80)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
