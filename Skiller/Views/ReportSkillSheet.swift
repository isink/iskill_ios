import SwiftUI

enum ReportNotePolicy {
    static let maxLength = 2_000

    static func length(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    static func limited(_ value: String) -> String {
        var scalarCount = 0
        var result = ""
        for character in value {
            let nextCount = scalarCount + character.unicodeScalars.count
            guard nextCount <= maxLength else { break }
            result.append(character)
            scalarCount = nextCount
        }
        return result
    }

    static func payload(_ value: String) -> String? {
        let trimmed = limited(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ReportSkillSheet: View {
    let skill: Skill
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    enum Reason: String, CaseIterable, Hashable {
        case abuse, copyright, malicious, spam, other

        var label: LocalizedStringKey {
            switch self {
            case .abuse:     return "Inappropriate content (sexual / violence / discrimination)"
            case .copyright: return "Copyright infringement"
            case .malicious: return "Malicious code"
            case .spam:      return "Spam or low-quality content"
            case .other:     return "Other"
            }
        }
    }

    @State private var reason: Reason = .abuse
    @State private var note: String = ""
    @State private var submitting = false
    @State private var submitted = false
    @State private var error: String? = nil
    @AccessibilityFocusState private var feedbackFocus: FeedbackFocus?

    private enum FeedbackFocus: Hashable {
        case error
        case success
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    switch auth.state {
                    case .unknown:
                        ProgressView()
                            .tint(Color.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    case .signedOut:
                        signInRequiredCard
                    case .signedIn:
                        if submitted {
                            successCard
                        } else {
                            reasonList
                            noteField
                            if let msg = error {
                                Text(msg)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                    .accessibilityFocused($feedbackFocus, equals: .error)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Color.bg.ignoresSafeArea())
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .tint(Color.textSubtle)
                        .disabled(submitting)
                }
                if !submitted, case .signedIn = auth.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await submit() }
                        } label: {
                            if submitting {
                                ProgressView().tint(Color.brand)
                            } else {
                                Text("Submit").fontWeight(.semibold)
                            }
                        }
                        .tint(Color.brand)
                        .disabled(submitting)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(submitting)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("We'll manually review reports and remove content when needed.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var reasonList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Report Reason")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSubtle)
                .tracking(1.2)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(Reason.allCases.enumerated()), id: \.element) { idx, r in
                    if idx > 0 {
                        Rectangle().fill(Color.borderSubtle).frame(height: 1).padding(.leading, 14)
                    }
                    Button { reason = r } label: {
                        HStack {
                            Text(r.label)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if reason == r {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.brand)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == r ? .isSelected : [])
                }
            }
            .background(Color.bgCard)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Additional Notes (Optional)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                Spacer()
                Text("\(ReportNotePolicy.length(note))/\(ReportNotePolicy.maxLength)")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Color.textSubtle)
            TextEditor(text: Binding(
                get: { note },
                set: { note = ReportNotePolicy.limited($0) }
            ))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(10)
                .background(Color.bgCard)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.borderSubtle, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .font(.system(size: 14))
                .foregroundStyle(Color.textPrimary)
                .accessibilityLabel(Text("Additional Notes (Optional)"))
        }
    }

    private var successCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentGreen)
            Text("Submitted")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Thanks for the feedback. We'll review it as soon as possible.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSubtle)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .tint(Color.brand)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityFocused($feedbackFocus, equals: .success)
    }

    private var signInRequiredCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(Color.brand)
            Text("Sign in to submit a report")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Text("Open Profile and sign in before reporting a Skill.")
                .font(.subheadline)
                .foregroundStyle(Color.textSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor
    private func submit() async {
        guard !submitting else { return }
        guard case .signedIn = auth.state else {
            error = String(localized: "Sign in to submit a report")
            feedbackFocus = .error
            return
        }
        submitting = true
        defer { submitting = false }
        error = nil
        do {
            try await SkillsAPI.submitReport(
                skillId: skill.id,
                reason: reason.rawValue,
                note: ReportNotePolicy.payload(note)
            )
            submitted = true
            feedbackFocus = .success
        } catch let submissionError as SkillReportSubmissionError {
            self.error = message(for: submissionError)
            feedbackFocus = .error
        } catch {
            print("Report failed: \(error)")
            self.error = String(localized: "Submission failed, please try again later")
            feedbackFocus = .error
        }
    }

    private func message(for error: SkillReportSubmissionError) -> String {
        switch error {
        case .signInRequired:
            return String(localized: "Your session expired. Please sign in again.")
        case .duplicate:
            return String(localized: "You already submitted this report recently.")
        case .rateLimited:
            return String(localized: "Too many reports. Please try again in an hour.")
        case .invalidSkillId, .skillUnavailable:
            return String(localized: "This Skill is no longer available.")
        case .noteTooLong:
            return String(localized: "The report note is too long.")
        case .unavailable:
            return String(localized: "Submission failed, please try again later")
        }
    }
}
