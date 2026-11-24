import MapKit
import SwiftUI
import UIKit

/// A static cover of the person's Post history, not a video player or a new
/// media downloader. Selection belongs to the picker; this view only styles it.
final class PostLocationThumbnailAnnotationView: MKAnnotationView {
    var onTap: (() -> Void)?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let tip = UIView()
    private let tapButton = UIButton(type: .custom)
    private let imageHost: UIView & UIContentView
    private var thumbnailIdentity: PostLocationMarkerThumbnailIdentity?
    private static let mint = UIColor(red: 0.17, green: 0.49, blue: 0.38, alpha: 1)

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        imageHost = UIHostingConfiguration {
            PostLocationMarkerContent(identity: nil)
        }.margins(.all, 0).makeContentView()
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear
        isEnabled = true
        isUserInteractionEnabled = true
        canShowCallout = false
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        selectedZPriority = .max
        isAccessibilityElement = true

        tip.backgroundColor = .white
        tip.bounds.size = .init(width: 6, height: 6)
        tip.transform = CGAffineTransform(rotationAngle: .pi / 4)
        tip.isUserInteractionEnabled = false
        addSubview(tip)

        card.backgroundColor = .white
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.14
        card.layer.shadowOffset = .init(width: 0, height: 2)
        card.layer.shadowRadius = 4
        card.layer.borderColor = Self.mint.cgColor
        card.isUserInteractionEnabled = false
        addSubview(card)

        imageHost.backgroundColor = .clear
        imageHost.isUserInteractionEnabled = false
        imageHost.layer.cornerRadius = 10
        imageHost.clipsToBounds = true
        addSubview(imageHost)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .black
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        titleLabel.layer.cornerRadius = 10
        titleLabel.clipsToBounds = true
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        countLabel.font = .systemFont(ofSize: 10, weight: .bold)
        countLabel.textAlignment = .center
        countLabel.textColor = .white
        countLabel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        countLabel.layer.cornerRadius = 11
        countLabel.layer.borderWidth = 2
        countLabel.layer.borderColor = UIColor.white.cgColor
        countLabel.clipsToBounds = true
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.75
        countLabel.isUserInteractionEnabled = false
        addSubview(countLabel)

        // This annotation draws with subviews, not MKAnnotationView.image.
        // Route taps explicitly rather than relying on MapKit's image hit area.
        tapButton.backgroundColor = .clear
        tapButton.isAccessibilityElement = false
        tapButton.isUserInteractionEnabled = true
        tapButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tapButton.addTarget(self, action: #selector(activateMarker), for: .touchUpInside)
        addSubview(tapButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        // Removing the SwiftUI image subtree cancels its task. A new identity
        // also prevents an old URL's decoded pixels appearing for another pin.
        imageHost.configuration = UIHostingConfiguration {
            PostLocationMarkerContent(identity: nil)
        }.margins(.all, 0)
        thumbnailIdentity = nil
        titleLabel.text = nil
        countLabel.text = nil
        card.layer.borderWidth = 0
        titleLabel.textColor = .black
        countLabel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityIdentifier = nil
        accessibilityTraits = .button
        displayPriority = .defaultHigh
        zPriority = .defaultUnselected
    }

    override func accessibilityActivate() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }

    @objc private func activateMarker() { onTap?() }

    func configure(choice: MapTalkPostLocationChoice, selected: Bool) {
        // Avoid walking previousPosts or using a long caption as a map label.
        let title = choice.selection.locationName ?? choice.selection.title
        titleLabel.text = title
        countLabel.text = String(choice.postCount)

        let width = min(146, max(80, ceil(titleLabel.intrinsicContentSize.width) + 16))
        bounds.size = .init(width: width, height: 82)
        tapButton.frame = bounds
        isEnabled = true
        isUserInteractionEnabled = true
        centerOffset = .init(x: 0, y: -41)
        card.frame = .init(x: width / 2 - 28, y: 0, width: 56, height: 56)
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 14).cgPath
        imageHost.frame = card.frame.insetBy(dx: 4, dy: 4)
        titleLabel.frame = .init(x: 0, y: 59, width: width, height: 20)
        let countWidth = min(42, max(22, ceil(countLabel.intrinsicContentSize.width) + 10))
        countLabel.frame = .init(x: width / 2 + 29 - countWidth, y: 37,
                                width: countWidth, height: 22)
        tip.center = .init(x: width / 2, y: 78)

        card.layer.borderWidth = selected ? 1.5 : 0
        titleLabel.textColor = selected ? Self.mint : .black
        countLabel.backgroundColor = selected ? Self.mint : UIColor(white: 0.12, alpha: 1)
        displayPriority = selected ? .required : .defaultHigh
        zPriority = selected ? .max : .defaultUnselected
        accessibilityLabel = title
        accessibilityValue = "Your \(choice.postCount) \(choice.postCount == 1 ? "post" : "posts")"
        accessibilityHint = "Select this existing Post location for confirmation"
        accessibilityIdentifier = "maptalk.post.location-marker.\(choice.id)"
        accessibilityTraits = selected ? [.button, .selected] : [.button]

        let identity = PostLocationMarkerThumbnailIdentity(choiceID: choice.id, url: choice.thumbnailURL)
        guard identity != thumbnailIdentity else { return }
        thumbnailIdentity = identity
        imageHost.configuration = UIHostingConfiguration {
            PostLocationMarkerContent(identity: identity)
        }.margins(.all, 0)
    }
}

private struct PostLocationMarkerThumbnailIdentity: Hashable {
    let choiceID: String
    let url: URL?
}

/// UIHostingContentView requires every replacement configuration to keep its
/// original Content type. Clear only the subtree, never swap the root to EmptyView.
private struct PostLocationMarkerContent: View {
    let identity: PostLocationMarkerThumbnailIdentity?

    var body: some View {
        if let identity {
            PostLocationMarkerThumbnail(url: identity.url)
                .id(identity)
        } else {
            EmptyView()
        }
    }
}

private struct PostLocationMarkerThumbnail: View {
    let url: URL?

    var body: some View {
        // Private backend media already arrives as account-scoped file URLs
        // after authenticated downloading. Use the shared bounded/downsampled
        // file loader and existing HTTPS handling, with no per-marker cache.
        MapImage(url: url, thumbnailSize: CGSize(width: 48, height: 48)) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(red: 0.94, green: 0.95, blue: 0.94)
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.32))
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipped()
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
