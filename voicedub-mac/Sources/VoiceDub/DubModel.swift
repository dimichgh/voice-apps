import Foundation
import SwiftUI
import AVFoundation
import CoreMedia

/// Orchestrates the dub pipeline and owns the redubbed AVPlayer.
///
/// Pipeline: extract audio → transcribe (timed segments) → optional per-segment
/// translation → per-segment TTS in the chosen voice → time-stretch each clip
/// to fill its source span (keeps A/V in sync) → assemble one audio track →
/// build an AVMutableComposition (original video + new audio) for playback.
@MainActor
final class DubModel: ObservableObject {
    @Published var videoURL: URL? = nil
    @Published var segments: [DubSegment] = []
    @Published var targetLanguage: String = AppModel.languages[0]   // "Off"
    @Published var isProcessing = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var error: String? = nil
    @Published var hasDub = false
    @Published var playingDubbed = true
    /// When set, clone the original speaker from the video's own audio and dub in
    /// that voice (the selected library voice is ignored). Ideal for translation:
    /// keep the speaker, change the language.
    @Published var useOriginalVoice = false
    /// When set, split the audio into vocals + background (Demucs) and mix the
    /// dub over the original background, so music & SFX are preserved. Also makes
    /// ASR, onset detection and the original-voice clone run on clean vocals.
    @Published var keepBackground = false
    /// Segment ids currently mid-operation (translating or re-voicing), so the
    /// editor can show per-row spinners and disable that row's buttons.
    @Published var busySegments: Set<Int> = []

    let player = AVPlayer()
    private var composition: AVMutableComposition? = nil
    private var dubbedAudioURL: URL? = nil
    private var workDir: URL? = nil
    /// Fitted (padded/stretched) WAV per segment id — the building blocks the
    /// dub track is assembled from. Editing a single segment replaces its entry
    /// and re-assembles, leaving the rest untouched.
    private var placedByID: [Int: URL] = [:]
    /// Source video duration, cached so re-assembly doesn't re-probe.
    private var totalDuration: Double = 0
    /// The speaker cloned from the video for the current dub (when
    /// `useOriginalVoice`). Stored so per-segment Re-voice reuses it instead of
    /// the library picker.
    private var originalVoice: VoicePreset? = nil
    /// The separated background (music/SFX) stem for the current dub, mixed under
    /// the new voice on every (re)assembly. Nil when separation is off.
    private var backgroundStem: URL? = nil
    /// The full original audio (44.1k stereo). With the background stem it forms
    /// the gated base: original in gaps, background under speech — preserving SFX
    /// dynamics where separation would otherwise bleed them. Nil when off.
    private var originalAudio: URL? = nil
    /// Monotonic counter for unique scratch filenames. Files accumulate in
    /// workDir for the session (the whole dir is removed on reset/regenerate) —
    /// we never delete one mid-edit, which would race a playing AVPlayer item.
    private var fileSeq = 0

    var translationEnabled: Bool { targetLanguage != AppModel.languages[0] }

    func pick(_ url: URL) {
        reset()
        videoURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        playingDubbed = false
    }

    func reset() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        segments = []; isProcessing = false; status = ""; progress = 0
        error = nil; hasDub = false; composition = nil; dubbedAudioURL = nil
        busySegments = []; placedByID = [:]; totalDuration = 0; fileSeq = 0
        originalVoice = nil; backgroundStem = nil; originalAudio = nil
        cleanupWorkDir()
    }

    // MARK: - Pipeline

    func generate(client: OmlxClient, voice: VoicePreset) async {
        guard let video = videoURL else { return }
        isProcessing = true; error = nil; hasDub = false; progress = 0
        // Start each run from a clean incremental state — stale entries from a
        // prior run (which may have had more/different segments) must not leak
        // into the new timeline.
        placedByID = [:]; fileSeq = 0; busySegments = []
        originalVoice = nil; backgroundStem = nil; originalAudio = nil
        let previousWork = workDir
        do {
            let work = try makeWorkDir()

            status = "Extracting audio…"; progress = 0.05
            let asrWav = work.appendingPathComponent("asr.wav")
            if keepBackground {
                guard Demucs.isAvailable else { throw Demucs.NotInstalled() }
                let full = work.appendingPathComponent("full.wav")
                try await FFmpeg.extractFullAudio(from: video, to: full)
                status = "Separating voice from background…"; progress = 0.08
                let stems = try await Demucs.separateVocals(
                    from: full, outDir: work.appendingPathComponent("stems"))
                backgroundStem = stems.background
                originalAudio = full
                // ASR, onset detection and the clone reference all run on the
                // clean isolated vocals — better transcripts and clone quality.
                try await FFmpeg.downmixForASR(from: stems.vocals, to: asrWav)
                DebugLog.log("separated vocals/background via Demucs")
            } else {
                try await FFmpeg.extractAudioForASR(from: video, to: asrWav)
            }
            let totalDur = try await FFmpeg.duration(of: video)
            totalDuration = totalDur

            status = "Transcribing…"; progress = 0.15
            let wavData = try Data(contentsOf: asrWav)
            let tr = try await client.transcribe(wav: wavData, language: nil)
            var segs = Self.buildSegments(from: tr, totalDuration: totalDur)
            // Whisper absorbs leading silence into a segment (the first line is
            // reported as starting at ~0), so the voice would begin too early.
            // Recover the true onset via silencedetect and trim each segment's
            // leading silence so the dub speaks exactly when the original does.
            if let silences = try? await FFmpeg.detectSilences(in: asrWav, totalDuration: totalDur) {
                let before = segs.map(\.start)
                segs = Self.trimLeadingSilence(segs, silences: silences)
                for (i, s) in segs.enumerated() where abs(s.start - before[i]) > 0.01 {
                    DebugLog.log(String(format: "segment %d start corrected %.2fs → %.2fs",
                                        i, before[i], s.start))
                }
                if silences.isEmpty {
                    DebugLog.log("silencedetect found no silence — timings left as-is (noisy/music audio?)")
                }
            }
            segments = segs

            if translationEnabled {
                for i in segs.indices {
                    status = "Translating \(i + 1)/\(segs.count)…"
                    segs[i].translatedText = try await client.translate(
                        text: segs[i].sourceText, targetLanguage: targetLanguage)
                    segments = segs
                    progress = 0.15 + 0.20 * Double(i + 1) / Double(max(segs.count, 1))
                }
            }

            // Pick the dub voice: clone the original speaker from the video when
            // requested (re-transcribe the clip so ref_text matches the audio —
            // leak-safe), otherwise the library voice the user selected.
            var effectiveVoice = voice
            if useOriginalVoice {
                status = "Cloning original voice…"; progress = 0.37
                if let span = Self.chooseReferenceSpan(segs, maxSeconds: FFmpeg.maxRefSeconds) {
                    let clip = work.appendingPathComponent("origref_\(nextSeq()).wav")
                    try await FFmpeg.extractClip(from: asrWav, start: span.start,
                                                 duration: span.end - span.start, to: clip)
                    let refData = try Data(contentsOf: clip)
                    let refText = try await client.transcribe(wav: refData, language: nil)
                        .text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !refText.isEmpty {
                        let v = VoicePreset(
                            id: "video-original", label: "Original speaker",
                            model: VoiceCatalog.omniModel,
                            kind: .omniCloned(refAudioPath: clip, refText: refText,
                                              description: "cloned from video"))
                        effectiveVoice = v
                        originalVoice = v
                        DebugLog.log(String(format: "original voice cloned from %.2f–%.2fs: \"%@\"",
                                            span.start, span.end, refText))
                    } else {
                        DebugLog.log("original-voice clone: empty transcript — using selected voice")
                    }
                } else {
                    DebugLog.log("original-voice clone: no usable reference span — using selected voice")
                }
            }

            for i in segs.indices {
                let voiced = segs[i].textToVoice
                guard !voiced.isEmpty else { continue }
                status = "Voicing \(i + 1)/\(segs.count)…"
                let raw = work.appendingPathComponent("seg_\(segs[i].id)_raw_\(nextSeq()).wav")
                let wav = try await client.tts(text: voiced, voice: effectiveVoice)
                try wav.write(to: raw, options: [.atomic])
                let fit = work.appendingPathComponent("seg_\(segs[i].id)_\(nextSeq()).wav")
                try await FFmpeg.fitToDuration(input: raw, target: segs[i].duration, output: fit)
                placedByID[segs[i].id] = fit
                segs[i].voicedText = voiced
                segments = segs
                progress = 0.40 + 0.45 * Double(i + 1) / Double(max(segs.count, 1))
            }

            status = "Assembling track…"; progress = 0.90
            let dubbed = work.appendingPathComponent("dubbed_\(nextSeq()).wav")
            try await FFmpeg.assemble(segments: placedFromSegments(),
                                      totalDuration: totalDur,
                                      background: backgroundStem,
                                      original: originalAudio,
                                      speechSpans: speechSpans(),
                                      output: dubbed)
            dubbedAudioURL = dubbed

            status = "Building player…"; progress = 0.96
            let comp = try await Self.makeComposition(video: video, audio: dubbed)
            composition = comp
            player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
            playingDubbed = true
            hasDub = true
            status = "Done — \(segs.count) segments"; progress = 1.0
            // Old run's files are now unreferenced — safe to remove.
            if let previousWork, previousWork != work {
                try? FileManager.default.removeItem(at: previousWork)
            }
        } catch {
            self.error = error.localizedDescription
            status = "Failed"
        }
        isProcessing = false
    }

    // MARK: - Per-segment editing (feature 7)

    /// Re-translate a single segment's (possibly edited) source text. No-op when
    /// translation is off. The result lands in `translatedText`; the row goes
    /// stale until the user re-voices it.
    func retranslate(_ id: Int, client: OmlxClient) async {
        guard translationEnabled,
              let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let source = segments[idx].sourceText
        busySegments.insert(id); error = nil
        do {
            let t = try await client.translate(text: source, targetLanguage: targetLanguage)
            if let i = segments.firstIndex(where: { $0.id == id }) {
                segments[i].translatedText = t
            }
        } catch {
            self.error = error.localizedDescription
        }
        busySegments.remove(id)
    }

    /// Re-voice a single segment with the given voice, then re-assemble the dub
    /// track in place (the other segments' audio is reused untouched). Playhead
    /// and dubbed/original selection are preserved across the swap.
    func revoice(_ id: Int, client: OmlxClient, voice: VoicePreset) async {
        guard let work = workDir,
              let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[idx]
        // Snapshot the text BEFORE the await — if the user keeps editing during
        // TTS, we must stamp voicedText with what we actually voiced, not the
        // newer text (else the stale row would wrongly look fresh).
        let voiced = seg.textToVoice
        // Match the dub: reuse the cloned original speaker when that mode is on.
        let useVoice = useOriginalVoice ? (originalVoice ?? voice) : voice
        busySegments.insert(id); error = nil
        do {
            if voiced.isEmpty {
                // Nothing to say now — drop this segment from the mix.
                placedByID[id] = nil
            } else {
                let raw = work.appendingPathComponent("seg_\(id)_raw_\(nextSeq()).wav")
                let wav = try await client.tts(text: voiced, voice: useVoice)
                try wav.write(to: raw, options: [.atomic])
                let fit = work.appendingPathComponent("seg_\(id)_\(nextSeq()).wav")
                try await FFmpeg.fitToDuration(input: raw, target: seg.duration, output: fit)
                placedByID[id] = fit
            }
            if let i = segments.firstIndex(where: { $0.id == id }) {
                segments[i].voicedText = voiced
            }
            try await reassemble()
        } catch {
            self.error = error.localizedDescription
        }
        busySegments.remove(id)
    }

    /// Re-voice every stale segment (text edited since last voiced), one by one.
    func revoiceStale(client: OmlxClient, voice: VoicePreset) async {
        for seg in segments where seg.needsRevoice {
            await revoice(seg.id, client: client, voice: voice)
        }
    }

    /// Rebuild the dub track from the current `placedByID` and swap the player's
    /// composition, preserving the current time and play state.
    private func reassemble() async throws {
        guard let video = videoURL else { return }
        fileSeq += 1
        let dubbed = workDir!.appendingPathComponent("dubbed_\(fileSeq).wav")
        try await FFmpeg.assemble(segments: placedFromSegments(),
                                  totalDuration: totalDuration,
                                  background: backgroundStem,
                                  original: originalAudio,
                                  speechSpans: speechSpans(),
                                  output: dubbed)
        dubbedAudioURL = dubbed
        let comp = try await Self.makeComposition(video: video, audio: dubbed)
        composition = comp
        hasDub = true
        // Only swap the live item if the dubbed track is what's showing.
        if playingDubbed {
            let t = player.currentTime()
            let wasPlaying = player.rate > 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
            await player.seek(to: t)
            if wasPlaying { player.play() }
        }
    }

    /// The fitted segment audio currently driving the dub for `id` (for preview).
    func segmentAudioURL(_ id: Int) -> URL? { placedByID[id] }

    /// Ordered `(start, url)` list for assembly, in segment order, skipping
    /// segments with no audio.
    private func placedFromSegments() -> [(start: Double, url: URL)] {
        segments.compactMap { seg in
            placedByID[seg.id].map { (seg.start, $0) }
        }
    }

    /// Spans (seconds) where the original voice plays — i.e. where the background
    /// stem (not the full original) must be used so the dub replaces the voice.
    private func speechSpans() -> [(start: Double, end: Double)] {
        segments.map { ($0.start, $0.end) }
    }

    private func nextSeq() -> Int { fileSeq += 1; return fileSeq }

    // MARK: - Playback switching

    func showDubbed() {
        guard let comp = composition else { return }
        let t = player.currentTime()
        player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
        player.seek(to: t)
        playingDubbed = true
    }

    func showOriginal() {
        guard let url = videoURL else { return }
        let t = player.currentTime()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: t)
        playingDubbed = false
    }

    // MARK: - Export (passthrough — no video re-encode)

    func export(to output: URL) async throws {
        guard let comp = composition else {
            throw FFmpeg.ToolError(message: "Nothing to export yet — generate a dub first.")
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw FFmpeg.ToolError(message: "Could not create export session.")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mov   // .mov accepts the lossless PCM audio track
        await session.export()
        if session.status != .completed {
            throw session.error ?? FFmpeg.ToolError(message: "Export failed (\(session.status.rawValue)).")
        }
    }

    // MARK: - Helpers

    private func makeWorkDir() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDub", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workDir = base
        return base
    }

    /// Remove the current run's scratch dir (called when tearing down — the
    /// composition/player no longer reference it).
    private func cleanupWorkDir() {
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }

    /// Move each segment's start forward to the end of any silence interval that
    /// covers its (Whisper-reported) start — i.e. trim leading silence Whisper
    /// folded in. Only ever moves a start forward, bounded so it can't cross the
    /// segment's own end, so ordering stays monotonic and speech is never cut.
    static func trimLeadingSilence(_ segs: [DubSegment],
                                   silences: [(start: Double, end: Double)]) -> [DubSegment] {
        guard !silences.isEmpty else { return segs }
        let minLead = 0.3     // ignore trivially-short leading silence
        let minSpeech = 0.2   // keep at least this much of the span as speech
        return segs.map { seg in
            guard let sil = silences.first(where: {
                $0.start <= seg.start + 0.05 &&        // silence begins at/before the start
                $0.end >= seg.start + minLead &&       // …and extends meaningfully past it
                $0.end <= seg.end - minSpeech          // …without swallowing the whole span
            }) else { return seg }
            return DubSegment(id: seg.id, start: sil.end, end: seg.end,
                              sourceText: seg.sourceText,
                              translatedText: seg.translatedText,
                              voicedText: seg.voicedText)
        }
    }

    /// Pick the contiguous run of segments that packs the most speech into a
    /// `maxSeconds` window — the best cloning reference for the original speaker.
    /// Returns the `[start, end]` span (the clip is re-transcribed for ref_text).
    /// Falls back to the first `maxSeconds` of speech if every segment is longer
    /// than the window.
    static func chooseReferenceSpan(_ segs: [DubSegment], maxSeconds: Double)
        -> (start: Double, end: Double)? {
        guard !segs.isEmpty else { return nil }
        var best: (start: Double, end: Double, score: Double)? = nil
        for i in segs.indices {
            let start = segs[i].start
            var score = 0.0
            var j = i
            while j < segs.count, segs[j].end - start <= maxSeconds {
                score += segs[j].duration
                if best == nil || score > best!.score {
                    best = (start, segs[j].end, score)
                }
                j += 1
            }
        }
        if let b = best { return (b.start, b.end) }
        // Every segment exceeds the window — take the first maxSeconds of speech.
        let first = segs[0]
        return (first.start, min(first.end, first.start + maxSeconds))
    }

    static func buildSegments(from tr: OmlxTranscription, totalDuration: Double) -> [DubSegment] {
        if let segs = tr.segments, !segs.isEmpty {
            var out: [DubSegment] = []
            for (i, s) in segs.enumerated() {
                let text = (s.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = max(0, s.start ?? 0)
                let end = min(totalDuration > 0 ? totalDuration : .greatestFiniteMagnitude,
                              s.end ?? (start + 2))
                out.append(DubSegment(id: i, start: start, end: max(end, start + 0.1),
                                      sourceText: text))
            }
            if !out.isEmpty { return out }
        }
        // Fallback: one segment spanning the whole clip.
        let whole = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        return [DubSegment(id: 0, start: 0,
                           end: totalDuration > 0 ? totalDuration : 5,
                           sourceText: whole)]
    }

    static func makeComposition(video: URL, audio: URL) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)

        let vTracks = try await vAsset.loadTracks(withMediaType: .video)
        let vDur = try await vAsset.load(.duration)
        guard let vTrack = vTracks.first,
              let compV = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FFmpeg.ToolError(message: "No video track found in the source file.")
        }
        try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)
        compV.preferredTransform = try await vTrack.load(.preferredTransform)

        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
        if let aTrack = aTracks.first,
           let compA = comp.addMutableTrack(withMediaType: .audio,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = try await aAsset.load(.duration)
            let dur = CMTimeMinimum(vDur, aDur)
            try compA.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aTrack, at: .zero)
        }
        return comp
    }
}
