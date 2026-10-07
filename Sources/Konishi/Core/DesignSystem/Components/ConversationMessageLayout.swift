import SwiftUI

enum ConversationMessageLayout {
    static let columnWidth: CGFloat = 860
    static let userBubbleMaxWidth: CGFloat = 680
}

struct CappedIntrinsicWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let widthLimit = min(maxWidth, proposal.width ?? maxWidth)
        let idealWidth = subview.sizeThatFits(.unspecified).width
        let width = min(idealWidth, widthLimit)
        let size = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let widthLimit = min(maxWidth, bounds.width)
        let idealWidth = subview.sizeThatFits(.unspecified).width
        let width = min(idealWidth, widthLimit)
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

struct UserMessageBubble<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        CappedIntrinsicWidth(maxWidth: ConversationMessageLayout.userBubbleMaxWidth) {
            VStack(alignment: .leading, spacing: 6) {
                Label("You", systemImage: "person.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent.opacity(0.16), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
    }
}

struct AssistantMessageLayout<Content: View>: View {
    let assistantName: String
    let iconSymbol: String
    let accent: Color
    let surface: Color
    let border: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: iconSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text(assistantName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content
            }
            .frame(maxWidth: 960, alignment: .leading)
            Spacer(minLength: 20)
        }
    }
}

struct MessageActionBar<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}