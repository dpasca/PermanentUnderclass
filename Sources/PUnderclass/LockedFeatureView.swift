import SwiftUI

/// One treatment for every capability that needs a cloud API key, so a locked
/// feature reads as "this needs setting up" rather than "this is broken".
/// The action always leads to the exact place that fixes it.
struct LockedFeatureCard: View {
    let feature: CloudFeature
    let access: FeatureAccess
    let onResolve: (SettingsSection) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: access == .blockedByPrivacyLock
                ? "lock.laptopcomputer"
                : "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.secondary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle {
                Button(actionTitle) {
                    onResolve(
                        access == .blockedByPrivacyLock ? .privacy : .openAI
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feature.title) is locked")
        .accessibilityValue(message)
    }

    private var message: String {
        CloudCapability(
            hasAPIKey: access != .needsAPIKey,
            privacyLockEnabled: access == .blockedByPrivacyLock
        )
        .lockMessage(for: feature) ?? feature.cloudReason
    }

    private var actionTitle: String? {
        switch access {
        case .available:
            nil
        case .needsAPIKey:
            switch feature {
            case .meetingCapture, .answerMirror:
                "Set Up API Keys…"
            case .mockMeeting, .mockInterview, .bestAccuracyDictation:
                "Set Up OpenAI…"
            }
        case .blockedByPrivacyLock:
            "Open Settings…"
        }
    }
}

extension View {
    /// Dims and disables a panel while showing why, keeping the real UI
    /// visible underneath so the feature is discoverable before it is unlocked.
    @ViewBuilder
    func locked(
        _ feature: CloudFeature,
        access: FeatureAccess,
        onResolve: @escaping (SettingsSection) -> Void
    ) -> some View {
        if access.isAvailable {
            self
        } else {
            ZStack {
                self
                    .disabled(true)
                    .opacity(0.24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                LockedFeatureCard(
                    feature: feature,
                    access: access,
                    onResolve: onResolve
                )
                .padding(10)
            }
        }
    }
}
