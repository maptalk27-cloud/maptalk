import MapKit
import SwiftUI

/// An isolated UI playground. Its save action never publishes or changes an archive.
/// Kept available in Release so a development-signed iPhone build can show it.
struct POIFeedbackPreview: View {
    let onClose: () -> Void

    private enum Fixture: String, CaseIterable, Identifiable {
        case empty, rating, comment, longPlace

        var id: Self { self }

        var title: String {
            switch self {
            case .empty: "Empty"
            case .rating: "Rating only"
            case .comment: "With comment"
            case .longPlace: "Long place name"
            }
        }

        var placeName: String {
            self == .longPlace
                ? "Pike Place Market · Waterfront Coffee & Bakery"
                : "Pike Place Market"
        }

        var draft: POIFeedbackDraft {
            switch self {
            case .empty, .longPlace:
                POIFeedbackDraft()
            case .rating:
                POIFeedbackDraft(endorsement: .hype)
            case .comment:
                POIFeedbackDraft(
                    endorsement: .solid,
                    comment: "Coffee, fresh flowers, and a slow walk by the water."
                )
            }
        }
    }

    @State private var style: POIFeedbackStyle = .clean
    @State private var iconSet: POIFeedbackIconSet = .emoji
    @State private var heading: POIFeedbackHeading = .place
    @State private var fixture: Fixture = .empty
    @State private var activeFixture: Fixture = .empty
    @State private var fixtureID = UUID()
    @State private var isNight = false
    @State private var isPresented = false
    @State private var replayRequest = 0
    @State private var confirmation: String?
#if DEBUG
    private enum FlowRound: String, CaseIterable {
        case current = "新方案", previous = "上一轮"
    }
    @State private var flowRound: FlowRound = .current
    @State private var flowDesign: POIFeedbackFlowDesign? = .inline

    private var flowOptions: [POIFeedbackFlowDesign] {
        flowRound == .current ? [.inline, .floating, .editor] : [.header, .corner, .ribbon]
    }

    private var roundSelection: Binding<FlowRound> {
        Binding(get: { flowRound }, set: { value in
            flowRound = value
            flowDesign = value == .current ? .inline : .header
        })
    }
#endif

    private static let placeCoordinate = CLLocationCoordinate2D(latitude: 47.6097, longitude: -122.3425)

    var body: some View {
        Map(initialPosition: .camera(MapCamera(
            centerCoordinate: Self.placeCoordinate,
            distance: 2_800,
            heading: -12,
            pitch: 40
        )), interactionModes: [.pan, .zoom, .rotate]) {
            Marker("Pike Place Market", coordinate: Self.placeCoordinate)
                .tint(.orange)
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
        .ignoresSafeArea(.container)
        .overlay {
            ZStack {
                if let confirmation, !isPresented {
                    confirmationCard(confirmation)
                        .transition(.opacity)
                }
                if isPresented {
                    feedbackPrompt
                    // Style and appearance changes deliberately keep identity,
                    // so they never clear the current rating or typed comment.
                    .id(fixtureID)
                    .transition(.opacity)
                }
            }
        }
        // Insert controls after the overlay so its outside-tap surface does not
        // intercept the preview controls or the close button.
        .safeAreaInset(edge: .top, spacing: 0) {
            controls
        }
        .preferredColorScheme(isNight ? .dark : .light)
        .tint(.primary)
        .accessibilityIdentifier("maptalk.poi-feedback-preview")
        .onChange(of: fixture) { _, _ in replayRequest += 1 }
        .task(id: replayRequest) {
            if isPresented {
                withAnimation(.easeOut(duration: 0.18)) { isPresented = false }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            activeFixture = fixture
            fixtureID = UUID()
            confirmation = nil
            withAnimation(.easeInOut(duration: 0.28)) { isPresented = true }
        }
    }

    @ViewBuilder
    private var feedbackPrompt: some View {
#if DEBUG
        if let flowDesign {
            POIFeedbackFlowPreview(
                placeName: activeFixture.placeName,
                iconSet: iconSet,
                heading: heading,
                initialDraft: activeFixture.draft,
                design: flowDesign,
                onSkip: { finishPreview("Skipped in this preview.") },
                onComplete: { emoji, comment in
                    let mood = emoji ?? "No feeling"
                    finishPreview("Preview only · \(mood)" + (comment.isEmpty ? "" : "\n\(comment)"))
                }
            )
        } else {
            originalFeedbackPrompt
        }
#else
        originalFeedbackPrompt
#endif
    }

    private var originalFeedbackPrompt: some View {
        MapTalkPOIFeedbackOverlay(
            placeName: activeFixture.placeName,
            audience: .livePublic,
            style: style,
            iconSet: iconSet,
            heading: heading,
            initialDraft: activeFixture.draft,
            onSkip: { finishPreview("Skipped in this preview.") },
            onSave: { _, _, _ in finishPreview("Saved in this preview only.") }
        )
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("POI · Design study")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
#if DEBUG
                Picker("预览轮次", selection: roundSelection) {
                    ForEach(FlowRound.allCases, id: \.self) { round in
                        Text(round.rawValue).tag(round)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
#endif
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close UI preview")
            }

#if DEBUG
            Picker("Flow design", selection: $flowDesign) {
                if flowRound == .previous {
                    Text("Original").tag(POIFeedbackFlowDesign?.none)
                }
                ForEach(flowOptions, id: \.self) { option in
                    Text(option.rawValue).tag(Optional(option))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("poi-feedback-preview.flow-design")
            if flowDesign == nil { originalStylePicker }
#else
            originalStylePicker
#endif

            Picker("Rating icons", selection: $iconSet) {
                ForEach(POIFeedbackIconSet.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("maptalk.poi-feedback-preview.icons")

            Picker("Feedback heading", selection: $heading) {
                ForEach(POIFeedbackHeading.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("maptalk.poi-feedback-preview.heading")

            HStack(spacing: 16) {
                Menu {
                    Picker("Preview fixture", selection: $fixture) {
                        ForEach(Fixture.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label(fixture.title, systemImage: "rectangle.stack")
                        .lineLimit(1)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Preview fixture: \(fixture.title)")

                Spacer(minLength: 0)

                Button {
                    isNight.toggle()
                } label: {
                    Image(systemName: isNight ? "moon.fill" : "sun.max.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isNight ? "Switch to day" : "Switch to night")

                Button {
                    replayRequest += 1
                } label: {
                    Label("Replay", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .accessibilityHint("Resets the selected fixture and replays the fade-in")
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private var originalStylePicker: some View {
        Picker("Feedback style", selection: $style) {
            ForEach(POIFeedbackStyle.reviewStyles) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("maptalk.poi-feedback-preview.style")
    }

    private func confirmationCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            Label(text, systemImage: "checkmark.circle")
                .font(.subheadline.weight(.medium))
            Button("Replay feedback") { replayRequest += 1 }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(24)
    }

    private func finishPreview(_ message: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isPresented = false
            confirmation = message
        }
    }
}

#Preview("POI feedback · style playground") {
    POIFeedbackPreview(onClose: {})
}
