import SwiftUI

/// This is a follow-up to a saved visit, never another publishing step.
struct POIFeedbackDraft {
    var endorsement: RatedPOI.Endorsement?
    var comment = ""

    var trimmedComment: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasContent: Bool { endorsement != nil || !trimmedComment.isEmpty }
    var isValid: Bool { hasContent && trimmedComment.utf16.count <= 1_000 }

    mutating func toggle(_ value: RatedPOI.Endorsement) {
        endorsement = endorsement == value ? nil : value
    }
}

enum POIFeedbackStyle: String, CaseIterable, Identifiable {
    case glass, clean, lifted, compact, feeling

    static let reviewStyles: [Self] = [.clean, .lifted, .compact, .feeling]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Original"
        case .clean: "A · Quiet"
        case .lifted: "B · Lift"
        case .compact: "C · Slim"
        case .feeling: "D · Feel"
        }
    }
}

enum POIFeedbackHeading: String, CaseIterable, Identifiable {
    case question, place, both

    var id: Self { self }
    var title: String {
        switch self {
        case .question: "Question"
        case .place: "Place"
        case .both: "Both"
        }
    }
}

struct MapTalkPOIFeedbackOverlay: View {
    let placeName: String
    let audience: MapPublishAudience
    let style: POIFeedbackStyle
    let iconSet: POIFeedbackIconSet
    let heading: POIFeedbackHeading
    let onSkip: () -> Void
    // Both the form and its store are MainActor-isolated. Keep that isolation
    // on the stored callback too, rather than erasing it at the async boundary.
    let onSave: @MainActor (RatedPOI.Endorsement?, String) async throws -> Void

    @State private var draft = POIFeedbackDraft()
    @State private var isSaving = false
    @State private var saveIssue: String?
    @FocusState private var isCommentFocused: Bool

    init(placeName: String, audience: MapPublishAudience,
         style: POIFeedbackStyle = .clean, iconSet: POIFeedbackIconSet = .emoji,
         heading: POIFeedbackHeading = .place,
         initialDraft: POIFeedbackDraft = .init(),
         onSkip: @escaping () -> Void,
         onSave: @escaping @MainActor (RatedPOI.Endorsement?, String) async throws -> Void) {
        self.placeName = placeName
        self.audience = audience
        self.style = style
        self.iconSet = iconSet
        self.heading = heading
        self.onSkip = onSkip
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    private let choices: [(RatedPOI.Endorsement, String, String)] = [
        (.hype, "😍", "Loved it"),
        (.solid, "🙂", "Liked it"),
        (.meh, "😐", "Okay"),
        (.questionable, "🙁", "Not for me")
    ]

    var body: some View {
        ZStack {
            // Catch taps behind the prompt without darkening the whole map.
            // Tapping outside only puts the keyboard away; Skip is explicit.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { isCommentFocused = false }
                .accessibilityHidden(true)

            ScrollView {
                prompt
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("maptalk.poi-feedback")
    }

    @ViewBuilder
    private var prompt: some View {
        switch style {
        case .glass:
            originalPrompt
        case .clean:
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    quietHeader
                    largeFeelings
                }
                commentInput
                issues
            }
            .padding(18)
            .frame(maxWidth: 360)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        case .feeling:
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 4) {
                    quietHeader
                    largeFeelings
                }
                commentInput
                issues
            }
            .padding(18)
            .frame(maxWidth: 360)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        case .lifted:
            VStack(spacing: 6) {
                // Keep the entire controls inside the layout/hit area, while
                // the glass begins halfway down them. No clipped tap targets.
                largeFeelings.padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 10) {
                    quietHeader
                    commentInput
                    issues
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: 360)
            .background {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
                    .padding(.top, 38)
            }
        case .compact:
            VStack(alignment: .leading, spacing: 8) {
                if heading != .question {
                    headingContent
                        .padding(.horizontal, 6)
                }
                HStack(spacing: 0) {
                    largeFeelings
                    closeButton
                }
                commentInput
                issues
            }
            .padding(12)
            .frame(maxWidth: 360)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
            .accessibilityLabel(placeName)
        }
    }

    // Retained original treatment for comparison.
    private var originalPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            feelingPicker
            commentInput
            footer
        }
        .padding(20)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var quietHeader: some View {
        HStack(spacing: 7) {
            headingContent
            Spacer(minLength: 0)
            closeButton
        }
    }

    @ViewBuilder
    private var headingContent: some View {
        switch heading {
        case .question:
            Text("How do you feel?")
                .font(.system(size: style == .feeling ? 20 : 15, weight: .medium))
                .lineLimit(1)
        case .place:
            placeTag
        case .both:
            VStack(alignment: .leading, spacing: 5) {
                Text("How do you feel?")
                    .font(.system(size: style == .feeling ? 20 : 15, weight: .medium))
                    .lineLimit(1)
                placeTag
            }
        }
    }

    private var placeTag: some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(placeName)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.28), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Place: \(placeName)")
        .accessibilityIdentifier("maptalk.poi-feedback.place")
    }

    private var closeButton: some View {
        Button(action: onSkip) {
            Text("Skip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel("Skip feedback")
        .accessibilityIdentifier("maptalk.poi-feedback.skip")
    }

    private var largeFeelings: some View {
        HStack(spacing: style == .compact ? 0 : 6) {
            ForEach(choices, id: \.0) { choice in
                let selected = draft.endorsement == choice.0
                Button {
                    draft.toggle(choice.0)
                } label: {
                    POIFeedbackIcon(endorsement: choice.0, set: iconSet,
                        size: style == .feeling ? 50 : (style == .lifted ? 49 : (style == .compact ? 39 : 46)))
                        .frame(width: style == .compact ? 56 : 68,
                               height: style == .compact ? 56 : 68)
                        .background {
                            if style == .lifted {
                                Color.clear.glassEffect(.regular, in: Circle())
                            }
                        }
                        .background(selected ? Color.white.opacity(0.65) : .clear, in: Circle())
                        .overlay {
                            if selected {
                                Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 1.5)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: style == .lifted ? 80 : 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel(choice.2)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("maptalk.poi-feedback.\(choice.0.rawValue)")
            }
        }
        .accessibilityLabel("How was it?")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Check-in saved", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(placeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Skip", action: onSkip)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityIdentifier("maptalk.poi-feedback.skip")
        }
    }

    private var feelingPicker: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.0) { choice in
                feeling(choice)
            }
        }
        .accessibilityLabel("How was it?")
    }

    private var commentInput: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Leave a thought…", text: $draft.comment, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...3)
                .focused($isCommentFocused)
                .padding(.leading, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isSaving)
                .accessibilityLabel("Add a comment (optional)")
                .accessibilityIdentifier("maptalk.poi-feedback.comment")

            Button(action: save) {
                ZStack {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(width: 32, height: 32)
                .foregroundStyle(draft.isValid ? Color.white : Color.primary.opacity(0.3))
                .background(draft.isValid ? Color.black.opacity(0.85) : Color.clear, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!draft.isValid || isSaving)
            .accessibilityLabel("Save")
            .accessibilityIdentifier("maptalk.poi-feedback.save")
        }
        .background {
            RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.3))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(audience == .privateMyMap ? "Only you can see this." : "Shared with your check-in.")
                .font(.caption2)
            issues
        }
        .foregroundStyle(.secondary)
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.trimmedComment.utf16.count > 1_000 {
                Text("Keep your comment under 1,000 characters.")
                    .font(.caption)
                    .accessibilityIdentifier("maptalk.poi-feedback.validation")
            }
            if let saveIssue {
                Text(saveIssue)
                    .font(.caption)
                    .accessibilityIdentifier("maptalk.poi-feedback.error")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func feeling(_ choice: (RatedPOI.Endorsement, String, String)) -> some View {
        let selected = draft.endorsement == choice.0
        return Button {
            draft.toggle(choice.0)
        } label: {
            VStack(spacing: 6) {
                Text(choice.1)
                    .font(.system(size: 28))
                    .frame(width: 52, height: 34)
                Text(choice.2)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? Color.white.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(choice.2)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("maptalk.poi-feedback.\(choice.0.rawValue)")
    }

    private func save() {
        let value = draft
        guard value.isValid, !isSaving else { return }
        let endorsement = value.endorsement
        let comment = value.trimmedComment
        let saveFeedback = onSave
        isSaving = true
        isCommentFocused = false
        saveIssue = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await saveFeedback(endorsement, comment)
            } catch {
                // Publishing already succeeded. Keep just this optional draft;
                // retrying here must never publish the visit a second time.
                saveIssue = "Your check-in is saved. Couldn't save this feedback; try again or skip."
            }
        }
    }
}
