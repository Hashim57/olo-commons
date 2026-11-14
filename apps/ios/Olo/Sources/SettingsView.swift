import OloKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calendar: CalendarBridge
    @EnvironmentObject var hands: HandsFree
    /// The language Talk to Olo, Quick Ask and dictation listen for; "auto" follows the phone's language.
    @AppStorage(VoiceLanguage.preferenceKey) private var voiceLanguage: String = VoiceLanguage.auto

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(v) (\(b))"
    }

    private var handsFreeNote: String {
        var lines = ["Hey Olo: while Olo is open on screen, say \"Hey Olo\" and then your question. Speech is recognised on this iPhone and the audio never leaves it. The ear button at the top of the chat turns it on and off too. Listening stops when you leave the app; iOS lets only its own assistant listen in the background or on the Lock Screen."]
        if hands.heyOlo {
            lines.append("Keep listening on the Home Screen: while Olo is still running in the background, say Hey Olo or shake the phone. Olo says \"Go ahead, I'm listening.\", then reads the answer aloud. iOS shows the orange microphone dot the whole time and it uses more battery. It stops if you close Olo from the app switcher or iOS closes it.")
        }
        lines.append("Shake to ask: shake the phone while Olo is open. Olo says \"Go ahead, I'm listening.\" and Quick Ask takes your question. iOS does not let apps feel a shake when they are closed.")
        lines.append("Anywhere else: use the Ask Olo and Quick Ask shortcuts, set the Action Button to one of them, or add the Ask Olo control to Control Center or the Lock Screen (iOS 18).")
        return lines.joined(separator: "\n\n")
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
                    LabeledContent("Plan", value: model.planName)
                    if let e = model.entitlement, e.subscribed {
                        Text("\(e.messagesRemaining) of \(e.messageLimit) messages left this month.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(model.isSubscribed ? "Manage plan" : "See plans") { model.showPlans = true }
                    Button("Restore Purchases") { Task { await model.purchases.restore() } }.disabled(!model.signedIn)
                } header: { Text("Plan") } footer: {
                    Text(model.isSubscribed ? "A plan bought here, on the web or on the Mac works everywhere you sign in." : BillingText.freePlan + " A plan bought on the web or the Mac works here too.")
                }
                Section {
                    NavigationLink { ConnectorsView() } label: { Label("Mail and calendar", systemImage: "envelope.badge") }
                } header: { Text("Connectors") } footer: {
                    Text("Connect Google and Olo can read your Gmail and Calendar when a question calls for it. Read only.")
                }
                Section {
                    Toggle("Read answers aloud", isOn: $model.speakAnswers)
                    Picker("Listening in", selection: $voiceLanguage) {
                        Text("Automatic (\(VoiceLanguage.label(VoiceLanguage.resolve(preference: VoiceLanguage.auto, deviceLocale: Locale.current.identifier))))").tag(VoiceLanguage.auto)
                        ForEach(VoiceLanguage.options) { option in Text(option.label).tag(option.code) }
                    }
                    Button("Talk to Olo") { hands.openTalk() }
                    Button("Quick Ask") { hands.openQuickAsk() }
                } header: { Text("Voice") } footer: {
                    Text("Answers are read in Olo's own voice when you are signed in, and in this iPhone's voice otherwise. A speech recogniser has to be told which language to listen for; Olo answers in the language you speak. Audio is not recorded or kept.")
                }
                Section {
                    Toggle("Listen for Hey Olo", isOn: $hands.heyOlo)
                    if hands.heyOlo {
                        Toggle("Keep listening on the Home Screen", isOn: $hands.heyOloBackground)
                    }
                    if case .unavailable(let reason) = hands.wakeState, hands.heyOlo {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    }
                    Toggle("Shake to ask", isOn: $hands.shakeToAsk)
                    Toggle("Haptics", isOn: $hands.haptics)
                } header: { Text("Hands free") } footer: {
                    Text(handsFreeNote)
                }
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
                    Link("Apple's standard EULA", destination: Legal.eulaURL)
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
