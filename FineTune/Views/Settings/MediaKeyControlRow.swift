// FineTune/Views/Settings/MediaKeyControlRow.swift
import SwiftUI

/// Toggle + attached permission footer (shown when AX is not granted) in one glass card.
@MainActor
struct MediaKeyControlRow: View {
    @Binding var isOn: Bool
    @Bindable var accessibility: AccessibilityPermissionService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingGrantedFlourish = false
    @State private var flourishTask: Task<Void, Never>?

    private static let flourishDuration: Duration = .milliseconds(1200)

    var body: some View {
        VStack(spacing: 0) {
            toggleRow

            if !accessibility.isTrustedCached || showingGrantedFlourish {
                Rectangle()
                    .fill(DesignTokens.Colors.separator.opacity(0.6))
                    .frame(height: 0.5)
                    .padding(.horizontal, DesignTokens.Spacing.sm)

                permissionFooter
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(borderColor, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .animation(
            reduceMotion
                ? .linear(duration: 0.15)
                : .spring(response: 0.35, dampingFraction: 0.85),
            value: accessibility.isTrustedCached
        )
        .animation(
            reduceMotion
                ? .linear(duration: 0.15)
                : .spring(response: 0.35, dampingFraction: 0.85),
            value: showingGrantedFlourish
        )
        .onChange(of: accessibility.isTrustedCached) { oldValue, newValue in
            if !oldValue, newValue { triggerGrantedFlourish() }
        }
    }

    // MARK: - Toggle header

    private var toggleRow: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "keyboard")
                .font(.system(size: DesignTokens.Dimensions.iconSizeSmall))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Volume Keys Control FineTune")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Use F10–F12 to control the default output device's volume")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Permission footer

    private var permissionFooter: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: showingGrantedFlourish ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(footerIconColor)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)
                .contentTransition(.symbolEffect(.replace))

            Text(footerMessage)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.xs)

            if showingGrantedFlourish {
                statusPill(granted: true)
            } else {
                Button(action: grantAccess) {
                    HStack(spacing: 3) {
                        Text("Grant")
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Registers FineTune in the Accessibility list and opens System Settings.")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func statusPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(granted ? DesignTokens.Colors.vuGreen : DesignTokens.Colors.mutedIndicator)
                .frame(width: 5, height: 5)
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    // MARK: - Derived values

    private var footerMessage: String {
        showingGrantedFlourish
            ? "Access granted — volume keys now control FineTune."
            : "FineTune needs Accessibility to intercept F10 / F11 / F12."
    }

    private var footerIconColor: Color {
        showingGrantedFlourish
            ? DesignTokens.Colors.vuGreen
            : DesignTokens.Colors.accentPrimary
    }

    private var borderColor: Color {
        if showingGrantedFlourish {
            return DesignTokens.Colors.vuGreen.opacity(0.45)
        }
        if !accessibility.isTrustedCached {
            return DesignTokens.Colors.glassBorder
        }
        return DesignTokens.Colors.glassBorder
    }

    // MARK: - Actions

    private func grantAccess() {
        accessibility.requestAccess()
    }

    private func triggerGrantedFlourish() {
        flourishTask?.cancel()
        showingGrantedFlourish = true

        flourishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.flourishDuration)
            guard !Task.isCancelled else { return }
            showingGrantedFlourish = false
        }
    }
}

// MARK: - Previews

#Preview("Untrusted / Trusted") {
    PreviewContainer {
        VStack(spacing: DesignTokens.Spacing.sm) {
            MediaKeyControlRow(
                isOn: .constant(true),
                accessibility: AccessibilityPermissionService()
            )
        }
        .frame(width: 560)
        .padding()
    }
}
