#if DEBUG
import SwiftUI

/// Isolated visual fixtures: no account, feed mutations, or network writes.
struct PostLayoutPreview: View {
    private enum SinglePhotoRatio: String, CaseIterable {
        case original = "原图", square = "1:1", landscape = "4:3", wide = "3:2"
        case portrait = "3:4", tall = "9:16", longImage = "1:3", panorama = "4:1"

        var pixels: (width: Int, height: Int)? {
            switch self {
            case .original: nil
            case .square: (840, 840)
            case .landscape: (960, 720)
            case .wide: (1080, 720)
            case .portrait: (720, 960)
            case .tall: (540, 960)
            case .longImage: (400, 1200)
            case .panorama: (1200, 300)
            }
        }
    }

    @State private var count = 9
    @State private var captionLineCount = 2
    @State private var singlePhotoRatio: SinglePhotoRatio = .original
    @State private var design: PostSheetDesign = .refined
    @State private var detent: PresentationDetent = .fraction(0.48)
    @State private var isPresented = false
    @State private var includesBubble = true
    @State private var environment = AppEnvironment.bootstrap()
    private let compactDetent: PresentationDetent = .fraction(0.48)

    private var fixture: RealPost {
        var post = PreviewData.sampleReals.first { $0.attachments.count == 9 && $0.capsuleId != nil }!
        // Keep a broken legacy sample URL out of the visual comparison. This
        // changes only the isolated fixture, never an actual post or upload.
        if let beach = PreviewData.sampleReals.first(where: { $0.attachments.count == 1 })?.attachments.first {
            post.attachments[2] = .init(id: post.attachments[2].id, kind: beach.kind)
        }
        post.attachments = Array(post.attachments.prefix(count))
        if count == 1, let pixels = singlePhotoRatio.pixels,
           case let .photo(source) = post.attachments[0].kind,
           var url = URLComponents(url: source, resolvingAgainstBaseURL: false) {
            // Real aspect-ratio fixtures from the existing public sample photo,
            // so both the card and its lightbox see the same complete source.
            var query = (url.queryItems ?? []).filter { !["w", "h", "fit"].contains($0.name) }
            query += [URLQueryItem(name: "w", value: String(pixels.width)),
                      URLQueryItem(name: "h", value: String(pixels.height)),
                      URLQueryItem(name: "fit", value: "crop")]
            url.queryItems = query
            if let sampleURL = url.url { post.attachments[0].kind = .photo(sampleURL) }
        }
        let captionLines = [
            "第一站，海边的清晨。",
            "沿着街角慢慢走。",
            "一杯咖啡，一点阳光。",
            "路过喜欢的小店。",
            "把普通的瞬间留下。",
            "下一站，再出发。",
            "这是第七行正文。",
            "这是第八行正文。"
        ] + (9...24).map { "这是第\($0)行正文。" }
        post.message = captionLines.prefix(captionLineCount).joined(separator: "\n")
        if !includesBubble { post.capsuleId = nil }
        return post
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("配色").font(.footnote)
                Spacer()
                PostCardPaletteSwitch()
            }
            Picker("Post design", selection: $design) {
                Text("原版").tag(PostSheetDesign.original)
                Text("原版改进").tag(PostSheetDesign.refined)
                Text("整页").tag(PostSheetDesign.editorial)
                Text("轻笔记").tag(PostSheetDesign.notebook)
            }
            .pickerStyle(.segmented)
            optionRow("照片", values: Array(0...9), selection: $count)
            if count == 1 { singlePhotoRatioRow }
            optionRow("正文", values: [0, 1, 2, 3, 4, 5, 6, 8], selection: $captionLineCount)
            optionRow("长文", values: [12, 16, 24], selection: $captionLineCount)
            HStack(spacing: 28) {
                Toggle("气泡", isOn: $includesBubble)
                Toggle("展开卡片", isOn: Binding(
                    get: { detent == .large },
                    set: { detent = $0 ? .large : compactDetent }
                ))
            }
            .font(.footnote)
            .tint(.black)

            if !isPresented {
                Button("显示预览") { isPresented = true }
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .appEnvironment(environment)
        .onAppear { isPresented = true }
        .sheet(isPresented: $isPresented) {
            // Use the same native container as Posts. A fixed-height rounded
            // rectangle inside a VStack leaves a fake gray safe-area strip.
            ExperienceDetailView(
                mode: .real(fixture, PreviewData.currentUser),
                isExpanded: detent == .large,
                usesClassicPostPreview: true,
                onCollapsedTap: { detent = .large },
                onJourneyAvatarStackTap: { _ in },
                journeyProvider: { PreviewData.journey(for: $0) },
                userProvider: { id in PreviewData.sampleFriends.first { $0.id == id } }
            )
            .environment(\.postSheetDesign, design)
            // Each design owns its compact geometry; never reuse measurements
            // from the other layout when comparing or expanding the sheet.
            .id(design)
            .mapExperienceSheetChrome(compactDetent: compactDetent, selection: $detent)
            .modifier(PostCardPaletteScope())
            .appEnvironment(environment)
        }
    }

    private var singlePhotoRatioRow: some View {
        HStack(spacing: 8) {
            Text("比例").font(.footnote).frame(width: 28, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(SinglePhotoRatio.allCases, id: \.self) { ratio in
                    Button(ratio.rawValue) { singlePhotoRatio = ratio }
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(singlePhotoRatio == ratio ? .white : .primary)
                        .background(singlePhotoRatio == ratio ? Color.black : Color.white,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .buttonStyle(.plain)
                        .accessibilityLabel("Single photo aspect ratio \(ratio.rawValue)")
                }
            }
        }
    }

    private func optionRow(_ title: String, values: [Int], selection: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote)
                .frame(width: 28, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(values, id: \.self) { value in
                    Button("\(value)") { selection.wrappedValue = value }
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(selection.wrappedValue == value ? .white : .primary)
                        .background(selection.wrappedValue == value ? Color.black : Color.white,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(value)")
                }
            }
        }
    }
}

#Preview("Post · 0–9 photos") {
    PostLayoutPreview()
}
#endif
