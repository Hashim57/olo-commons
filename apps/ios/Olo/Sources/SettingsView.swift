import OloKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calendar: CalendarBridge

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = model.email {
                        LabeledContent("Signed in", value: email)
                        Button("Sign out", role: .destructive) { model.signOut() }
                    } else {
                        Text("You are using Olo without an account, with free questions every day.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Sign in") { model.showSignIn = true }
                    }
                }
                Section {
                    Toggle("Read answers aloud", isOn: $model.speakAnswers)
                } header: { Text("Voice") } footer: { Text("Olo uses this iPhone's own speech recognition and voice. Audio is not recorded or kept.") }
                Section {
                    LabeledContent("Calendar", value: calendar.eventsAllowed ? "Allowed" : "Not allowed")
                    LabeledContent("Reminders", value: calendar.remindersAllowed ? "Allowed" : "Not allowed")
                    if let url = URL(string: UIApplication.openSettingsURLString) { Link("Change in Settings", destination: url) }
                } header: { Text("What Olo can see") } footer: {
                    Text("Your calendar and reminders are read on this iPhone. They are sent to Olo only when you press Plan my day and confirm what is shared.")
                }
                Section("Privacy and terms") {
                    Link("Privacy Policy", destination: Legal.privacyURL)
                    Link("Terms of Use", destination: Legal.termsURL)
                    Text("Private chats are never stored, used for training or added to the Olo brain.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    Text("Answered by Olo, checked by Zeus. Olo is AI and can make mistakes.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
