import SwiftUI
import OloKit

/// "Before you start": the Olo Terms of Use in plain English, shown as a sheet before
/// the first conversation and again whenever Legal.termsVersion changes. It closes only
/// through "I agree and continue" (or Quit). Settings > Account can reopen it to read.
struct TermsGateView: View {
    @Environment(AppModel.self) private var model

    private enum Reason { case firstRun, changed, rereading }

    private var reason: Reason {
        let store = LegalStore()
        if store.accepted() { return .rereading }
        if store.acceptedOlderVersion() { return .changed }
        return .firstRun
    }

    var body: some View {
        let reason = self.reason
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    HeliusAtomView(mode: reason == .firstRun ? .launch : .idle, size: 200)
                    Text(title(for: reason)).font(.title.weight(.semibold))
                    Text(intro(for: reason))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Legal.summary, id: \.title) { point in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.title).font(.headline)
                                Text(point.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, 6)
                    HStack(spacing: 18) {
                        Link("Terms of Use", destination: Legal.termsURL)
                        Link("Privacy Policy", destination: Legal.privacyURL)
                        Link("Apple's standard EULA", destination: Legal.eulaURL)
                    }
                    .font(.callout)
                    Text("Version \(Legal.termsVersion). \(Legal.provider).")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if reason == .rereading {
                    Button("Close") { model.showTerms = false }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Quit") { NSApp.terminate(nil) }
                }
                Spacer()
                if reason != .rereading {
                    Button("I agree and continue") { model.acceptTerms() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 820, minHeight: 560, idealHeight: 700, maxHeight: 820)
        .interactiveDismissDisabled()
    }

    private func title(for reason: Reason) -> String {
        switch reason {
        case .firstRun: return "Before you start"
        case .changed: return "The terms have changed"
        case .rereading: return "Olo Terms of Use"
        }
    }

    private func intro(for reason: Reason) -> String {
        switch reason {
        case .firstRun:
            return "A short summary of the Olo Terms of Use in plain English. The full terms, the privacy policy and Apple's licence are linked below."
        case .changed:
            return "You agreed to an earlier version. Here is what the terms say now, in plain English; the full text is linked below."
        case .rereading:
            return "What you agreed to, in plain English. The full terms, the privacy policy and Apple's licence are linked below."
        }
    }
}
