import AppKit
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import FluidAudio
import Speech

struct AppSettings {
    private enum Key {
        static let language = "language"
        static let savePath = "savePath"
        static let transcriptPanelFrame = "transcriptPanelFrame"
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

    static var transcriptPanelFrame: NSRect? {
        get {
            let frameString = UserDefaults.standard.string(forKey: Key.transcriptPanelFrame) ?? ""
            guard !frameString.isEmpty else { return nil }
            return NSRectFromString(frameString)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSStringFromRect(newValue), forKey: Key.transcriptPanelFrame)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.transcriptPanelFrame)
            }
        }
    }
}

struct SpeechRecognitionMode {
    let primaryLocaleIdentifier: String

    var storageValue: String { primaryLocaleIdentifier }
    var title: String { primaryLocaleIdentifier }
    var isMixedWithEnglish: Bool { !primaryLocaleIdentifier.lowercased().hasPrefix("en") }

    static let all: [SpeechRecognitionMode] = [
        SpeechRecognitionMode(primaryLocaleIdentifier: "zh-CN"),
        SpeechRecognitionMode(primaryLocaleIdentifier: "en-US"),
        SpeechRecognitionMode(primaryLocaleIdentifier: "ja-JP"),
        SpeechRecognitionMode(primaryLocaleIdentifier: "ko-KR")
    ]

    static func mode(for storageValue: String) -> SpeechRecognitionMode {
        let primaryIdentifier = storageValue.components(separatedBy: "+").first ?? storageValue
        return all.first { $0.primaryLocaleIdentifier == primaryIdentifier }
            ?? SpeechRecognitionMode(primaryLocaleIdentifier: primaryIdentifier)
    }

    var reportingOptions: Set<SpeechTranscriber.ReportingOption> {
        isMixedWithEnglish ? [.volatileResults, .alternativeTranscriptions] : [.volatileResults]
    }

    var attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> {
        isMixedWithEnglish ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange]
    }

    func makeAnalysisContext() -> AnalysisContext {
        let context = AnalysisContext()
        if isMixedWithEnglish {
            context.contextualStrings[.general] = Self.mixedWithEnglishContextualStrings
        }
        return context
    }

    static let mixedWithEnglishContextualStrings = [
        "Zoom", "meeting", "OK", "yes", "no", "hello", "hi", "thanks", "thank you",
        "question", "answer", "issue", "problem", "solution", "feedback", "follow up",
        "next step", "action item", "agenda", "timeline", "deadline", "status", "update",
        "project", "product", "design", "engineering", "review", "decision", "proposal",
        "document", "doc", "slide", "dashboard", "report", "data", "metric", "experiment",
        "API", "SDK", "UI", "UX", "PR", "pull request", "branch", "release", "deploy",
        "backend", "frontend", "server", "client", "database", "cache", "feature", "bug",
        "test", "testing", "debug", "login", "signup", "payment", "checkout", "profile",
        "notification", "permission", "setting", "config", "model", "prompt", "agent",
        "transcript", "recording", "audio", "speech", "English"
    ]
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

final class TranscriptWriter {
    private let saveURL: URL
    private let fileNameFormatter: DateFormatter

    init(saveURL: URL) throws {
        try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        self.saveURL = saveURL
        fileNameFormatter = DateFormatter()
        fileNameFormatter.dateFormat = "yyyyMMdd-HHmmss"
    }

    private func transcriptURL(for sessionStartedAt: Date) -> URL {
        saveURL.appendingPathComponent("transcript-\(fileNameFormatter.string(from: sessionStartedAt)).txt")
    }

    func recordingURL(for sessionStartedAt: Date) -> URL {
        saveURL.appendingPathComponent("recording-\(fileNameFormatter.string(from: sessionStartedAt)).caf")
    }

    private func ensureFileExists(at fileURL: URL) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func saveTranscript(for sessionStartedAt: Date, text: String) throws -> URL {
        let fileURL = transcriptURL(for: sessionStartedAt)
        ensureFileExists(at: fileURL)

        var normalized = text
        if !normalized.isEmpty && !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        try normalized.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

struct TranscriptSegment: Sendable {
    let startedAt: Date
    let audioOffset: TimeInterval
    let audioEndOffset: TimeInterval
    let text: String
}

struct TranscriptUpdate: Sendable {
    let segment: TranscriptSegment
    let replacesPreviousLine: Bool
}

@MainActor
final class NativeSpeechTranscriber {
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var audioWriter: AudioFileWriter?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var sessionStartedAt = Date()
    private var onText: ((Date, TimeInterval, TimeInterval, String, Bool) -> Void)?
    private var onVoiceActivity: ((Date) -> Void)?

    func start(
        language: String,
        audioFileURL: URL,
        onVoiceActivity: @escaping (Date) -> Void,
        onText: @escaping (Date, TimeInterval, TimeInterval, String, Bool) -> Void
    ) async throws {
        await stop()

        let recognitionMode = SpeechRecognitionMode.mode(for: language)
        guard let locale = await SpeechLocale.bestMatching(preferredIdentifier: recognitionMode.primaryLocaleIdentifier) else {
            throw VoiceShotError.speechRecognizerUnavailable(language)
        }

        self.onText = onText
        self.onVoiceActivity = onVoiceActivity
        sessionStartedAt = Date()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: recognitionMode.reportingOptions,
            attributeOptions: recognitionMode.attributeOptions
        )
        self.transcriber = transcriber

        try await SpeechLocale.ensureModelInstalled(transcriber: transcriber, locale: locale)

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.setContext(recognitionMode.makeAnalysisContext())
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceShotError.analyzerFormatUnavailable
        }
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        let audioWriter = try AudioFileWriter(fileURL: audioFileURL, format: analyzerFormat)
        self.audioWriter = audioWriter

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { continue }
                    let text = self.bestText(from: result, recognitionMode: recognitionMode)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let offset = self.startOffset(from: result.text)
                    let endOffset = self.endOffset(from: result.text)
                    self.onText?(self.sessionStartedAt.addingTimeInterval(offset), offset, endOffset, text, result.isFinal)
                }
            } catch {
                NSLog("VoiceShot speech result stream error: \(error)")
            }
        }

        try startAudioCapture(analyzerFormat: analyzerFormat, inputBuilder: inputBuilder, audioWriter: audioWriter)
    }

    func stop() async {
        captureSession?.stopRunning()
        let writer = audioWriter
        captureSession = nil
        captureDelegate = nil
        writer?.finish()
        audioWriter = nil

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
        onVoiceActivity = nil
    }

    private func startAudioCapture(
        analyzerFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        audioWriter: AudioFileWriter
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
        let delegate = AudioCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioWriter: audioWriter,
            onVoiceActivity: { [weak self] startedAt in
                Task { @MainActor [weak self] in
                    self?.onVoiceActivity?(startedAt)
                }
            }
        )
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

    private func endOffset(from attributedText: AttributedString) -> TimeInterval {
        typealias ConfidenceKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        var latestEnd: TimeInterval = 0
        for (_, timeRange, range) in attributedText.runs[ConfidenceKey.self, TimeKey.self] {
            let wordText = String(attributedText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let timeRange else { continue }
            latestEnd = max(latestEnd, CMTimeRangeGetEnd(timeRange).seconds)
        }

        return latestEnd
    }

    private func bestText(from result: SpeechTranscriber.Result, recognitionMode: SpeechRecognitionMode) -> String {
        guard recognitionMode.isMixedWithEnglish, !result.alternatives.isEmpty else {
            return String(result.text.characters)
        }

        let candidates = [result.text] + result.alternatives
        let bestCandidate = candidates.max { first, second in
            mixedWithEnglishScore(for: first) < mixedWithEnglishScore(for: second)
        } ?? result.text
        return String(bestCandidate.characters)
    }

    private func mixedWithEnglishScore(for attributedText: AttributedString) -> Double {
        let text = String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return -Double.infinity }

        var score = averageConfidence(for: attributedText) ?? 0.5
        let scriptCounts = scriptCounts(in: text)

        if scriptCounts.nonLatinPrimary > 0 && scriptCounts.latin > 0 {
            score += 0.08
        } else if scriptCounts.nonLatinPrimary == 0 && scriptCounts.latin > 0 {
            score -= 0.04
        }

        score += min(Double(scriptCounts.latin), 24) * 0.003
        score += min(Double(contextualHitCount(in: text)), 5) * 0.025
        return score
    }

    private func averageConfidence(for attributedText: AttributedString) -> Double? {
        typealias ConfidenceKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute

        var weightedConfidence = 0.0
        var characterCount = 0

        for (confidence, range) in attributedText.runs[ConfidenceKey.self] {
            guard let confidence else { continue }
            let text = String(attributedText[range].characters)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let count = trimmed.count
            weightedConfidence += confidence * Double(count)
            characterCount += count
        }

        guard characterCount > 0 else { return nil }
        return weightedConfidence / Double(characterCount)
    }

    private func scriptCounts(in text: String) -> (nonLatinPrimary: Int, latin: Int) {
        var nonLatinPrimary = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                nonLatinPrimary += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                continue
            }
        }

        return (nonLatinPrimary, latin)
    }

    private func contextualHitCount(in text: String) -> Int {
        let normalized = text.lowercased()
        return SpeechRecognitionMode.mixedWithEnglishContextualStrings.reduce(0) { count, term in
            normalized.contains(term.lowercased()) ? count + 1 : count
        }
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
    private let audioWriter: AudioFileWriter
    private let onVoiceActivity: @Sendable (Date) -> Void
    private var converter: AVAudioConverter?
    private var lastVoiceActivityAt = Date.distantPast

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat,
        audioWriter: AudioFileWriter,
        onVoiceActivity: @escaping @Sendable (Date) -> Void
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioWriter = audioWriter
        self.onVoiceActivity = onVoiceActivity
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        notifyVoiceActivityIfNeeded(from: pcmBuffer)

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

        audioWriter.write(outputBuffer)
        inputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
    }

    private func notifyVoiceActivityIfNeeded(from buffer: AVAudioPCMBuffer) {
        guard isLikelyVoiceActivity(buffer) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastVoiceActivityAt) > 0.8 else { return }

        lastVoiceActivityAt = now
        onVoiceActivity(now)
    }

    private func isLikelyVoiceActivity(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        if let channels = buffer.floatChannelData {
            let channelCount = max(1, Int(buffer.format.channelCount))
            var sum: Float = 0
            var count = 0

            for channelIndex in 0..<channelCount {
                let samples = channels[channelIndex]
                for frameIndex in 0..<frameLength {
                    let sample = samples[frameIndex]
                    sum += sample * sample
                    count += 1
                }
            }

            guard count > 0 else { return false }
            let rms = sqrt(sum / Float(count))
            return rms > 0.018
        }

        if let channels = buffer.int16ChannelData {
            let channelCount = max(1, Int(buffer.format.channelCount))
            var sum: Float = 0
            var count = 0

            for channelIndex in 0..<channelCount {
                let samples = channels[channelIndex]
                for frameIndex in 0..<frameLength {
                    let normalized = Float(samples[frameIndex]) / Float(Int16.max)
                    sum += normalized * normalized
                    count += 1
                }
            }

            guard count > 0 else { return false }
            let rms = sqrt(sum / Float(count))
            return rms > 0.018
        }

        return false
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

final class AudioFileWriter: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let writeQueue = DispatchQueue(label: "com.qteqpid.VoiceShot.audio-file-writer")

    init(fileURL: URL, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyBuffer(buffer) else { return }
        writeQueue.async { [audioFile] in
            do {
                try audioFile.write(from: copy)
            } catch {
                NSLog("VoiceShot audio write error: \(error)")
            }
        }
    }

    func finish() {
        writeQueue.sync {}
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData, let destinationData = destinationBuffers[index].mData else {
                continue
            }

            destinationBuffers[index].mDataByteSize = source.mDataByteSize
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
        }

        return copy
    }
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

actor FluidAudioSpeakerModelStore {
    static let shared = FluidAudioSpeakerModelStore()

    private var loadedModels: DiarizerModels?
    private var loadingTask: Task<DiarizerModels, Error>?

    func models(progressHandler: DownloadUtils.ProgressHandler? = nil) async throws -> DiarizerModels {
        if let loadedModels {
            return loadedModels
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task {
            try await DiarizerModels.downloadIfNeeded { progress in
                NSLog("VoiceShot FluidAudio model download: \(Int(progress.fractionCompleted * 100))%%")
                progressHandler?(progress)
            }
        }
        loadingTask = task

        do {
            let models = try await task.value
            loadedModels = models
            loadingTask = nil
            return models
        } catch {
            loadingTask = nil
            throw error
        }
    }

    func readyModels() -> DiarizerModels? {
        loadedModels
    }
}

final class FluidAudioSpeakerDiarizer {
    private static let sampleRate = 16_000

    static func prepareModels(progressHandler: DownloadUtils.ProgressHandler? = nil) async throws {
        _ = try await FluidAudioSpeakerModelStore.shared.models(progressHandler: progressHandler)
    }

    func annotatedTranscript(for segments: [TranscriptSegment], audioURL: URL, models: DiarizerModels) async throws -> String {
        let labels = try await speakerLabels(for: segments, audioURL: audioURL, models: models)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        return zip(segments, labels)
            .map { segment, label in
                "\(formatter.string(from: segment.startedAt)) [\(label)] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
            .joined()
    }

    private func speakerLabels(for segments: [TranscriptSegment], audioURL: URL, models: DiarizerModels) async throws -> [String] {
        guard segments.count > 1 else {
            return Array(repeating: "A", count: segments.count)
        }

        let samples = try Self.diarizationSamples(from: audioURL)
        let audioDuration = Double(samples.count) / Double(Self.sampleRate)
        guard audioDuration >= 2 else {
            return Array(repeating: "A", count: segments.count)
        }

        let diarizer = DiarizerManager(config: DiarizerConfig())
        diarizer.initialize(models: models)
        let result = try diarizer.performCompleteDiarization(samples, sampleRate: Self.sampleRate)
        return Self.labels(for: segments, diarization: result.segments)
    }

    private static func diarizationSamples(from audioURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sourceFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return []
        }

        try audioFile.read(into: sourceBuffer)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.commonFormat == targetFormat.commonFormat,
           sourceFormat.channelCount == targetFormat.channelCount,
           let floatData = sourceBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: floatData[0], count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return []
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }

        var error: NSError?
        let state = ConversionState()
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error {
            throw error
        }

        guard let floatData = outputBuffer.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outputBuffer.frameLength)))
    }

    private static func labels(for segments: [TranscriptSegment], diarization: [TimedSpeakerSegment]) -> [String] {
        guard !diarization.isEmpty else {
            return Array(repeating: "A", count: segments.count)
        }

        var labelBySpeakerID: [String: String] = [:]
        var nextLabelScalar = 65

        return segments.map { segment in
            let speakerID = bestSpeakerID(for: segment, diarization: diarization)
            guard let speakerID else { return "A" }

            if let label = labelBySpeakerID[speakerID] {
                return label
            }

            let label = String(UnicodeScalar(nextLabelScalar) ?? "A")
            labelBySpeakerID[speakerID] = label
            nextLabelScalar += 1
            return label
        }
    }

    private static func bestSpeakerID(for segment: TranscriptSegment, diarization: [TimedSpeakerSegment]) -> String? {
        let segmentStart = segment.audioOffset
        let segmentEnd = max(segment.audioEndOffset, segmentStart)
        var bestSpeakerID: String?
        var bestOverlap: TimeInterval = 0

        for diarizedSegment in diarization {
            let diarizedStart = TimeInterval(diarizedSegment.startTimeSeconds)
            let diarizedEnd = TimeInterval(diarizedSegment.endTimeSeconds)
            let overlapStart = max(segmentStart, diarizedStart)
            let overlapEnd = min(segmentEnd, diarizedEnd)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerID = diarizedSegment.speakerId
            }
        }

        return bestSpeakerID
    }
}

@MainActor
final class RecordingSession {
    private let transcriptWriter: TranscriptWriter
    private let transcriber = NativeSpeechTranscriber()
    private let startedAt = Date()
    private let audioURL: URL
    private var transcriptSegments: [TranscriptSegment] = []

    init(saveURL: URL) throws {
        transcriptWriter = try TranscriptWriter(saveURL: saveURL)
        audioURL = transcriptWriter.recordingURL(for: startedAt)
    }

    func start(
        onVoiceActivity: ((Date) -> Void)? = nil,
        onPartialText: ((Date, String) -> Void)? = nil,
        onFinalText: ((Date, String, Bool) -> Void)? = nil
    ) async throws {
        try await transcriber.start(
            language: AppSettings.language,
            audioFileURL: audioURL,
            onVoiceActivity: { startedAt in
                onVoiceActivity?(startedAt)
            },
            onText: { [weak self] startedAt, audioOffset, audioEndOffset, text, isFinal in
                if isFinal {
                    let update = self?.appendOrMergeFinalSegment(
                        startedAt: startedAt,
                        audioOffset: audioOffset,
                        audioEndOffset: audioEndOffset,
                        text: text
                    )
                    if let update {
                        onFinalText?(update.segment.startedAt, update.segment.text, update.replacesPreviousLine)
                    }
                } else {
                    onPartialText?(startedAt, text)
                }
            }
        )
    }

    func stop() async {
        await transcriber.stop()
    }

    func saveTranscript(_ text: String) throws -> URL {
        try transcriptWriter.saveTranscript(for: startedAt, text: text)
    }

    func speakerLabeledTranscript() async throws -> String? {
        guard transcriptSegments.count > 1, FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }

        let segments = transcriptSegments
        let recordingURL = audioURL
        guard let models = await FluidAudioSpeakerModelStore.shared.readyModels() else {
            return nil
        }

        return try await FluidAudioSpeakerDiarizer().annotatedTranscript(for: segments, audioURL: recordingURL, models: models)
    }

    private func appendOrMergeFinalSegment(
        startedAt: Date,
        audioOffset: TimeInterval,
        audioEndOffset: TimeInterval,
        text: String
    ) -> TranscriptUpdate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSegment = TranscriptSegment(
            startedAt: startedAt,
            audioOffset: audioOffset,
            audioEndOffset: max(audioOffset, audioEndOffset),
            text: trimmed
        )

        guard let previous = transcriptSegments.last,
              shouldMerge(previous: previous, next: newSegment) else {
            transcriptSegments.append(newSegment)
            return TranscriptUpdate(segment: newSegment, replacesPreviousLine: false)
        }

        let mergedSegment = TranscriptSegment(
            startedAt: previous.startedAt,
            audioOffset: previous.audioOffset,
            audioEndOffset: max(previous.audioEndOffset, newSegment.audioEndOffset),
            text: mergedText(previous.text, trimmed)
        )
        transcriptSegments[transcriptSegments.count - 1] = mergedSegment
        return TranscriptUpdate(segment: mergedSegment, replacesPreviousLine: true)
    }

    private func shouldMerge(previous: TranscriptSegment, next: TranscriptSegment) -> Bool {
        guard !previous.text.isEmpty, !next.text.isEmpty else { return false }
        guard !endsSentence(previous.text) else { return false }

        let gap = next.audioOffset - previous.audioEndOffset
        return gap >= -0.4 && gap < 2.5
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last else {
            return false
        }
        return ".。!?！？".unicodeScalars.contains(last)
    }

    private func mergedText(_ previous: String, _ next: String) -> String {
        let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        guard let leftLast = left.unicodeScalars.last, let rightFirst = right.unicodeScalars.first else {
            return left + right
        }

        if isClosingPunctuation(rightFirst)
            || (isCJK(leftLast) && isCJK(rightFirst))
            || (isLatin(leftLast) && isCJK(rightFirst)) {
            return left + right
        }

        if isCJK(leftLast) && isLatin(rightFirst) {
            return left + " " + right
        }

        if isLatin(leftLast) && isLatin(rightFirst) {
            return left + " " + right
        }

        return left + right
    }

    private func isLatin(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x0030...0x0039, 0x0027:
            return true
        default:
            return false
        }
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private func isClosingPunctuation(_ scalar: UnicodeScalar) -> Bool {
        ".,，。!?！？;；:：)]}）】」』".unicodeScalars.contains(scalar)
    }

}

@MainActor
final class TranscriptOverlayController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let copyButton = NSButton()
    private let titlebarAccessoryController = NSTitlebarAccessoryViewController()
    private let timeFormatter: DateFormatter
    private var pendingStartedAt: Date?
    private var pendingDotCount = 0
    private var pendingTimer: Timer?
    private var canClose = false
    private var didSaveOnClose = false
    var onSaveAndClose: ((String) -> Bool)?
    var onDidClose: (() -> Void)?

    init() {
        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let panel = NSPanel(
            contentRect: AppSettings.transcriptPanelFrame ?? NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "VoiceShot Transcript"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 180)

        super.init(window: panel)
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isEnabled = false
        buildUI()
        buildTitlebarControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(near statusItem: NSStatusItem?) {
        if AppSettings.transcriptPanelFrame == nil {
            positionBelowMenuBar(near: statusItem)
        }
        window?.orderFrontRegardless()
    }

    func showPending(startedAt: Date) {
        if pendingStartedAt == nil {
            pendingStartedAt = startedAt
            pendingDotCount = 0
            appendPendingLine()
            startPendingAnimation()
        }
    }

    func append(startedAt: Date, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        removePendingIfNeeded()

        let line = "\(timeFormatter.string(from: startedAt)) \(trimmed)\n"
        textView.textStorage?.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    func replaceLastLine(startedAt: Date, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        removePendingIfNeeded()
        removeLastLine()
        append(startedAt: startedAt, text: trimmed)
    }

    func clear() {
        textView.string = ""
        stopPendingAnimation()
        pendingStartedAt = nil
    }

    func replaceTranscript(with text: String) {
        removePendingIfNeeded()
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    override func close() {
        guard canClose else { return }
        guard saveBeforeClosingIfNeeded() else { return }
        stopPendingAnimation()
        super.close()
    }

    func enableCloseForSaving() {
        removePendingIfNeeded()
        canClose = true
        window?.standardWindowButton(.closeButton)?.isEnabled = true
    }

    @discardableResult
    func closeForSaving() -> Bool {
        enableCloseForSaving()
        close()
        return didSaveOnClose
    }

    func closeWithoutSaving() {
        canClose = true
        onSaveAndClose = nil
        onDidClose = nil
        close()
    }

    func transcriptTextForSaving() -> String {
        removePendingIfNeeded()
        return textView.string
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canClose else { return false }
        return saveBeforeClosingIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        stopPendingAnimation()
        onDidClose?()
        onSaveAndClose = nil
        onDidClose = nil
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.string = ""

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func buildTitlebarControls() {
        guard let window else { return }

        copyButton.frame = NSRect(x: 4, y: 2, width: 30, height: 24)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy transcript")
        copyButton.imagePosition = .imageOnly
        copyButton.bezelStyle = .rounded
        copyButton.setButtonType(.momentaryPushIn)
        copyButton.toolTip = "Copy transcript"
        copyButton.target = self
        copyButton.action = #selector(copyTranscript)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        container.addSubview(copyButton)

        titlebarAccessoryController.view = container
        titlebarAccessoryController.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(titlebarAccessoryController)
    }

    @objc private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptTextForSaving(), forType: .string)
    }

    private func saveBeforeClosingIfNeeded() -> Bool {
        guard !didSaveOnClose else { return true }

        didSaveOnClose = true
        let shouldClose = onSaveAndClose?(transcriptTextForSaving()) ?? true
        if !shouldClose {
            didSaveOnClose = false
        }
        return shouldClose
    }

    private func positionBelowMenuBar(near statusItem: NSStatusItem?) {
        guard let window else { return }

        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }

        var frame = window.frame
        let buttonFrame = statusItem?.button?.window?.convertToScreen(statusItem?.button?.frame ?? .zero)
        let preferredMidX = buttonFrame?.midX ?? visibleFrame.midX
        frame.origin.x = min(max(preferredMidX - frame.width / 2, visibleFrame.minX + 12), visibleFrame.maxX - frame.width - 12)
        frame.origin.y = visibleFrame.maxY - frame.height - 12
        window.setFrame(frame, display: true)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        AppSettings.transcriptPanelFrame = frame
    }

    private func startPendingAnimation() {
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePendingLine()
            }
        }
        RunLoop.main.add(pendingTimer!, forMode: .common)
    }

    private func stopPendingAnimation() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingDotCount = 0
    }

    private func updatePendingLine() {
        guard pendingStartedAt != nil else { return }
        pendingDotCount = (pendingDotCount % 3) + 1
        removeLastLine()
        appendPendingLine()
    }

    private func appendPendingLine() {
        guard let pendingStartedAt else { return }

        let dots = String(repeating: ".", count: max(1, pendingDotCount))
        let line = "\(timeFormatter.string(from: pendingStartedAt)) \(dots)\n"
        textView.textStorage?.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    private func removePendingIfNeeded() {
        guard pendingStartedAt != nil else { return }

        stopPendingAnimation()
        removeLastLine()
        pendingStartedAt = nil
    }

    private func removeLastLine() {
        let storage = textView.textStorage
        let fullRange = NSRange(location: 0, length: storage?.length ?? 0)
        guard let storage, fullRange.length > 0 else { return }

        let string = storage.string as NSString
        var searchLocation = max(0, string.length - 2)
        while searchLocation > 0 && string.character(at: searchLocation) != 10 {
            searchLocation -= 1
        }

        let start = string.character(at: searchLocation) == 10 ? searchLocation + 1 : 0
        storage.deleteCharacters(in: NSRange(location: start, length: string.length - start))
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

        for mode in SpeechRecognitionMode.all {
            languagePopup.addItem(withTitle: mode.title)
            languagePopup.lastItem?.representedObject = mode.storageValue
        }
        stack.addArrangedSubview(row(label: "Primary speech language", control: languagePopup))

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
        let mode = SpeechRecognitionMode.mode(for: AppSettings.language)
        languagePopup.selectItem(withTitle: mode.title)
        pathField.stringValue = NSString(string: AppSettings.saveURL.path).abbreviatingWithTildeInPath
    }

    @objc private func save() {
        AppSettings.language = languagePopup.selectedItem?.representedObject as? String ?? "zh-CN"
        close()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum SpeakerModelState {
        case preparing
        case ready
        case failed(String)

        var menuTitle: String {
            switch self {
            case .preparing:
                return "Speaker Model: Preparing"
            case .ready:
                return "Speaker Model: Ready"
            case .failed:
                return "Speaker Model: Unavailable"
            }
        }
    }

    private var statusItem: NSStatusItem?
    private var recordingSession: RecordingSession?
    private var pendingTranscriptSession: RecordingSession?
    private var settingsController: SettingsWindowController?
    private var transcriptOverlay: TranscriptOverlayController?
    private var isRunning = false
    private var speakerModelState: SpeakerModelState = .preparing

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        prepareSpeakerModelInBackground()
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

        let statusTitle: String
        if isRunning {
            statusTitle = "VoiceShot: Recording"
        } else if pendingTranscriptSession != nil {
            statusTitle = "VoiceShot: Transcript Open"
        } else {
            statusTitle = "VoiceShot: Idle"
        }
        menu.addItem(NSMenuItem(title: statusTitle, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        addPermissionRow(to: menu, title: "Microphone", granted: PermissionManager.isMicrophoneGranted(), action: #selector(openMicrophoneSettings))
        addSpeakerModelRow(to: menu)
        menu.addItem(.separator())
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(start), keyEquivalent: "s")
        startItem.isEnabled = !isRunning && pendingTranscriptSession == nil
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

    private func addSpeakerModelRow(to menu: NSMenu) {
        let item = NSMenuItem(title: speakerModelState.menuTitle, action: nil, keyEquivalent: "")
        switch speakerModelState {
        case .failed(let message):
            item.toolTip = "Speaker labels will be skipped. \(message)"
        case .preparing:
            item.toolTip = "VoiceShot is preparing the speaker-label model in the background."
        case .ready:
            item.toolTip = "Speaker labels will be added after recording stops."
        }
        menu.addItem(item)
    }

    private func prepareSpeakerModelInBackground() {
        speakerModelState = .preparing
        Task { [weak self] in
            do {
                try await FluidAudioSpeakerDiarizer.prepareModels()
                await MainActor.run {
                    self?.speakerModelState = .ready
                    self?.buildMenu()
                }
            } catch {
                NSLog("VoiceShot speaker model preparation failed: \(error)")
                await MainActor.run {
                    self?.speakerModelState = .failed(error.localizedDescription)
                    self?.updateStatusMessage(title: "VoiceShot", message: "Speaker labels unavailable")
                    self?.buildMenu()
                }
            }
        }
    }

    @objc private func start() {
        guard recordingSession == nil, pendingTranscriptSession == nil else {
            showAlert(title: "Transcript still open", message: "Close the transcript window to save it before starting a new recording.")
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
                let overlay = TranscriptOverlayController()
                overlay.clear()
                overlay.show(near: statusItem)
                overlay.onSaveAndClose = { [weak self, weak session] text in
                    guard let self, let session else { return true }
                    do {
                        let fileURL = try session.saveTranscript(text)
                        self.updateStatusMessage(title: "VoiceShot saved", message: "Saved to \(fileURL.path)")
                        return true
                    } catch {
                        self.showAlert(title: "Save failed", message: error.localizedDescription)
                        return false
                    }
                }
                overlay.onDidClose = { [weak self, weak overlay, weak session] in
                    guard let self else { return }
                    if self.transcriptOverlay === overlay {
                        self.transcriptOverlay = nil
                    }
                    if let session {
                        if self.recordingSession === session {
                            self.recordingSession = nil
                        }
                        if self.pendingTranscriptSession === session {
                            self.pendingTranscriptSession = nil
                        }
                    }
                    self.isRunning = false
                    self.buildMenu()
                }
                transcriptOverlay = overlay

                try await session.start(
                    onVoiceActivity: { [weak overlay] startedAt in
                        overlay?.showPending(startedAt: startedAt)
                    },
                    onPartialText: { [weak overlay] startedAt, text in
                        overlay?.showPending(startedAt: startedAt)
                    },
                    onFinalText: { [weak overlay] startedAt, text, replacesPreviousLine in
                        if replacesPreviousLine {
                            overlay?.replaceLastLine(startedAt: startedAt, text: text)
                        } else {
                            overlay?.append(startedAt: startedAt, text: text)
                        }
                    }
                )
                recordingSession = session
                isRunning = true
                updateStatusMessage(title: "VoiceShot started", message: "Recording speech")
                buildMenu()
            } catch {
                transcriptOverlay?.closeWithoutSaving()
                transcriptOverlay = nil
                showAlert(title: "Failed to start", message: error.localizedDescription)
            }
        }
    }

    @objc private func finish() {
        guard let recordingSession else { return }
        let overlay = transcriptOverlay
        Task {
            await recordingSession.stop()
            var completionMessage = "Close transcript window to save"

            switch speakerModelState {
            case .ready:
                self.updateStatusMessage(title: "VoiceShot stopped", message: "Identifying speakers")
                do {
                    if let speakerLabeledTranscript = try await recordingSession.speakerLabeledTranscript() {
                        overlay?.replaceTranscript(with: speakerLabeledTranscript)
                    }
                } catch {
                    NSLog("VoiceShot speaker diarization failed: \(error)")
                    completionMessage = "Speaker labels skipped; close transcript window to save"
                }
            case .preparing:
                completionMessage = "Speaker model still preparing; close transcript window to save"
            case .failed:
                completionMessage = "Speaker labels unavailable; close transcript window to save"
            }

            self.recordingSession = nil
            self.pendingTranscriptSession = recordingSession
            overlay?.enableCloseForSaving()
            self.isRunning = false
            self.updateStatusMessage(title: "VoiceShot stopped", message: completionMessage)
            self.buildMenu()
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
                if case .ready = speakerModelState {
                    do {
                        if let speakerLabeledTranscript = try await recordingSession.speakerLabeledTranscript() {
                            transcriptOverlay?.replaceTranscript(with: speakerLabeledTranscript)
                        }
                    } catch {
                        NSLog("VoiceShot speaker diarization failed: \(error)")
                    }
                }
                self.pendingTranscriptSession = recordingSession
                self.recordingSession = nil
                transcriptOverlay?.enableCloseForSaving()
            }
            if transcriptOverlay?.closeForSaving() == false {
                return
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
