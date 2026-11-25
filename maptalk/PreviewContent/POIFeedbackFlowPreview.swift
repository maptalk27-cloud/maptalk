#if DEBUG
import SwiftUI

enum POIFeedbackFlowDesign: String, CaseIterable {
    case header = "A 标题旁"
    case corner = "B 角落"
    case ribbon = "C 横滑"
    case inline = "D 原地展开"
    case floating = "E 轻浮层"
    case editor = "F 编辑页"
}

/// A local design study. Custom feelings never become place ratings or backend requests.
struct POIFeedbackFlowPreview: View {
    let placeName: String
    let iconSet: POIFeedbackIconSet
    let heading: POIFeedbackHeading
    let design: POIFeedbackFlowDesign
    let onSkip: () -> Void
    let onComplete: (String?, String) -> Void

    private enum Feeling: Equatable {
        case standard(RatedPOI.Endorsement)
        case custom(String)

        var emoji: String {
            switch self {
            case .standard(.hype): "😍"
            case .standard(.solid): "🙂"
            case .standard(.meh): "😐"
            case .standard(.questionable): "🙁"
            case .custom(let value): value
            }
        }

        var id: String {
            switch self {
            case .standard(let value): "standard-\(value.rawValue)"
            case .custom(let value): "custom-\(value)"
            }
        }
    }

    private let standardFeelings: [RatedPOI.Endorsement] = [.hype, .solid, .meh, .questionable]
    private let extraFeelings = ["🫠", "🥹", "😂", "😎", "🥱", "🤯",
                                 "🤤", "🤩", "🥲", "😌", "🙃", "🫶",
                                 "☕️", "🍜", "🌧️", "🌅", "✨", "💀"]

    @State private var selection: Feeling?
    @State private var comment: String
    @State private var isComposing: Bool
    @State private var showsMore = false
    @State private var didComplete = false
    @State private var expressionExpanded: Bool
    @State private var showsComposer = false
    @FocusState private var commentIsFocused: Bool

    init(placeName: String, iconSet: POIFeedbackIconSet, heading: POIFeedbackHeading,
         initialDraft: POIFeedbackDraft, design: POIFeedbackFlowDesign,
         onSkip: @escaping () -> Void, onComplete: @escaping (String?, String) -> Void) {
        self.placeName = placeName
        self.iconSet = iconSet
        self.heading = heading
        self.design = design
        self.onSkip = onSkip
        self.onComplete = onComplete
        _selection = State(initialValue: initialDraft.endorsement.map(Feeling.standard))
        _comment = State(initialValue: initialDraft.comment)
        _isComposing = State(initialValue: !initialDraft.comment.isEmpty)
        _expressionExpanded = State(initialValue: !initialDraft.comment.isEmpty)
    }

    private var trimmedComment: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        !didComplete && (selection != nil || !trimmedComment.isEmpty)
            && trimmedComment.utf16.count <= 1_000
    }
    private var selectedCustom: String? {
        guard case let .custom(value) = selection else { return nil }
        return value
    }
    private var isProgressive: Bool {
        design == .inline || design == .floating || design == .editor
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture { commentIsFocused = false }
                .accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    promptContent
                    if trimmedComment.utf16.count > 1_000 {
                        Text("Keep your thought under 1,000 characters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: 360)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.colorScheme, .light)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("poi-feedback-flow.preview")
        .onChange(of: commentIsFocused) { _, focused in
            if focused { isComposing = true }
        }
        .onChange(of: comment) { _, value in
            // Clearing text never silently turns an emoji back into an instant send.
            if !value.isEmpty { isComposing = true }
        }
        .onChange(of: design) { _, _ in
            showsMore = false
            showsComposer = false
        }
    }

    @ViewBuilder
    private var promptContent: some View {
        if design == .editor, expressionExpanded {
            HStack {
                Button {
                    commentIsFocused = false
                    expressionExpanded = false
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back, keep draft")
                placeTag
                Spacer(minLength: 0)
            }
            feelings
            compactFeelings
            commentInput
            HStack { Spacer(); sendButton }
        } else {
            VStack(spacing: 4) {
                header
                feelings
            }
            if !isProgressive {
                commentInput
            } else if design == .inline, expressionExpanded {
                compactFeelings
                commentInput
            } else {
                expressionEntry
            }
        }
    }

    private var expressionEntry: some View {
        HStack(spacing: 8) {
            Button {
                isComposing = true
                if design == .floating {
                    showsComposer = true
                } else {
                    expressionExpanded = true
                }
            } label: {
                Label(isComposing ? "Continue editing" : "Add a little more", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("poi-feedback-flow.add-expression")
            .popover(isPresented: $showsComposer, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("A little more").font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            commentIsFocused = false
                            showsComposer = false
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Close, keep draft")
                    }
                    compactFeelings
                    commentInput
                    if trimmedComment.utf16.count > 1_000 {
                        Text("Keep your thought under 1,000 characters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 280).padding(16)
                .presentationCompactAdaptation(.popover)
            }
            Spacer(minLength: 0)
            // Once an editor was entered, a visible send remains even after returning.
            if isComposing {
                if let selectedCustom { Text(selectedCustom).font(.system(size: 22)) }
                sendButton
            }
        }
    }

    private var compactFeelings: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                if design == .floating {
                    ForEach(standardFeelings, id: \.self) { value in
                        compactFeelingButton(.standard(value))
                    }
                }
                ForEach(extraFeelings, id: \.self) { value in
                    compactFeelingButton(.custom(value))
                }
            }
        }
        .scrollIndicators(.hidden).frame(height: 44)
        .accessibilityLabel("More feelings")
    }

    private func compactFeelingButton(_ feeling: Feeling) -> some View {
        Button { choose(feeling) } label: {
            Text(feeling.emoji).font(.system(size: 27))
                .frame(width: 44, height: 44)
                .background(selection == feeling ? Color.white.opacity(0.7) : .clear, in: Circle())
                .overlay {
                    if selection == feeling {
                        Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(didComplete)
        .accessibilityAddTraits(selection == feeling ? .isSelected : [])
    }

    private var sendButton: some View {
        Button("Send", action: complete)
            .font(.system(size: 14, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.plain).disabled(!canSend)
            .accessibilityIdentifier("poi-feedback-flow.send-expression")
    }

    private var header: some View {
        HStack(spacing: 4) {
            headingContent
            Spacer(minLength: 0)
            if design == .header { moreButton }
            Button {
                guard !didComplete else { return }
                didComplete = true
                commentIsFocused = false
                onSkip()
            } label: {
                Text("Skip").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("poi-feedback-flow.skip")
        }
    }

    @ViewBuilder
    private var headingContent: some View {
        switch heading {
        case .question:
            Text("How do you feel?").font(.system(size: 15, weight: .medium)).lineLimit(1)
        case .place:
            placeTag
        case .both:
            VStack(alignment: .leading, spacing: 5) {
                Text("How do you feel?").font(.system(size: 15, weight: .medium)).lineLimit(1)
                placeTag
            }
        }
    }

    private var placeTag: some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(placeName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.white.opacity(0.28), in: Capsule())
    }

    @ViewBuilder
    private var feelings: some View {
        if design == .ribbon {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(standardFeelings, id: \.self) { value in
                            feelingButton(.standard(value), width: 64)
                                .id(Feeling.standard(value).id)
                        }
                        ForEach(extraFeelings, id: \.self) { value in
                            feelingButton(.custom(value), width: 64)
                                .id(Feeling.custom(value).id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 72)
                .onAppear {
                    if let selection { proxy.scrollTo(selection.id, anchor: .center) }
                }
                .onChange(of: selection) { _, value in
                    if let value { proxy.scrollTo(value.id, anchor: .center) }
                }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(standardFeelings, id: \.self) { value in
                        feelingButton(.standard(value), width: 68)
                            .frame(maxWidth: .infinity)
                    }
                }
                if design == .corner {
                    HStack {
                        Spacer(minLength: 0)
                        moreButton
                    }
                }
            }
        }
    }

    private func feelingButton(_ feeling: Feeling, width: CGFloat) -> some View {
        Button { choose(feeling) } label: {
            Group {
                switch feeling {
                case .standard(let value):
                    POIFeedbackIcon(endorsement: value, set: iconSet, size: 46)
                case .custom(let value):
                    Text(value).font(.system(size: 46))
                }
            }
            .frame(width: width, height: 68)
            .background(selection == feeling ? Color.white.opacity(0.6) : .clear, in: Circle())
            .overlay {
                if selection == feeling {
                    Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1.25)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(didComplete)
        .accessibilityLabel(feeling.emoji)
        .accessibilityAddTraits(selection == feeling ? .isSelected : [])
        .accessibilityIdentifier("poi-feedback-flow.\(feeling.id)")
    }

    private var moreButton: some View {
        Button {
            commentIsFocused = false
            showsMore = true
        } label: {
            Group {
                if let selectedCustom {
                    Text(selectedCustom).font(.system(size: 28))
                } else {
                    Image(systemName: design == .corner ? "plus" : "face.smiling")
                        .font(.system(size: design == .corner ? 14 : 18, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.5))
                        .overlay(alignment: .bottomTrailing) {
                            if design == .header {
                                Image(systemName: "plus").font(.system(size: 8, weight: .semibold))
                                    .offset(x: 5, y: 4)
                            }
                        }
                }
            }
            .frame(width: 44, height: 44)
            .background(selectedCustom == nil ? Color.clear : .white.opacity(0.5), in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(didComplete)
        .accessibilityLabel(selectedCustom.map { "Feeling: \($0). Change feeling" } ?? "More feelings")
        .accessibilityIdentifier("poi-feedback-flow.more")
        .popover(isPresented: $showsMore, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your feeling").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 0), count: 6), spacing: 0) {
                    ForEach(extraFeelings, id: \.self) { value in
                        Button {
                            showsMore = false
                            choose(.custom(value))
                        } label: {
                            Text(value).font(.system(size: 28))
                                .frame(width: 44, height: 44)
                                .background(selectedCustom == value ? Color.primary.opacity(0.06) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var commentInput: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Leave a thought…", text: $comment, axis: .vertical)
                .font(.subheadline).lineLimit(1...3)
                .focused($commentIsFocused)
                .simultaneousGesture(TapGesture().onEnded { isComposing = true })
                .padding(.leading, 14).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("poi-feedback-flow.comment")
            if isComposing && !(design == .editor && expressionExpanded) {
                Button(action: complete) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(canSend ? Color.white : Color.primary.opacity(0.3))
                        .background(canSend ? Color.black.opacity(0.85) : .clear, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send feeling and thought")
                .accessibilityIdentifier("poi-feedback-flow.send")
            }
        }
        .background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 22))
    }

    private func choose(_ feeling: Feeling) {
        guard !didComplete else { return }
        selection = feeling
        if !isComposing {
            didComplete = true
            onComplete(feeling.emoji, trimmedComment)
        } else if isProgressive {
            if design == .floating {
                showsComposer = true
            } else {
                expressionExpanded = true
            }
        }
    }

    private func complete() {
        guard canSend else { return }
        didComplete = true
        commentIsFocused = false
        showsMore = false
        showsComposer = false
        onComplete(selection?.emoji, trimmedComment)
    }
}
#endif
