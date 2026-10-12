//
//  SpatialAudio.swift
//  TomoTV
//
//  TrueHD Atmos and DTS:X converted to APAC (SpatialAudioBridge) on a grid of 3.2 s segments. Every
//  read generation feeds one session that starts on that grid, so generations line up sample for sample.
//

import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import SpatialAudioBridge

private let SWIFT_AV_NOPTS_VALUE = Int64(bitPattern: 0x8000_0000_0000_0000)

final class SpatialAudio {
    /// Two APAC sync periods of 75 packets, 3.2 s: every segment opens on a sync packet.
    static let segmentFrames: Int64 = 2 * 75 * 1024
    static let sampleRate = 48_000.0
    /// 7.1.4, the layout Apple TV's Atmos output carries, at the library's default rate.
    static let codecs = "apac.31.03"
    static let channels = 12
    static let bitRate = 3_072_000
    /// A restart for a segment seeks this much before it: audio sits near, not at, the video keyframe.
    static let seekLead = 1.0
    /// Audio a session takes without an error before the master may name APAC.
    static let verdictSeconds = 1.0
    /// Chunks handed to the transcoder at once, about 0.2 s each; the read loop waits past them.
    static let queuedChunks = 16

    /// What a library error means for the track: FLAC for the process, for this session, or a new session.
    enum Disposition: Equatable { case remember, refuse, newSession }

    let prefix: String
    let streamIndex: Int32
    let totalFrames: Int64
    private let trueHD: Bool
    private let priming: Int64
    private let dir: URL
    private let refusalKey: String

    private let lock = NSLock()
    private var completed: Set<Int> = []
    private var initWritten = false
    /// Bumped by every reset; fragments and errors of an older session are dropped.
    private var generation = 0
    /// The session's first grid index, once its opening sync packet arrived.
    private var first: Int?
    private var highest = -1
    private var accepted = false
    private var refusal: String?
    private var remembers = false
    private var jumped = false
    /// The input ended: no packet follows to open a new session on.
    private var finishing = false

    // Pipeline thread only.
    private var session: AnyObject?
    private var opensAtSessionStart = false
    /// After a timestamp jump, the grid index the replaced session left unfinished.
    private var resumeIndex: Int?
    private var inputStart = 0.0
    private var tail: Task<Void, Never>?
    private let slots = DispatchSemaphore(value: SpatialAudio.queuedChunks)
    private var chunk = Data()
    private var chunkStart: Double?

    private static let refusedLock = NSLock()
    /// Tracks this process carries as FLAC, and those only the next session does: it replaces one that failed on them.
    private static var refused: Set<String> = []
    private static var refusedNext: Set<String> = []

    /// TrueHD with an Atmos presentation, or DTS-HD MA, whose DTS:X FFmpeg cannot tell from plain
    /// (the library refuses plain as decoding starts), at 48 kHz on systems 26 and later, not over AirPlay.
    static func eligible(_ parameters: AVCodecParameters) -> Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, *), parameters.sample_rate == 48_000, !SpatialAudioOutput.externalPlayback else { return false }
        switch parameters.codec_id {
        case AV_CODEC_ID_TRUEHD: return parameters.profile == AV_PROFILE_TRUEHD_ATMOS
        case AV_CODEC_ID_DTS: return [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX].contains(parameters.profile)
        default: return false
        }
    }

    /// A converter for an eligible `stream`, unless this process carries the track as FLAC.
    static func make(stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32, prefix: String, inputUrl: String,
                     durationSeconds: Double, dir: URL) -> SpatialAudio? {
        let parameters = stream.pointee.codecpar.pointee
        let key = refusalKey(inputUrl: inputUrl, streamIndex: streamIndex)
        guard eligible(parameters), durationSeconds > 0, !refusedLock.withLock({ refused.contains(key) || refusedNext.remove(key) != nil }),
              #available(macOS 26, iOS 26, tvOS 26, *), let priming = try? APACConfiguration().encoderPrimingDuration() else { return nil }
        return SpatialAudio(prefix: prefix, streamIndex: streamIndex, trueHD: parameters.codec_id == AV_CODEC_ID_TRUEHD, priming: priming.value,
                            totalFrames: Int64((durationSeconds * sampleRate).rounded(.up)), dir: dir, refusalKey: key)
    }

    /// One track of one media source on one server, whatever credentials its URL carries: item ids
    /// repeat across servers, and a source's versions share the item's path.
    static func refusalKey(inputUrl: String, streamIndex: Int32) -> String {
        guard let url = URLComponents(string: inputUrl) else { return "\(inputUrl)#\(streamIndex)" }
        let source = url.queryItems?.first { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }?.value ?? ""
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? ["http": 80, "https": 443][scheme] ?? 0
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)\(url.path)?\(source)#\(streamIndex)"
    }

    static func disposition(of error: Error) -> Disposition {
        guard #available(macOS 26, iOS 26, tvOS 26, *), let error = error as? SpatialAudioError else { return .refuse }
        switch error {
        case .decoding, .invalidConfiguration: return .remember
        case .source: return .newSession
        default: return .refuse
        }
    }

    /// The conversion alone puts a segment below realtime: the track goes back to FLAC before a verdict.
    static func slowsSegment(produced: Double, converting: Double, segment: Double) -> Bool {
        converting > 0 && produced > segment && produced - converting <= segment
    }

    static func forgetRefusals() {
        refusedLock.withLock {
            refused.removeAll()
            refusedNext.removeAll()
        }
    }

    init(prefix: String, streamIndex: Int32, trueHD: Bool, priming: Int64, totalFrames: Int64, dir: URL, refusalKey: String) {
        self.prefix = prefix
        self.streamIndex = streamIndex
        self.trueHD = trueHD
        self.priming = priming
        self.totalFrames = totalFrames
        self.dir = dir
        self.refusalKey = refusalKey
    }

    var segmentCount: Int { Int((totalFrames + Self.segmentFrames - 1) / Self.segmentFrames) }
    var initName: String { "\(prefix)-init.mp4" }
    func segmentName(_ index: Int) -> String { "\(prefix)-seg\(index).m4s" }
    static func startSeconds(_ index: Int) -> Double { Double(Int64(index) * segmentFrames) / sampleRate }

    func segmentDurationSeconds(_ index: Int) -> Double {
        Double(min(Self.segmentFrames, totalFrames - Int64(index) * Self.segmentFrames)) / Self.sampleRate
    }

    /// The session has taken enough audio, or written a segment, for the master to name APAC.
    var isAccepted: Bool { lock.withLock { accepted } }
    /// Why the track went back to FLAC; terminal for this rendition.
    var failure: String? { lock.withLock { refusal } }

    func has(_ index: Int) -> Bool { lock.withLock { completed.contains(index) } }

    /// Whether the running session will reach `index` without a restart; nil while it has not opened.
    func covers(_ index: Int) -> Bool? {
        lock.withLock {
            guard let first else { return nil }
            return index >= first && index > highest
        }
    }

    /// Sends the track back to FLAC for a reason of the session's own, remembered for the process or not.
    func decline(_ reason: String, remembered: Bool = false) {
        lock.withLock {
            guard refusal == nil else { return }
            refusal = reason
            remembers = remembered
        }
    }

    /// A refusal that reopens the engine holds for the reopened session at least, so it cannot loop.
    func rememberRefusal(reopening: Bool) {
        let remembered = lock.withLock { remembers }
        guard remembered || reopening else { return }
        Self.refusedLock.withLock { _ = remembered ? Self.refused.insert(refusalKey) : Self.refusedNext.insert(refusalKey) }
    }

    /// A new read generation: the running session ends and its late fragments are dropped.
    func reset() {
        lock.withLock {
            generation += 1
            first = nil
            highest = -1
            jumped = false
            finishing = false
        }
        resumeIndex = nil
        cancelSession()
    }

    /// Where the generation's first video keyframe sits: at the session's start, a late first sync
    /// is padded with silence instead of opening a segment later.
    func open(atSessionStart: Bool) {
        opensAtSessionStart = atSessionStart
    }

    /// One packet of the selected track, its time already on the output timeline.
    func feed(_ pkt: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        guard let data = pkt.pointee.data, pkt.pointee.size > 0 else { return }
        if let resume = lock.withLock({ jumped ? max(first ?? 0, highest + 1) : nil }) {
            NSLog("[LocalRemuxer] spatial %@: the timestamps jumped, a new session takes over at seg%d", prefix, resume)
            reset()
            resumeIndex = resume
        }
        let bytes = Data(bytes: data, count: Int(pkt.pointee.size))
        let time = pkt.pointee.pts == SWIFT_AV_NOPTS_VALUE ? nil : Double(pkt.pointee.pts) * av_q2d(timeBase)
        if session == nil {
            guard lock.withLock({ refusal == nil }), let time, isSyncPoint(bytes) else { return }
            begin(at: time)
            guard session != nil else { return }
        }
        // About 0.2 s per append: the library judges the step between append times as a gap or not.
        if let start = chunkStart, let time, time - start >= 0.2 || time < start {
            send()
        } else if chunk.count >= 1 << 18 {
            send()
        }
        if chunk.isEmpty { chunkStart = time }
        chunk.append(bytes)
    }

    /// The input ended: the session pads to the playlist's end and delivers its last segments.
    func finish() {
        guard #available(macOS 26, iOS 26, tvOS 26, *), let transcoder = transcoder else { return }
        let jumpedAtEnd = lock.withLock { () -> Bool in
            finishing = true
            guard jumped, refusal == nil else { return false }
            refusal = "the timestamps jumped at the end of the input"
            return true
        }
        if jumpedAtEnd { NSLog("[LocalRemuxer] spatial %@ refused: the timestamps jumped at the end of the input", prefix) }
        send()
        let end = CMTime(value: totalFrames, timescale: CMTimeScale(Self.sampleRate))
        enqueue { _ = try await transcoder.finish(paddingTo: end) }
        session = nil
    }

    /// Ends conversion for good, as the session goes.
    func stop() {
        lock.withLock { generation += 1 }
        cancelSession()
    }

    /// Drops segments outside `seconds`, the time span the session keeps.
    func prune(outside seconds: ClosedRange<Double>) {
        let doomed: [Int] = lock.withLock {
            let outside = completed.filter {
                Self.startSeconds($0) + Self.startSeconds(1) < seconds.lowerBound || Self.startSeconds($0) > seconds.upperBound
            }
            completed.subtract(outside)
            return Array(outside)
        }
        for index in doomed { try? FileManager.default.removeItem(at: dir.appendingPathComponent(segmentName(index))) }
    }

    // MARK: - Sessions

    @available(macOS 26, iOS 26, tvOS 26, *)
    private var transcoder: SpatialAudioTranscoder? { session as? SpatialAudioTranscoder }

    private func isSyncPoint(_ bytes: Data) -> Bool {
        // A TrueHD major sync, or a DTS core sync.
        let head = [UInt8](bytes.prefix(8))
        if trueHD { return head.count == 8 && head[4...7] == [0xF8, 0x72, 0x6F, 0xBA] }
        return head.starts(with: [0x7F, 0xFE, 0x80, 0x01])
    }

    /// Opens a session at a sync packet. Its first segment is the first grid index whose audio, after
    /// the encoder's priming, the packet reaches, or after a jump the one left unfinished, padded to the packet.
    private func begin(at time: Double) {
        guard #available(macOS 26, iOS 26, tvOS 26, *) else { return }
        let frames = Int64((time * Self.sampleRate).rounded())
        let index = resumeIndex ?? (opensAtSessionStart ? 0 : max(0, Int((Double(frames - priming) / Double(Self.segmentFrames)).rounded(.up))))
        resumeIndex = nil
        var configuration = APACConfiguration(startTime: CMTime(value: Int64(index) * Self.segmentFrames + priming, timescale: 48_000),
                                              liveEncoding: true)
        configuration.inputStartTime = CMTime(value: frames, timescale: 48_000)
        let generation = lock.withLock {
            first = index
            return self.generation
        }
        do {
            session = try SpatialAudioTranscoder(codec: trueHD ? .trueHDAtmos : .dtsX, destination: .segments(onSegment: { [weak self] segment in
                self?.deliver(segment, generation: generation)
            }), configuration: configuration)
            inputStart = time
            NSLog("[LocalRemuxer] spatial %@: session from seg%d at %.3fs", prefix, index, time)
        } catch {
            refuse(error, generation: generation)
        }
    }

    private func send() {
        guard #available(macOS 26, iOS 26, tvOS 26, *), let transcoder = transcoder, !chunk.isEmpty else { return }
        let (data, start) = (chunk, chunkStart)
        chunk = Data()
        chunkStart = nil
        let reached = start.map { $0 - inputStart >= Self.verdictSeconds } ?? false
        let generation = lock.withLock { self.generation }
        enqueue {
            try await transcoder.append(data, time: start.map { CMTime(seconds: $0, preferredTimescale: 48_000) })
            if reached { self.lock.withLock { if self.generation == generation { self.accepted = true } } }
        }
    }

    /// Runs `work` after everything queued before it; the read loop waits while the queue is full.
    private func enqueue(_ work: @escaping () async throws -> Void) {
        slots.wait()
        let (previous, slots) = (tail, slots)
        let generation = lock.withLock { self.generation }
        tail = Task {
            defer { slots.signal() }
            await previous?.value
            do { try await work() } catch { self.refuse(error, generation: generation) }
        }
    }

    private func cancelSession() {
        // A finish still padding never yields to the session's cancel(); cancelling its task stops it.
        tail?.cancel()
        if #available(macOS 26, iOS 26, tvOS 26, *), let transcoder = transcoder {
            Task { await transcoder.cancel() }
        }
        session = nil
        chunk = Data()
        chunkStart = nil
    }

    private func refuse(_ error: Error, generation: Int) {
        guard !(error is CancellationError) else { return }
        let disposition = Self.disposition(of: error)
        let first = lock.withLock { () -> Bool in
            guard self.generation == generation, refusal == nil, !jumped else { return false }
            if disposition == .newSession, !finishing {
                jumped = true
                return false
            }
            refusal = String(describing: error)
            remembers = disposition == .remember
            return true
        }
        if first { NSLog("[LocalRemuxer] spatial %@ refused: %@", prefix, String(describing: error)) }
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func deliver(_ segment: APACSegment, generation: Int) {
        switch segment.kind {
        case .initialization:
            // Every session writes the same initialization apart from its creation time.
            guard lock.withLock({ self.generation == generation && !initWritten }),
                  (try? segment.data.write(to: dir.appendingPathComponent(initName), options: .atomic)) != nil else { return }
            lock.withLock { initWritten = true }
        case .media:
            guard let start = segment.startTime else { return }
            let index = Int((start.seconds * Self.sampleRate / Double(Self.segmentFrames)).rounded())
            guard lock.withLock({ self.generation == generation && first.map { index >= $0 } == true }),
                  (try? RemuxSession.writeSegment(segment.data, lead: RemuxSession.stypBox, to: dir.appendingPathComponent(segmentName(index)))) != nil
            else { return }
            lock.withLock {
                guard self.generation == generation else { return }
                completed.insert(index)
                highest = max(highest, index)
                accepted = true
            }
        }
    }
}

extension RemuxSession {
    static let spatialRebuildSeconds = 6.0

    func spatialRendition(_ prefix: String) -> SpatialAudio? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return renditions.first { $0.prefix == prefix }?.spatial
    }

    func withdrawSpatialAudio(_ reason: String) {
        stateLock.lock()
        let spatial = renditions.compactMap(\.spatial)
        stateLock.unlock()
        spatial.forEach { $0.decline(reason) }
    }

    /// Holds the master, within its budget, until every spatial rendition has taken audio or gone back
    /// to the transcoder, then fixes the ones it names APAC. `declining` withdraws them first.
    func awaitSpatialVerdict(declining reason: String? = nil) {
        if let reason {
            stateLock.lock()
            let spatial = spatialNamed ? [] : renditions.compactMap(\.spatial)
            stateLock.unlock()
            spatial.forEach { $0.decline(reason) }
        }
        _ = waitUntil(deadline: masterBudgetLeft()) { [weak self] in
            guard let self else { return true }
            stateLock.lock()
            defer { stateLock.unlock() }
            let settled = !spatialConverting && renditions.allSatisfy { $0.spatial.map { $0.isAccepted && $0.failure == nil } ?? true }
            return settled || failed || cancelled || !sourceReady || sourceReleased
        }
        // Past the budget a refused track still waits for its rebuild: until then its name serves the spatial playlist.
        _ = waitUntil(deadline: Self.spatialRebuildSeconds) { [weak self] in
            guard let self else { return true }
            stateLock.lock()
            defer { stateLock.unlock() }
            let rebuilt = spatialNamed || (!spatialConverting && !renditions.contains { $0.spatial?.failure != nil })
            return rebuilt || failed || cancelled || !sourceReady || sourceReleased
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !spatialNamed else { return }
        // Refused and not rebuilt yet: the transcoder takes it after this master, which names it from the config.
        for rendition in renditions where rendition.spatial?.failure != nil {
            resolvedAudioCodecs[rendition.prefix] = nil
            resolvedAudioChannels[rendition.prefix] = nil
        }
        spatialAnnounced = Set(resolvedAudioCodecs.filter { $0.value == SpatialAudio.codecs }.keys)
        spatialNamed = true
    }

    /// The spatial rendition's own playlist: the same total duration as the video, on its grid.
    func spatialPlaylist(_ spatial: SpatialAudio) -> String {
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n" + startTag
        out += "#EXT-X-TARGETDURATION:\(sessionTargetDuration())\n"
        out += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        out += "#EXT-X-MAP:URI=\"\(spatial.initName)\"\n"
        for index in 0..<spatial.segmentCount {
            out += String(format: "#EXTINF:%.6f,\n", spatial.segmentDurationSeconds(index))
            out += spatial.segmentName(index) + "\n"
        }
        return out + "#EXT-X-ENDLIST\n"
    }

    var spatialDurationSeconds: Double {
        let last = segmentCount - 1
        return segmentStartSeconds(last) + segmentDurationSeconds(last)
    }

    func spatialSegmentResponse(_ index: Int, _ spatial: SpatialAudio) -> LocalHTTPResponse {
        guard (0..<spatial.segmentCount).contains(index), !hasFailed, !isCancelled else { return .notFound }
        let file = dir.appendingPathComponent(spatial.segmentName(index))
        if spatial.has(index), FileManager.default.fileExists(atPath: file.path) { return .file(file, contentType: "audio/mp4") }
        // AVPlayer fails an audio segment it hears nothing from in 3.2 s (-12889, measured on Apple TV).
        return .segment(contentType: "audio/mp4", lead: Self.stypBox, padding: Self.freeBox) { [weak self] request in
            self?.spatialSegmentURL(index, spatial, request: request)
        }
    }

    /// Waits for a spatial segment. Production is counted on the video grid, so a segment the
    /// running session will not reach restarts the read at the video segment before its audio.
    func spatialSegmentURL(_ index: Int, _ spatial: SpatialAudio, request: SegmentRequest?) -> URL? {
        let start = SpatialAudio.startSeconds(index)
        let videoSegment = segmentIndex(atSeconds: start)
        let target = segmentIndex(atSeconds: max(0, start - SpatialAudio.seekLead))
        let file = dir.appendingPathComponent(spatial.segmentName(index))
        stateLock.lock()
        spatialWaiters += 1
        let ticket = spatialWaiters
        lastRequestedSegment = videoSegment
        if !sourceReleased { lastPrimaryDemandAt = Date() }
        activeWaiters[videoSegment, default: 0] += 1
        stateLock.unlock()
        defer {
            stateLock.lock()
            if let count = activeWaiters[videoSegment], count > 1 { activeWaiters[videoSegment] = count - 1 } else { activeWaiters[videoSegment] = nil }
            stateLock.unlock()
        }
        let deadline = Date().addingTimeInterval(20)
        var restarted = false
        var waitedSinceRestart = 0
        while Date() < deadline, request?.isAbandoned != true {
            stateLock.lock()
            // A source retry rebuilds the renditions: follow the instance serving this prefix now.
            let live = renditions.first { $0.prefix == spatial.prefix }?.spatial
            let dead = failed || cancelled || sourceUnusable
            let producing = producingSegment
            // A scrub leaves requests the player stopped waiting on; they must not drag the read.
            let newest = spatialWaiters == ticket
            let nearPlayhead = abs(videoSegment - lastRequestedSegment) <= aheadWindow
            stateLock.unlock()
            guard let live else { return nil }
            if live.has(index) { return FileManager.default.fileExists(atPath: file.path) ? file : nil }
            if dead || live.failure != nil { return nil }
            // A session opening after a restart is waited for before it is judged again, and only near
            // the playhead, as a video waiter re-asserts.
            let stranded = live.covers(index).map { !$0 } ?? false
            let ahead = videoSegment > producing + Self.seekAheadSegments
            if newest && (stranded || ahead) && (!restarted || (waitedSinceRestart >= 20 && nearPlayhead)) {
                stateLock.lock()
                pendingSpatialSeek = target
                playerBufferFilled = false
                stateLock.unlock()
                NSLog("[LocalRemuxer] spatial %@ seg%d restarts the read at segment %d", spatial.prefix, index, target)
                restarted = true
                waitedSinceRestart = 0
            }
            waitedSinceRestart += 1
            usleep(100_000)
        }
        NSLog("[LocalRemuxer] spatial %@ seg%d unserved", spatial.prefix, index)
        return nil
    }
}
