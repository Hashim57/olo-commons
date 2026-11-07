import SwiftUI
import OloKit

/// The one-time card: "Add my questions to the Olo brain?" Shown when no default has been
/// chosen (the account's brainSharing is null, or nothing is saved on this Mac when anonymous).
/// It closes only through one of its two buttons.
struct BrainChoiceSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(BrainText.cardTitle, systemImage: "brain.head.profile")
                .font(.title2.weight(.semibold))
            Text(BrainText.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Private chats are never added. " + BrainText.privateExplainer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(BrainText.viewBrain, destination: BrainLinks.view)
                .font(.callout)
            HStack {
                Button(BrainText.keepPrivate) { model.setBrainSharing(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(BrainText.share) { model.setBrainSharing(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
