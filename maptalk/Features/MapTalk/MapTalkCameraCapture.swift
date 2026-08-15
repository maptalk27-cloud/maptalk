import SwiftUI
import UIKit
import UniformTypeIdentifiers

internal enum MapTalkCameraCaptureResult {
    case photo(UIImage)
    case video(URL)
}

@MainActor
internal struct MapTalkCameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (MapTalkCameraCaptureResult) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 15
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (MapTalkCameraCaptureResult) -> Void
        private let onCancel: () -> Void

        init(
            onCapture: @escaping (MapTalkCameraCaptureResult) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(.photo(image))
                return
            }

            guard let sourceURL = info[.mediaURL] as? URL,
                  sourceURL.isFileURL else {
                onCancel()
                return
            }
            Task { @MainActor in
                let ownedURL = await Task.detached(priority: .userInitiated) {
                    Self.copyVideoToApplicationSupport(from: sourceURL)
                }.value
                guard let ownedURL else {
                    onCancel()
                    return
                }
                onCapture(.video(ownedURL))
            }
        }

        nonisolated private static func copyVideoToApplicationSupport(from sourceURL: URL) -> URL? {
            let fileManager = FileManager.default

            do {
                let applicationSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let mediaDirectory = applicationSupport.appendingPathComponent(
                    "MapTalkMedia",
                    isDirectory: true
                )
                try fileManager.createDirectory(
                    at: mediaDirectory,
                    withIntermediateDirectories: true
                )

                let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
                let destination = mediaDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension)
                try fileManager.copyItem(at: sourceURL, to: destination)
                return destination
            } catch {
                return nil
            }
        }
    }
}
