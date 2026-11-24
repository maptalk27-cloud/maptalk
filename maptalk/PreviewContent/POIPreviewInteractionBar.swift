#if DEBUG
import Combine
import SwiftUI

/// Shared by the footer/header actions and a stable, controller-backed sheet host.
@MainActor
final class POIPreviewInteractionPresentation: ObservableObject {
    struct Context: Identifiable {
        enum Kind: Equatable { case comment, reply, share }
        let id = UUID()
        let media: RatedPOI.Media
        let authorID: UUID
        let authorName: String
        let placeName: String
        let kind: Kind
    }

    @Published var context: Context?
    @Published var commentDraft = ""
    @Published var commentSubmitted = false
    @Published var isReplyVisible = false
    var isPresented: Bool { context != nil }
    var pausesPlayback: Bool {
        context?.kind == .reply ? isReplyVisible : isPresented
    }

    func open(_ kind: Context.Kind, media: RatedPOI.Media,
              authorID: UUID, authorName: String, placeName: String, existingComment: String) {
        commentDraft = existingComment
        commentSubmitted = false
        // Keep the tapped media, even if the parent later changes selection.
        context = Context(media: media, authorID: authorID, authorName: authorName,
                          placeName: placeName, kind: kind)
    }
}

/// Local-only interaction styling for the POI design playground.
struct POIPreviewInteractionBar: View {
    let media: RatedPOI.Media
    let authorID: UUID
    let authorName: String
    let placeName: String
    @Binding var likedMediaIDs: Set<UUID>
    @Binding var localComments: [UUID: String]
    @Binding var localReplies: [UUID: String]
    var usesPrivateReply = false
    var compact = false
    var showsShare = true
    var iconSize: CGFloat = 24
    @ObservedObject var presentation: POIPreviewInteractionPresentation

    private var isLiked: Bool { likedMediaIDs.contains(media.id) }

    var body: some View {
        HStack(spacing: compact ? 0 : 10) {
            Button { openSheet(usesPrivateReply ? .reply : .comment) } label: {
                if compact || usesPrivateReply {
                    Image(systemName: usesPrivateReply ? "bubble.left" : "bubble.right")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                } else {
                    Text("评论…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 17)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(.black.opacity(0.13), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                        .contentShape(Capsule())
                }
            }
            .accessibilityLabel(usesPrivateReply
                ? "针对\(poiPreviewMediaLabel(media))发消息"
                : "评论\(poiPreviewMediaLabel(media))")
            .accessibilityIdentifier(usesPrivateReply ? "poi.preview.reply" : "poi.preview.comment")

            Button {
                if isLiked {
                    likedMediaIDs.remove(media.id)
                } else {
                    likedMediaIDs.insert(media.id)
                }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: iconSize + 1, weight: .regular))
                    .foregroundStyle(isLiked ? Color.red : Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(isLiked ? "取消喜欢" : "喜欢")\(poiPreviewMediaLabel(media))")
            .accessibilityHint("仅本地预览")
            .accessibilityIdentifier("poi.preview.like")

            if showsShare {
                Button { openSheet(.share) } label: {
                    Image(systemName: "paperplane")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("分享\(poiPreviewMediaLabel(media))")
                .accessibilityIdentifier("poi.preview.share")
            }
        }
        .buttonStyle(.plain)
    }

    private func openSheet(_ kind: POIPreviewInteractionPresentation.Context.Kind) {
        let existingText = kind == .reply ? localReplies[media.id] : localComments[media.id]
        presentation.open(kind, media: media, authorID: authorID,
                          authorName: authorName, placeName: placeName,
                          existingComment: existingText ?? "")
    }
}

/// Attach to stable preview card content, not the floating UIKit accessory.
struct POIPreviewInteractionSheet: ViewModifier {
    @ObservedObject var presentation: POIPreviewInteractionPresentation
    @Binding var localComments: [UUID: String]
    @Binding var localReplies: [UUID: String]
    @FocusState private var isReplyFocused: Bool

    func body(content: Content) -> some View {
        content.sheet(item: $presentation.context, onDismiss: {
            isReplyFocused = false
            presentation.isReplyVisible = false
            presentation.context = nil
        }) { context in
            Group {
                if context.kind == .reply {
                    privateReplyContent(context)
                        .onAppear { presentation.isReplyVisible = true }
                        .onDisappear {
                            isReplyFocused = false
                            presentation.isReplyVisible = false
                        }
                } else {
                    sheetContent(context)
                }
            }
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
                .environment(\.friendStoryChildPresentationChanged, nil)
        }
    }

    private func privateReplyContent(_ context: POIPreviewInteractionPresentation.Context) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                replyThumbnail(context.media)
                VStack(alignment: .leading, spacing: 5) {
                    Text("发消息给 \(context.authorName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(poiPreviewMediaLabel(context.media))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("poi.preview.reply.target")
            .accessibilityValue("\(context.authorID.uuidString):\(context.media.id.uuidString)")

            if presentation.commentSubmitted {
                Label("预览消息已记录", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.mint)
                Text(localReplies[context.media.id] ?? "")
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                HStack(spacing: 12) {
                    TextField("发消息…", text: $presentation.commentDraft, axis: .vertical)
                        .focused($isReplyFocused)
                        .lineLimit(1...3)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    Button("发送") {
                        isReplyFocused = false
                        // Use the captured media, never the parent's later selection.
                        localReplies[context.media.id] = presentation.commentDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        presentation.commentSubmitted = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(presentation.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("仅本地预览，不会发送给对方。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func replyThumbnail(_ media: RatedPOI.Media) -> some View {
        let url: URL?
        let isVideo: Bool
        switch media.kind {
        case let .photo(photo): url = photo; isVideo = false
        case let .video(_, poster): url = poster; isVideo = true
        }
        return MapImage(url: url, thumbnailSize: CGSize(width: 48, height: 60)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.08)
                .overlay(Image(systemName: isVideo ? "video" : "photo").foregroundStyle(.secondary))
        }
        .frame(width: 48, height: 60)
        .clipped()
        .overlay {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func sheetContent(_ context: POIPreviewInteractionPresentation.Context) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(context.kind == .comment ? "评论" : "分享")\(poiPreviewMediaLabel(context.media))")
                .font(.headline)
            Text("\(context.authorName) · \(context.placeName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if context.kind == .comment {
                if presentation.commentSubmitted {
                    Label("预览评论已记录", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                    Text(localComments[context.media.id] ?? "")
                        .font(.subheadline)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 12) {
                        TextField("写下你的评论…", text: $presentation.commentDraft, axis: .vertical)
                            .lineLimit(1...3)
                            .padding(12)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        Button("发送") {
                            localComments[context.media.id] = presentation.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            presentation.commentSubmitted = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(presentation.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("仅本地预览，不会发送给对方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("分享样式预览", systemImage: "paperplane")
                    .font(.title3)
                Text("这里仅展示分享入口，不会发送消息或链接。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("完成") { presentation.context = nil }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private func poiPreviewMediaLabel(_ media: RatedPOI.Media) -> String {
    switch media.kind {
    case .photo: return "这张照片"
    case .video: return "这段视频"
    }
}
#endif
