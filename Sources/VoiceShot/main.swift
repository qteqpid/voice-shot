import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Speech

struct AppSettings {
    private enum Key {
        static let language = "language"
        static let savePath = "savePath"
    }

    static var language: String {
        get { UserDefaults.standard.string(forKey: Key.language) ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: Key.language) }
    }

    static var saveURL: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Key.savePath), !path.isEmpty {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }

            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
            return documents.appendingPathComponent("VoiceShot")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Key.savePath) }
    }
}

enum PermissionManager {
    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func checkMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

struct TranscriptEvent: Codable, Sendable {
    let type: String
    let timestamp: Date
    let startedAt: Date
    let text: String
}

final class JSONLWriter {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "voiceshot.jsonl", qos: .utility)
    private let encoder: JSONEncoder

    init(saveURL: URL) throws {
        try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        fileURL = saveURL.appendingPathComponent("events.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func append<T: Encodable & Sendable>(_ value: T) {
        queue.async { [fileURL, encoder] in
            guard var data = try? encoder.encode(value) else { return }
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

final class TranscriptWriter {
    private let saveURL: URL
    private let timeFormatter: DateFormatter
    private let dateFormatter: DateFormatter
    private let jsonlWriter: JSONLWriter

    init(saveURL: URL, jsonlWriter: JSONLWriter) throws {
        try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        self.saveURL = saveURL
        self.jsonlWriter = jsonlWriter
        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
    }

    private func transcriptURL(for date: Date) -> URL {
        saveURL.appendingPathComponent("transcript-\(dateFormatter.string(from: date)).txt")
    }

    private func ensureFileExists(at fileURL: URL) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func append(startedAt: Date, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fileURL = transcriptURL(for: startedAt)
        ensureFileExists(at: fileURL)

        let line = "\(timeFormatter.string(from: startedAt)) \(trimmed)\n"
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }

        jsonlWriter.append(TranscriptEvent(
            type: "transcript",
            timestamp: Date(),
            startedAt: startedAt,
            text: trimmed
        ))
    }
}

@MainActor
final class NativeSpeechTranscriber {
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var sessionStartedAt = Date()
    private var onText: ((Date, String) -> Void)?

    func start(language: String, onText: @escaping (Date, String) -> Void) async throws {
        await stop()

        guard let locale = await SpeechLocale.bestMatching(preferredIdentifier: language) else {
            throw VoiceShotError.speechRecognizerUnavailable(language)
        }

        self.onText = onText
        sessionStartedAt = Date()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        try await SpeechLocale.ensureModelInstalled(transcriber: transcriber, locale: locale)

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceShotError.analyzerFormatUnavailable
        }
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, result.isFinal else { continue }
                    let text = String(result.text.characters)
                    let offset = self.startOffset(from: result.text)
                    self.onText?(self.sessionStartedAt.addingTimeInterval(offset), text)
                }
            } catch {
                NSLog("VoiceShot speech result stream error: \(error)")
            }
        }

        try startAudioCapture(analyzerFormat: analyzerFormat, inputBuilder: inputBuilder)
    }

    func stop() async {
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil

        inputBuilder?.finish()
        inputBuilder = nil

        if analyzer != nil {
            try? await withThrowingTimeout(seconds: 5) { [weak self] in
                try await self?.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
        }

        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        onText = nil
    }

    private func startAudioCapture(
        analyzerFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw VoiceShotError.noAudioDevice
        }

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
        }

        let audioOutput = AVCaptureAudioDataOutput()
        let captureQueue = DispatchQueue(label: "com.qteqpid.VoiceShot.audio-capture")
        let delegate = AudioCaptureDelegate(inputBuilder: inputBuilder, analyzerFormat: analyzerFormat)
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        captureDelegate = delegate
        captureSession = session
        session.startRunning()
    }

    private func startOffset(from attributedText: AttributedString) -> TimeInterval {
        typealias ConfidenceKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        for (_, timeRange, range) in attributedText.runs[ConfidenceKey.self, TimeKey.self] {
            let wordText = String(attributedText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return timeRange?.start.seconds ?? 0
        }

        return 0
    }
}

enum SpeechLocale {
    static func bestMatching(preferredIdentifier: String) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let preferred = Locale(identifier: preferredIdentifier).identifier(.bcp47)

        if let exact = supported.first(where: { $0.identifier(.bcp47) == preferred }) {
            return exact
        }

        let languagePrefix = preferred.split(separator: "-").first.map(String.init) ?? preferredIdentifier
        if let languageMatch = supported.first(where: { $0.identifier(.bcp47).hasPrefix(languagePrefix) }) {
            return languageMatch
        }

        if preferredIdentifier.lowercased().hasPrefix("zh") {
            for prefix in ["zh-Hans", "zh-CN", "zh-Hant", "zh"] {
                if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                    return match
                }
            }
        }

        return supported.first
    }

    static func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == localeID }) {
            return
        }

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }
}

final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(inputBuilder: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        let outputBuffer: AVAudioPCMBuffer
        if pcmBuffer.format.sampleRate != analyzerFormat.sampleRate
            || pcmBuffer.format.commonFormat != analyzerFormat.commonFormat
            || pcmBuffer.format.channelCount != analyzerFormat.channelCount {
            if converter == nil {
                converter = AVAudioConverter(from: pcmBuffer.format, to: analyzerFormat)
            }

            guard let converter, let converted = convert(buffer: pcmBuffer, using: converter, to: analyzerFormat) else {
                return
            }
            outputBuffer = converted
        } else {
            outputBuffer = pcmBuffer
        }

        inputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let state = ConversionState()
        converter.convert(to: output, error: &error) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

final class ConversionState: @unchecked Sendable {
    var consumed = false
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return pcmBuffer
    }
}

@MainActor
final class RecordingSession {
    private let transcriptWriter: TranscriptWriter
    private let transcriber = NativeSpeechTranscriber()

    init(saveURL: URL) throws {
        let jsonlWriter = try JSONLWriter(saveURL: saveURL)
        transcriptWriter = try TranscriptWriter(saveURL: saveURL, jsonlWriter: jsonlWriter)
    }

    func start() async throws {
        try await transcriber.start(language: AppSettings.language) { [weak self] startedAt, text in
            self?.transcriptWriter.append(startedAt: startedAt, text: text)
        }
    }

    func stop() async {
        await transcriber.stop()
    }
}

final class SettingsWindowController: NSWindowController {
    private let languagePopup = NSPopUpButton()
    private let pathField = NSTextField()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceShot Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        buildUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading

        languagePopup.addItems(withTitles: ["zh-CN", "en-US", "ja-JP", "ko-KR"])
        stack.addArrangedSubview(row(label: "Speech language", control: languagePopup))

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.spacing = 10
        pathRow.alignment = .centerY
        let pathLabel = NSTextField(labelWithString: "Save path")
        pathLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        pathField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        pathField.isEditable = false
        pathField.lineBreakMode = .byTruncatingMiddle
        pathRow.addArrangedSubview(pathLabel)
        pathRow.addArrangedSubview(pathField)
        stack.addArrangedSubview(pathRow)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        stack.addArrangedSubview(saveButton)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24)
        ])
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY

        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 170).isActive = true
        control.widthAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(control)
        return stack
    }

    private func load() {
        languagePopup.selectItem(withTitle: AppSettings.language)
        pathField.stringValue = NSString(string: AppSettings.saveURL.path).abbreviatingWithTildeInPath
    }

    @objc private func save() {
        AppSettings.language = languagePopup.titleOfSelectedItem ?? "zh-CN"
        close()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var recordingSession: RecordingSession?
    private var settingsController: SettingsWindowController?
    private var isRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in self.buildMenu() }
    }

    private func buildMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }

        if let button = statusItem?.button {
            button.image = makeStatusBarImage()
            button.title = ""
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = isRunning ? "VoiceShot is recording. Click and choose Stop Recording to finish." : "VoiceShot"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(NSMenuItem(title: isRunning ? "VoiceShot: Recording" : "VoiceShot: Idle", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        addPermissionRow(to: menu, title: "Microphone", granted: PermissionManager.isMicrophoneGranted(), action: #selector(openMicrophoneSettings))
        menu.addItem(.separator())
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(start), keyEquivalent: "s")
        startItem.isEnabled = !isRunning
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(finish), keyEquivalent: "f")
        stopItem.isEnabled = isRunning
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    private func makeStatusBarImage() -> NSImage {
        if isRunning {
            let image = NSImage(size: NSSize(width: 42, height: 18))
            image.lockFocus()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 5, width: 8, height: 8)).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.systemRed
            ]
            NSString(string: "REC").draw(in: NSRect(x: 11, y: 2, width: 30, height: 14), withAttributes: attributes)
            image.unlockFocus()
            image.isTemplate = false
            return image
        }

        for symbolName in ["mic.and.signal.meter", "waveform", "mic"] {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceShot") {
                image.isTemplate = true
                return image
            }
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        NSString(string: "VS").draw(in: NSRect(x: 2, y: 4, width: 14, height: 10), withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func addPermissionRow(to menu: NSMenu, title: String, granted: Bool, action: Selector) {
        let item = NSMenuItem(title: "\(granted ? "✓" : "!") \(title)", action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func start() {
        guard recordingSession == nil else {
            showAlert(title: "Already running", message: "Finish the current session before starting a new one.")
            return
        }

        Task {
            guard await PermissionManager.checkMicrophone() else {
                showAlert(title: "Microphone required", message: "VoiceShot needs Microphone permission.")
                buildMenu()
                return
            }

            do {
                let session = try RecordingSession(saveURL: AppSettings.saveURL)
                try await session.start()
                recordingSession = session
                isRunning = true
                updateStatusMessage(title: "VoiceShot started", message: "Recording speech")
                buildMenu()
            } catch {
                showAlert(title: "Failed to start", message: error.localizedDescription)
            }
        }
    }

    @objc private func finish() {
        guard let recordingSession else { return }
        Task {
            await recordingSession.stop()
            self.recordingSession = nil
            isRunning = false
            updateStatusMessage(title: "VoiceShot finished", message: "Saved to \(AppSettings.saveURL.path)")
            buildMenu()
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let settings = SettingsWindowController()
        settingsController = settings
        settings.showWindow(nil)
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        Task {
            if let recordingSession {
                await recordingSession.stop()
            }
            NSApp.terminate(nil)
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func updateStatusMessage(title: String, message: String) {
        statusItem?.button?.toolTip = "\(title): \(message)"
    }
}

enum VoiceShotError: LocalizedError {
    case speechRecognizerUnavailable(String)
    case analyzerFormatUnavailable
    case noAudioDevice
    case timeout

    var errorDescription: String? {
        switch self {
        case .speechRecognizerUnavailable(let language):
            return "SpeechAnalyzer is unavailable for \(language)."
        case .analyzerFormatUnavailable:
            return "SpeechAnalyzer could not provide a compatible audio format."
        case .noAudioDevice:
            return "No audio input device is available."
        case .timeout:
            return "Timed out while stopping speech recognition."
        }
    }
}

func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw VoiceShotError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
