import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browser: MemoryBrowser
    @State private var ruleDraft = ""
    @State private var ruleIsRegex = false

    private var retention: Binding<Int> {
        Binding(
            get: { browser.storage.rawRetentionDays ?? -1 },
            set: { browser.setRawRetentionDays($0 == -1 ? nil : $0) }
        )
    }

    private var semanticSearch: Binding<Bool> {
        Binding(
            get: { browser.storage.semanticSearchEnabled },
            set: { browser.setSemanticSearchEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep detailed activity for", selection: retention) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(-1)
                }

                Toggle("Search meaning as well as words", isOn: semanticSearch)

                LabeledContent("On disk") {
                    Text(ByteCountFormatter.string(fromByteCount: browser.storage.databaseBytes, countStyle: .file))
                        .monospacedDigit()
                }

                LabeledContent("Stored") {
                    Text("\(browser.health.taskCount) tasks · \(browser.health.evidenceCount) pieces of context")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Detailed activity expires on this schedule. The tasks themselves and the context saved with them stay, so older work is still searchable.")
            }

            Section {
                HStack {
                    TextField(ruleIsRegex ? "Pattern to redact" : "Text to redact", text: $ruleDraft)
                        .onSubmit(addRule)
                    Toggle("Pattern", isOn: $ruleIsRegex)
                        .toggleStyle(.checkbox)
                        .help("Treat the text as a regular expression")
                    Button("Add", action: addRule)
                        .disabled(ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(model.customRedactionLiterals, id: \.self) { rule in
                    RedactionRuleRow(rule: rule, kind: "Text") {
                        model.removeCustomRedactionRule(rule, regex: false)
                    }
                }
                ForEach(model.customRedactionRegexes, id: \.self) { rule in
                    RedactionRuleRow(rule: rule, kind: "Pattern") {
                        model.removeCustomRedactionRule(rule, regex: true)
                    }
                }
            } header: {
                Text("Redaction")
            } footer: {
                Text("Passwords, tokens, keys, and credentials in URLs are always removed and cannot be turned off. Add your own rules here — up to \(CapturePrivacy.maximumCustomRules).")
            }

            Section {
                Text("Your memory never leaves this Mac. It is stored in your user library, readable only by your macOS account.")
                Text("It is not separately encrypted yet, so it is only as protected as your Mac is. Turn on FileVault for full-disk protection, and lock your Mac when you step away.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("How your data is protected")
            }
        }
        .formStyle(.grouped)
        .onAppear { browser.refresh() }
    }

    private func addRule() {
        if model.addCustomRedactionRule(ruleDraft, regex: ruleIsRegex) {
            ruleDraft = ""
        }
    }
}

private struct RedactionRuleRow: View {
    let rule: String
    let kind: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Chip(text: kind)
            Text(rule)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
            .accessibilityLabel("Remove rule \(rule)")
        }
    }
}
