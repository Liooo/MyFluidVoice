import SwiftUI

/// Release notes stay intentionally unavailable until MyFluidVoice has its own
/// release channel. This prevents the fork from presenting upstream releases.
struct ChangelogView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Label("Release notes are not available yet", systemImage: "doc.text")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)

            Text("MyFluidVoice will publish release notes here when its release infrastructure is ready.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ChangelogView()
}
