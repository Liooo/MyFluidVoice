import SwiftUI

struct FeedbackView: View {
    @Environment(\.theme) private var theme

    private let issueURL = URL(string: "https://github.com/Liooo/MyFluidVoice/issues/new/choose")!
    private let repositoryURL = URL(string: "https://github.com/Liooo/MyFluidVoice")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(self.theme.palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Feedback")
                            .font(.system(size: 28, weight: .bold))
                        Text("Help improve MyFluidVoice on GitHub")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }

                ThemedCard(style: .prominent, hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Report a bug or suggest a feature")
                            .font(.system(size: 18, weight: .semibold))

                        Text("MyFluidVoice does not operate a private feedback endpoint. GitHub Issues is the public, reviewable place for reports and ideas. Review your issue before submitting it, and do not include transcripts, API keys, or debug logs that contain private information.")
                            .font(.system(size: 14))
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Link(destination: self.issueURL) {
                                Label("Open GitHub Issues", systemImage: "exclamationmark.bubble.fill")
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                            }
                            .fluidButton(.glass, size: .medium)
                            .buttonHoverEffect()

                            Link(destination: self.repositoryURL) {
                                Label("View Repository", systemImage: "star.fill")
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                            }
                            .fluidButton(.glass, size: .medium)
                            .buttonHoverEffect()
                        }
                    }
                    .padding(20)
                }
            }
            .padding(24)
        }
    }
}

#Preview {
    FeedbackView()
}
