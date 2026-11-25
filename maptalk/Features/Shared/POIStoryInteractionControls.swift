import SwiftUI

/// Actions have explicit targets: save the place, like an exact attachment,
/// and privately reply to its author. No action mutates the browsing cursor.
struct POIStorySaveButton: View {
    let place: RatedPOI
    @Environment(\.appEnv) private var environment
    @State private var demoSaved = false

    var body: some View {
        if let store = environment.backend {
            ConnectedPOISaveButton(store: store, placeID: place.id)
        } else {
            Button { demoSaved.toggle() } label: { saveIcon(demoSaved) }
                .buttonStyle(.plain)
                .accessibilityLabel(demoSaved ? "Unsave place" : "Save place")
        }
    }

    private func saveIcon(_ saved: Bool) -> some View {
        Image(systemName: saved ? "bookmark.fill" : "bookmark")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct ConnectedPOISaveButton: View {
    @ObservedObject var store: BackendStore
    let placeID: UUID
    @State private var isSaving = false
    @State private var issue: String?

    private var saved: Bool {
        store.savedPlaceStates[store.canonicalPlaceID(for: placeID) ?? placeID] ?? false
    }

    var body: some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                defer { isSaving = false }
                do { try await store.setPlaceSaved(placeID, saved: !saved) }
                catch { issue = poiInteractionError(error) }
            }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white)
                .opacity(isSaving ? 0.5 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(saved ? "Unsave place" : "Save place")
        .accessibilityIdentifier("poi.save.\(placeID)")
        .task(id: placeID) {
            do { try await store.loadPlaceSaved(placeID) }
            catch is CancellationError { }
            catch { /* Reads never imply a successful write; tapping can retry. */ }
        }
        .alert("Couldn't save", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK", role: .cancel) { issue = nil }
        } message: { Text(issue ?? "") }
    }
}

struct POIStoryMediaActions: View {
    let visit: RatedPOI.CheckIn
    let mediaID: UUID?
    @Environment(\.appEnv) private var environment
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @State private var replyUser: User?
    @State private var presentationID = UUID()
    @State private var demoLiked = false

    var body: some View {
        HStack(spacing: 4) {
            if visit.userId != environment.currentUser.id,
               let author = environment.user(for: visit.userId) {
                Button { replyUser = author } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Message \(author.handle)")
            }
            if let mediaID {
                if let store = environment.backend {
                    ConnectedPOIMediaLike(store: store, key: .init(memoryID: visit.id, mediaID: mediaID))
                } else {
                    Button { demoLiked.toggle() } label: {
                        Image(systemName: demoLiked ? "heart.fill" : "heart")
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(demoLiked ? "Unlike photo or video" : "Like photo or video")
                }
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .sheet(item: $replyUser) { user in
            NavigationStack {
                ChatThreadView(user: user, replyContext: mediaID.map {
                    BackendMessageContext(memoryId: visit.id, mediaId: $0)
                })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { replyUser = nil }
                    }
                }
            }
            .environment(\.colorScheme, .light)
        }
        .onChange(of: replyUser != nil) { _, presented in
            childPresentationChanged?(presentationID, presented)
        }
        .onDisappear { childPresentationChanged?(presentationID, false) }
    }
}

private struct ConnectedPOIMediaLike: View {
    @ObservedObject var store: BackendStore
    let key: BackendMediaLikeKey
    @State private var isSaving = false
    @State private var issue: String?
    private var liked: Bool { store.mediaLikes[key]?.liked ?? false }

    var body: some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                defer { isSaving = false }
                do { try await store.setMediaLiked(key, liked: !liked) }
                catch { issue = poiInteractionError(error) }
            }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .opacity(isSaving ? 0.5 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(liked ? "Unlike photo or video" : "Like photo or video")
        .accessibilityIdentifier("poi.media.like.\(key.mediaID)")
        .task(id: key) {
            do { try await store.loadMediaLike(key) }
            catch is CancellationError { }
            catch { }
        }
        .alert("Couldn't update like", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK", role: .cancel) { issue = nil }
        } message: { Text(issue ?? "") }
    }
}

/// Personal browsing has no floating author bar, but must not lose the exact
/// visit's expression. Keep it subordinate to the media, not a new panel.
struct POIVisitExpression: View {
    let visit: RatedPOI.CheckIn
    let place: RatedPOI
    @Environment(\.appEnv) private var environment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let feeling = visit.endorsement {
                POIFeedbackIcon(endorsement: feeling, set: .emoji, size: 26)
                    .fixedSize()
                    .accessibilityLabel(feeling.rawValue)
            } else if let emoji = visit.customEmoji {
                POICustomFeelingIcon(emoji: emoji, size: 26)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let comment = visit.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
                    Text(comment).font(.system(size: 13)).lineLimit(2)
                }
                if let store = environment.backend {
                    ConnectedPOIVisitCount(store: store, placeID: place.id, authorID: visit.userId)
                } else if let person = place.checkInPeople().first(where: { $0.userID == visit.userId }) {
                    Text(person.visitDayCount == 1 ? "1 visit" : "\(person.visitDayCount) visits")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .allowsHitTesting(false)
    }
}

private struct ConnectedPOIVisitCount: View {
    @ObservedObject var store: BackendStore
    let placeID: UUID
    let authorID: UUID
    var body: some View {
        Group {
            if let count = store.visiblePOIVisitDayCount(placeID: placeID, authorID: authorID) {
                Text(count == 1 ? "1 visit" : "\(count) visits")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .task(id: "\(placeID):\(authorID):\(store.poiVisitCountRevision)") {
            await store.ensurePOIVisitDayCounts(placeID: placeID, ownerIDs: [authorID])
        }
    }
}

func poiInteractionError(_ error: Error) -> String {
    if case let BackendClientError.http(status, _, code) = error,
       status == 404 && (code == "not_found" || code == nil) {
        return "This action isn't available on the server yet, or the original memory is no longer shared. Nothing was sent or saved."
    }
    return error.localizedDescription
}
