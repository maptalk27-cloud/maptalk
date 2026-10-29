import SwiftUI
import UIKit
import Combine
@preconcurrency import AVFoundation

internal enum MapTalkCameraCaptureResult {
    case photo(UIImage)
    case video(URL)
}

/// The composer owns presentation and clipping; the camera never presents a second screen.
@MainActor
internal struct MapTalkInlineCameraView: View {
    let isActive: Bool
    let onCapture: @MainActor (MapTalkCameraCaptureResult) -> Void
    let onOpenLibrary: @MainActor () -> Void
    let onIssue: @MainActor (String) -> Void
    var onCaptureActivityChanged: @MainActor (Bool) -> Void = { _ in }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = MapTalkInlineCameraModel()

    var body: some View {
        ZStack {
            Color.black
            if let session = camera.session {
                MapTalkCameraPreview(session: session)
                    .accessibilityHidden(true)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.1), .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if let message = camera.unavailableMessage {
                VStack(spacing: 10) {
                    Image(systemName: "camera")
                        .font(.system(size: 30, weight: .light))
                    Text(message)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 100)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("maptalk.place.camera-unavailable")
            } else if camera.isReady == false, camera.captureInProgress == false {
                ProgressView().tint(.white)
            }

            VStack(spacing: 0) {
                if let recordingStartedAt = camera.recordingStartedAt {
                    TimelineView(.periodic(from: recordingStartedAt, by: 0.25)) { context in
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text(MapTalkInlineCameraPolicy.elapsedLabel(
                                seconds: context.date.timeIntervalSince(recordingStartedAt)
                            ))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.45), in: Capsule())
                    }
                    .accessibilityIdentifier("maptalk.place.recording-time")
                    .padding(.top, 18)
                }
                Spacer(minLength: 16)
                HStack {
                    Button(action: onOpenLibrary) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 48, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.captureInProgress)
                    .accessibilityLabel("Choose from library")
                    .accessibilityIdentifier("maptalk.place.library")

                    Spacer()
                    MapTalkPressShutter(
                        allowsNewCapture: camera.canBeginCapture,
                        isRecording: camera.isRecordingVideo,
                        isFinishing: camera.isFinishing,
                        onPhoto: camera.capturePhoto,
                        onHold: camera.beginHeldRecording,
                        onRelease: camera.endHeldRecording
                    )
                    .frame(width: 64, height: 64)

                    Spacer()
                    Button {
                        camera.flip()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 23, weight: .regular))
                            .frame(width: 48, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.canFlip == false || camera.captureInProgress || camera.isReady == false)
                    .opacity(camera.canFlip ? 1 : 0.4)
                    .accessibilityLabel("Switch camera")
                    .accessibilityIdentifier("maptalk.place.flip-camera")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

                Text(camera.shutterHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(height: 16)
                    .opacity(camera.isReady || camera.captureInProgress ? 1 : 0)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("maptalk.place.shutter-hint")
            }
        }
        .onAppear {
            camera.onCapture = onCapture
            camera.onIssue = onIssue
            camera.onCaptureActivityChanged = onCaptureActivityChanged
            camera.setVisible(true)
            camera.setActive(isActive && scenePhase == .active)
        }
        .onChange(of: isActive) { _, _ in
            camera.setActive(isActive && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            camera.setActive(isActive && phase == .active)
        }
        .onDisappear {
            camera.setVisible(false)
            onCaptureActivityChanged(false)
        }
    }
}

/// A touch produces either one photo or one recording, never both. It remains
/// consumed after the hold threshold even if permission or capture fails.
nonisolated internal struct MapTalkShutterPressState {
    enum Action: Equatable { case none, photo, startVideo, finishVideo }
    private enum Phase { case idle, pressed, holding }
    private var phase = Phase.idle
    static let holdDuration: TimeInterval = 0.3
    var isHolding: Bool { phase == .holding }

    mutating func began(acceptsNewCapture: Bool) -> Bool {
        guard acceptsNewCapture, phase == .idle else { return false }
        phase = .pressed
        return true
    }

    mutating func held() -> Action {
        guard phase == .pressed else { return .none }
        phase = .holding
        return .startVideo
    }

    mutating func ended(inside: Bool, cancelled: Bool = false) -> Action {
        defer { phase = .idle }
        switch phase {
        case .idle: return .none
        case .pressed: return inside && !cancelled ? .photo : .none
        case .holding: return .finishVideo
        }
    }
}

/// AVCaptureMovieFileOutput starts asynchronously. Releasing the shutter or
/// leaving the app before its didStart callback must still stop that recording.
nonisolated internal struct MapTalkRecordingStopLatch {
    private(set) var stopRequested = false
    mutating func begin() { stopRequested = false }
    mutating func requestStop() { stopRequested = true }
    func shouldStopOnStart(isActive: Bool, wasCancelled: Bool) -> Bool {
        stopRequested || !isActive || wasCancelled
    }
}

/// Small pure policies keep duration limits and successful-at-limit handling testable.
nonisolated internal enum MapTalkInlineCameraPolicy {
    static let maximumDuration: TimeInterval = 60

    static func elapsedLabel(seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? max(0, min(maximumDuration, seconds)) : 0
        let value = Int(bounded)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    static func recordingSucceeded(error: Error?) -> Bool {
        guard let error else { return true }
        return (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
    }

    static func shouldKeepRecording(finishedSuccessfully: Bool, fileByteCount: Int, wasCancelled: Bool) -> Bool {
        finishedSuccessfully && fileByteCount > 0 && wasCancelled == false
    }

    static func stabilizationMode(connectionSupports: Bool, formatSupportsStandard: Bool) -> AVCaptureVideoStabilizationMode {
        // Avoid cinematic/auto modes' extra latency and tighter crop in a quick-capture composer.
        connectionSupports && formatSupportsStandard ? .standard : .off
    }

    static func shutterHint(isRecording: Bool, isFinishing: Bool, microphoneJustGranted: Bool) -> String {
        if isFinishing { return "Saving…" }
        if isRecording { return "Release to finish" }
        if microphoneJustGranted { return "Microphone ready · hold to record" }
        return "Tap for photo · hold for video"
    }
}

@MainActor
private final class MapTalkInlineCameraModel: ObservableObject {
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var isReady = false
    @Published private(set) var canFlip = false
    @Published private(set) var captureInProgress = false {
        didSet {
            // Disable the composer's publish controls in the same shutter tap,
            // not one SwiftUI render later.
            if captureInProgress != oldValue { onCaptureActivityChanged?(captureInProgress) }
        }
    }
    @Published private(set) var isFinishing = false
    @Published private(set) var isRecordingVideo = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var unavailableMessage: String?
    @Published private var microphoneJustGranted = false

    var onCapture: (@MainActor (MapTalkCameraCaptureResult) -> Void)?
    var onIssue: (@MainActor (String) -> Void)?
    var onCaptureActivityChanged: (@MainActor (Bool) -> Void)?
    private var isVisible = false
    private var wantsActive = false
    private var permissionRequest: Task<Void, Never>?
    private var microphoneRequest: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var previousIdleTimerDisabled: Bool?
    private var engine: MapTalkInlineCameraEngine?
    private var enginePreparation: Task<Void, Never>?

    var canBeginCapture: Bool {
        isVisible && wantsActive && isReady && captureInProgress == false
    }

    var shutterHint: String {
        MapTalkInlineCameraPolicy.shutterHint(isRecording: isRecordingVideo,
            isFinishing: isFinishing, microphoneJustGranted: microphoneJustGranted)
    }

    private func prepareEngineIfNeeded() {
        if let engine {
            engine.setActive(wantsActive)
            return
        }
        guard enginePreparation == nil else { return }
        let onEvent: @Sendable (MapTalkInlineCameraEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else {
                    if case let .video(url) = event { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.receive(event)
            }
        }
        enginePreparation = Task { [weak self] in
            // Session and output initialization can block as well as startRunning.
            // Do not create them from SwiftUI's body on the main thread.
            let prepared = await Task.detached(priority: .userInitiated) {
                MapTalkInlineCameraEngine(onEvent: onEvent)
            }.value
            guard let self else { return }
            self.enginePreparation = nil
            guard self.isVisible else { return }
            self.engine = prepared
            self.session = prepared.session
            if self.wantsActive { prepared.setActive(true) }
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible == false {
            permissionRequest?.cancel()
            microphoneRequest?.cancel()
            wantsActive = false
            engine?.setActive(false, discardCapture: true)
            resetCapture()
        }
    }

    func setActive(_ active: Bool) {
        wantsActive = active && isVisible
        guard wantsActive else {
            isReady = false
            if captureInProgress, backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish place recording") { [weak self] in
                    guard let self else { return }
                    self.engine?.setActive(false, discardCapture: true)
                    self.endBackgroundTask()
                }
            }
            engine?.setActive(false)
            return
        }
#if targetEnvironment(simulator)
        unavailableMessage = "Use your library to add a photo or video."
        return
#else
        guard permissionRequest == nil else { return }
        permissionRequest = Task { [weak self] in
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard let self else { return }
            self.permissionRequest = nil
            guard Task.isCancelled == false, self.isVisible else { return }
            if granted {
                self.unavailableMessage = nil
                if self.wantsActive { self.prepareEngineIfNeeded() }
            } else {
                self.unavailableMessage = "Allow camera access in Settings, or choose from your library."
            }
        }
#endif
    }

    func prepareMicrophone() {
        guard isReady, wantsActive, microphoneRequest == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        microphoneRequest = Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.microphoneRequest = nil
            guard Task.isCancelled == false, self.isVisible else { return }
            if granted {
                // The permission alert ends the original touch. A visible hint
                // explains why that first hold did not start recording.
                self.microphoneJustGranted = true
            } else {
                self.onIssue?("Allow microphone access in Settings to record video with sound.")
            }
        }
    }

    func capturePhoto() {
        guard canBeginCapture else { return }
        microphoneJustGranted = false
        captureInProgress = true
        isFinishing = true
        engine?.capturePhoto()
    }

    func beginHeldRecording() {
        guard canBeginCapture else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                // A permission prompt ends this touch. Never replay its old
                // intent after the person releases or returns to the app.
                prepareMicrophone()
            } else {
                onIssue?("Allow microphone access in Settings to record video with sound.")
            }
            return
        }
        microphoneJustGranted = false
        captureInProgress = true
        isRecordingVideo = true
        engine?.startRecording()
    }

    func endHeldRecording() {
        guard isRecordingVideo, isFinishing == false else { return }
        isFinishing = true
        engine?.stopRecording()
    }

    func flip() {
        guard isReady, captureInProgress == false else { return }
        isReady = false
        engine?.flip()
    }

    private func resetCapture() {
        captureInProgress = false
        isFinishing = false
        isRecordingVideo = false
        recordingStartedAt = nil
        endBackgroundTask()
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func receive(_ event: MapTalkInlineCameraEvent) {
        guard isVisible else {
            if case let .video(url) = event { try? FileManager.default.removeItem(at: url) }
            return
        }
        switch event {
        case let .ready(canFlip):
            isReady = wantsActive
            self.canFlip = canFlip
            unavailableMessage = nil
        case .stopped:
            isReady = false
        case let .unavailable(message):
            isReady = false
            unavailableMessage = message
            resetCapture()
        case let .recording(date):
            recordingStartedAt = date
            captureInProgress = true
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            }
        case .finishing:
            isFinishing = true
        case let .photo(data):
            resetCapture()
            guard let image = UIImage(data: data) else {
                onIssue?("Couldn't save this photo. Please try again.")
                return
            }
            onCapture?(.photo(image))
        case let .video(url):
            resetCapture()
            onCapture?(.video(url))
        case let .failed(message):
            resetCapture()
            onIssue?(message)
        case .cancelled:
            resetCapture()
        }
    }
}

nonisolated private enum MapTalkInlineCameraEvent: Sendable {
    case ready(canFlip: Bool)
    case stopped
    case unavailable(String)
    case recording(Date)
    case finishing
    case photo(Data)
    case video(URL)
    case failed(String)
    case cancelled
}

/// All device/session mutations are confined to `queue`, including delegate completion handling.
/// Only the immutable session reference is exposed for AVCaptureVideoPreviewLayer.
nonisolated private final class MapTalkInlineCameraEngine: NSObject, @unchecked Sendable,
    AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "maptalk.inline-camera", qos: .userInitiated)
    private let onEvent: @Sendable (MapTalkInlineCameraEvent) -> Void
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var wantsActive = false
    private var activePhotoID: Int64?
    private var recordingURL: URL?
    private var recordingStop = MapTalkRecordingStopLatch()
    private var discardCapture = false
    private var observers: [NSObjectProtocol] = []

    init(onEvent: @escaping @Sendable (MapTalkInlineCameraEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.stopRecordingOnQueue()
                self.onEvent(.stopped)
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.resumeIfNeeded() }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let wasReset = (notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code
                == .mediaServicesWereReset
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.recordingURL != nil || self.activePhotoID != nil {
                    // A capture interrupted by a device failure must never arrive
                    // later and overwrite a newly selected library item.
                    self.discardCapture = true
                    self.activePhotoID = nil
                    self.stopRecordingOnQueue()
                    self.onEvent(.cancelled)
                }
                if wasReset, self.wantsActive {
                    self.resumeIfNeeded()
                } else {
                    self.onEvent(.unavailable("Camera is unavailable right now. You can still use your library."))
                }
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func setActive(_ active: Bool, discardCapture: Bool = false) {
        queue.async { [self] in
            wantsActive = active
            if discardCapture { self.discardCapture = true }
            guard active else {
                stopRecordingOnQueue()
                if session.isRunning { session.stopRunning() }
                onEvent(.stopped)
                return
            }
            do {
                if configured == false { try configure() }
                resumeIfNeeded()
            } catch {
                onEvent(.unavailable("Camera is unavailable right now. You can still use your library."))
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        videoInput = input
        guard session.canAddOutput(photoOutput), session.canAddOutput(movieOutput) else {
            session.removeInput(input)
            videoInput = nil
            throw CameraError.unavailable
        }
        session.addOutput(photoOutput)
        session.addOutput(movieOutput)
        movieOutput.maxRecordedDuration = CMTime(seconds: MapTalkInlineCameraPolicy.maximumDuration, preferredTimescale: 600)
        movieOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        updateOutputConnections()
        configured = true
    }

    private func updateOutputConnections() {
        for connection in [photoOutput.connection(with: .video), movieOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.videoRotationAngle != 90, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = videoInput?.device.position == .front
            }
        }
        if let connection = movieOutput.connection(with: .video) {
            let mode = MapTalkInlineCameraPolicy.stabilizationMode(
                connectionSupports: connection.isVideoStabilizationSupported,
                formatSupportsStandard: videoInput?.device.activeFormat.isVideoStabilizationModeSupported(.standard) == true
            )
            if connection.preferredVideoStabilizationMode != mode {
                connection.preferredVideoStabilizationMode = mode
            }
        }
    }

    private func resumeIfNeeded() {
        guard wantsActive, configured else { return }
        updateOutputConnections()
        if session.isRunning == false { session.startRunning() }
        if session.isRunning, session.isInterrupted == false {
            let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            onEvent(.ready(canFlip: front != nil && back != nil))
        }
    }

    func flip() {
        queue.async { [self] in
            guard wantsActive, recordingURL == nil, activePhotoID == nil,
                  let previous = videoInput else { return }
            let position: AVCaptureDevice.Position = previous.device.position == .front ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                resumeIfNeeded()
                return
            }
            session.beginConfiguration()
            session.removeInput(previous)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            } else if session.canAddInput(previous) {
                session.addInput(previous)
            }
            updateOutputConnections()
            session.commitConfiguration()
            resumeIfNeeded()
        }
    }

    func capturePhoto() {
        queue.async { [self] in
            guard wantsActive, session.isRunning, activePhotoID == nil, recordingURL == nil else {
                onEvent(.cancelled)
                return
            }
            discardCapture = false
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .balanced
            activePhotoID = settings.uniqueID
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func startRecording() {
        queue.async { [self] in
            guard wantsActive, session.isRunning, activePhotoID == nil, recordingURL == nil else {
                onEvent(.cancelled)
                return
            }
            do {
                try addMicrophoneIfNeeded()
                let url = try makeRecordingURL()
                discardCapture = false
                recordingURL = url
                recordingStop.begin()
                if let connection = movieOutput.connection(with: .video),
                   movieOutput.availableVideoCodecTypes.contains(.h264) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                }
                movieOutput.startRecording(to: url, recordingDelegate: self)
            } catch {
                removeMicrophoneOnQueue()
                onEvent(.failed("Couldn't start recording. Please try again."))
            }
        }
    }

    private func addMicrophoneIfNeeded() throws {
        guard audioInput == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: microphone)
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            updateOutputConnections()
        }
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        audioInput = input
    }

    private func makeRecordingURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("MapTalkMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    private func removeMicrophoneOnQueue() {
        guard let audioInput else { return }
        session.beginConfiguration()
        session.removeInput(audioInput)
        self.audioInput = nil
        session.commitConfiguration()
        updateOutputConnections()
    }

    func stopRecording() {
        queue.async { [self] in stopRecordingOnQueue() }
    }

    private func stopRecordingOnQueue() {
        guard recordingURL != nil else { return }
        recordingStop.requestStop()
        onEvent(.finishing)
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let uniqueID = photo.resolvedSettings.uniqueID
        queue.async { [self] in
            guard activePhotoID == uniqueID else { return }
            activePhotoID = nil
            if discardCapture {
                onEvent(.cancelled)
            } else if let data {
                onEvent(.photo(data))
            } else {
                onEvent(.failed("Couldn't save this photo. Please try again."))
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error != nil else { return }
        let uniqueID = resolvedSettings.uniqueID
        queue.async { [self] in
            guard activePhotoID == uniqueID else { return }
            activePhotoID = nil
            onEvent(discardCapture ? .cancelled : .failed("Couldn't save this photo. Please try again."))
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            guard recordingURL == fileURL else { return }
            if recordingStop.shouldStopOnStart(isActive: wantsActive, wasCancelled: discardCapture) {
                movieOutput.stopRecording()
                onEvent(.finishing)
            } else {
                onEvent(.recording(Date()))
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let succeeded = MapTalkInlineCameraPolicy.recordingSucceeded(error: error)
        queue.async { [self] in
            guard recordingURL == outputFileURL else { return }
            recordingURL = nil
            // The microphone is needed only for an explicitly started recording,
            // not while the user is deciding what to photograph next.
            removeMicrophoneOnQueue()
            let size = (try? outputFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if MapTalkInlineCameraPolicy.shouldKeepRecording(
                finishedSuccessfully: succeeded, fileByteCount: size, wasCancelled: discardCapture
            ) == false {
                try? FileManager.default.removeItem(at: outputFileURL)
                onEvent(discardCapture ? .cancelled : .failed("Couldn't save this video. Please try again."))
            } else {
                onEvent(.video(outputFileURL))
            }
        }
    }

    private enum CameraError: Error { case unavailable }
}

@MainActor
private struct MapTalkPressShutter: UIViewRepresentable {
    let allowsNewCapture: Bool
    let isRecording: Bool
    let isFinishing: Bool
    let onPhoto: () -> Void
    let onHold: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> MapTalkShutterControl { MapTalkShutterControl() }

    func updateUIView(_ view: MapTalkShutterControl, context: Context) {
        view.allowsNewCapture = allowsNewCapture
        view.isRecording = isRecording
        view.isFinishing = isFinishing
        view.onPhoto = onPhoto
        view.onHold = onHold
        view.onRelease = onRelease
        view.updateAppearance()
    }

    static func dismantleUIView(_ view: MapTalkShutterControl, coordinator: ()) {
        view.cancelTracking(with: nil)
    }
}

/// One UIKit tracking sequence owns both gestures. SwiftUI button/long-press
/// combinations can fire the photo on release or lose touch-up while busy.
@MainActor
private final class MapTalkShutterControl: UIControl {
    var allowsNewCapture = false
    var isRecording = false
    var isFinishing = false
    var onPhoto: (() -> Void)?
    var onHold: (() -> Void)?
    var onRelease: (() -> Void)?
    private var press = MapTalkShutterPressState()
    private var holdTimer: Timer?
    private let rim = CALayer()
    private let shutterFill = CALayer()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityIdentifier = "maptalk.place.add-media"
        accessibilityHint = "Tap to take a photo. Touch and hold to record video."
        rim.borderWidth = 3
        rim.borderColor = UIColor.white.cgColor
        layer.addSublayer(rim)
        layer.addSublayer(shutterFill)
        spinner.color = .white
        spinner.isUserInteractionEnabled = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        rim.cornerRadius = bounds.width / 2
        shutterFill.frame = bounds.insetBy(dx: isRecording ? 18 : 6, dy: isRecording ? 18 : 6)
        shutterFill.cornerRadius = isRecording ? 6 : shutterFill.bounds.width / 2
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func updateAppearance() {
        // Starting/finalizing must not disable the tracking touch: its release
        // is what stops the recording, including before didStart arrives.
        isEnabled = allowsNewCapture || isRecording || isFinishing || isTracking
        alpha = isEnabled ? 1 : 0.45
        shutterFill.backgroundColor = (isRecording ? UIColor.systemRed : .white).cgColor
        shutterFill.isHidden = isFinishing
        if isFinishing { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityLabel = isRecording ? "Stop recording" : "Take photo"
        accessibilityValue = isFinishing ? "Saving" : isRecording ? "Recording" : nil
        accessibilityTraits = allowsNewCapture || isRecording ? [.button] : [.button, .notEnabled]
        accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: isRecording ? "Stop recording" : "Record video"
        ) { [weak self] _ in
            guard let self, !self.isFinishing else { return false }
            if self.isRecording { self.onRelease?() }
            else if self.allowsNewCapture { self.onHold?() }
            else { return false }
            return true
        }]
        setNeedsLayout()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard press.began(acceptsNewCapture: allowsNewCapture) else { return false }
        let timer = Timer(timeInterval: MapTalkShutterPressState.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.perform(self.press.held())
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if !press.isHolding, !bounds.insetBy(dx: -20, dy: -20).contains(touch.location(in: self)) {
            cancelTracking(with: event)
            return false
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        holdTimer?.invalidate()
        holdTimer = nil
        let inside = touch.map { bounds.contains($0.location(in: self)) } ?? false
        perform(press.ended(inside: inside))
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        holdTimer?.invalidate()
        holdTimer = nil
        perform(press.ended(inside: false, cancelled: true))
        super.cancelTracking(with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard !isFinishing else { return false }
        if isRecording { onRelease?() }
        else if allowsNewCapture { onPhoto?() }
        else { return false }
        return true
    }

    private func perform(_ action: MapTalkShutterPressState.Action) {
        switch action {
        case .none: break
        case .photo: onPhoto?()
        case .startVideo: onHold?()
        case .finishVideo: onRelease?()
        }
    }
}

@MainActor
private struct MapTalkCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> MapTalkCameraPreviewUIView {
        let view = MapTalkCameraPreviewUIView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: MapTalkCameraPreviewUIView, context: Context) {
        uiView.attach(session: session)
    }

    static func dismantleUIView(_ uiView: MapTalkCameraPreviewUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

@MainActor
private final class MapTalkCameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func attach(session: AVCaptureSession) {
        guard previewLayer.session !== session else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.session = session
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.videoRotationAngle != 90, connection.isVideoRotationAngleSupported(90) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            connection.videoRotationAngle = 90
            CATransaction.commit()
        }
    }
}
