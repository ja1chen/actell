import SwiftUI

/// Small leading icon shared by the reasoning header, the folded turn
/// summary, and the tool cards. The fixed box keeps every symbol at the same
/// footprint (AspectFit). Decorative only: it carries no information of its
/// own, so it stays out of the accessibility tree.
struct MessageHeaderIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
