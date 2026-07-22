import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import FFmpegHeaders
import FFmpegCBridge

// MARK: - Public Types

@objc public enum PlayerState: Int {
    case initialized    = 0
    case preparing      = 1
    case readyToPlay    = 2
    case buffering      = 3
    case bufferFinished = 4
    case paused         = 5
    case playedToTheEnd = 6
    case error          = 7
    case stop           = 8
}

@objc public protocol DecoderDelegate: AnyObject {
    func receivedDecodedCIImage(_ ciImage: CIImage)
    func receivedCurrentTime(_ currentTime: Int64, duration: Int64)
    func receivedState(_ state: PlayerState)
    func receivedSeekingState(_ success: Bool)
    func receivedVideoSize(_ videoSize: CGSize)
}

// MARK: - FFmpegDecoder

@objc public final class FFmpegDecoder: NSObject {

    private static let version = "1.0.6"

    @objc public weak var delegate: (any DecoderDelegate)?
    @objc public var engine: AVAudioEngine?
    @objc public var player: AVAudioPlayerNode?
    private var varispeedNode: AVAudioUnitVarispeed?
    private var playbackRate: Double = 1.0

    // FFmpeg C context pointers
    private var swsCtx: OpaquePointer?
    private var pFormatContext: UnsafeMutablePointer<AVFormatContext>?
    private var pVCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pACtx: UnsafeMutablePointer<AVCodecContext>?
    private var pVStream: UnsafeMutablePointer<AVStream>?
    private var pAStream: UnsafeMutablePointer<AVStream>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var vFrame: UnsafeMutablePointer<AVFrame>?
    private var aFrame: UnsafeMutablePointer<AVFrame>?
    private var outputFrameSize: CGSize = .zero

    // Pixel format buffers
    private var dst_data = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
    private var dst_linesize = [Int32](repeating: 0, count: 4)

    private var vidx: Int32 = -1
    private var aidx: Int32 = -1

    // Per-instance interrupt flag — heap-allocated so its address stays stable across calls
    // and is not shared between decoder instances (unlike a file-level global).
    private let stoppedFlag = UnsafeMutablePointer<CBool>.allocate(capacity: 1)

    // Playback state
    private var decodingStopped = false
    private var isPaused = false
    private var isPlayingInternal = true
    private var isSeeking = false
    private var seekTarget: Double = 0
    private var hasPendingSeek = false
    private var hasEverSeeked = false
    private var pendingSeekSeconds: Double = 0
    private var needLog = false
    private var needInterrupt = false
    private let pauseCondition = NSCondition()
    private var lastRescaledPTS: Int64 = -1
    private var ptsOffset: Int64 = 0
    private var currentState: Int = 0

    // PTS-based frame timing for non-RTSP sources (file://, http://)
    private var sourceURL: String = ""
    private var frameStartWallTime: Double = 0
    private var frameStartPTS: Double = -1

    // RTSP PAUSE/PLAY 중복 전송 방지
    private var rtspPaused = false

    private let decodingQueue = DispatchQueue.global(qos: .default)

    @objc public override init() {
        stoppedFlag.initialize(to: false)
        super.init()
    }

    deinit {
        stopDecoding()
        clearResources()
        stoppedFlag.deallocate()
    }

    // MARK: - Public API

    @objc public func startStreaming(_ url: String,
                                     withOptions options: [String: String],
                                     needLog: Bool,
                                     needInterrupt: Bool) {
        stoppedFlag.pointee = false
        decodingStopped = false
        self.needLog = needLog
        self.needInterrupt = needInterrupt
        sourceURL = url
        frameStartPTS = -1
        frameStartWallTime = 0
        rtspPaused = false
        decodingQueue.async { [weak self] in
            self?.openFile(url, options: options)
        }
    }

    @objc public func stopDecoding() {
        log("FFmpeg## stopDecoding")
        pauseCondition.lock()
        let shouldNotify = !decodingStopped && currentState != 0
        decodingStopped = true
        stoppedFlag.pointee = true
        pauseCondition.signal()
        pauseCondition.unlock()
        if shouldNotify { sendState(.stop) }
    }

    @objc public func pause() {
        decodingQueue.async { [weak self] in
            guard let self else { return }
            pauseCondition.lock()
            isPaused = true
            pauseCondition.unlock()
        }
    }

    @objc public func resume() {
        decodingQueue.async { [weak self] in
            guard let self else { return }
            pauseCondition.lock()
            isPaused = false
            pauseCondition.signal()
            pauseCondition.unlock()
        }
    }

    @objc public func seek(_ seconds: Double) {
        decodingQueue.async { [weak self] in
            guard let self else { return }
            log("FFmpeg## isSeeking")
            pauseCondition.lock()
            seekTarget = seconds
            isSeeking = true
            pauseCondition.signal()
            pauseCondition.unlock()
        }
    }

    @objc public func isPlaying() -> Bool {
        return !isPaused
    }

    @objc public func setPlaybackRate(_ rate: Double) {
        varispeedNode?.rate = Float(rate)
        decodingQueue.async { [weak self] in
            self?.playbackRate = rate
            self?.frameStartPTS = -1
        }
    }

    // MARK: - Logging

    @objc public func log(_ text: String) {
        NSLog("%@", text)
        guard needLog else { return }

        let now = Date()
        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HH"
        let fileName = fileFormatter.string(from: now) + ".txt"

        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = docsURL.appendingPathComponent(fileName)

        let tsFormatter = DateFormatter()
        tsFormatter.dateFormat = "HH:mm:ss"
        let logLine = "[\(tsFormatter.string(from: now))] \(text)\n"
        guard let logData = logLine.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(logData)
                handle.closeFile()
            }
        } else {
            try? logData.write(to: fileURL)
        }
    }

    // MARK: - Private: Open

    private func openFile(_ url: String, options: [String: String]) {
        log("FFmpeg## SPM Version: \(FFmpegDecoder.version)")
        log("FFmpeg## openFile: \(url)")

        if currentState != 0 { sendState(.stop) }
        ffmpeg_setup_log_callback()
        av_log_set_level(AV_LOG_DEBUG)
        avformat_network_init()

        pFormatContext = avformat_alloc_context()
        if needInterrupt {
            pFormatContext?.pointee.interrupt_callback.callback = ffmpeg_interrupt_check
            pFormatContext?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(stoppedFlag)
        }

        var opts: OpaquePointer? = nil
        for (key, value) in options {
            key.withCString { keyPtr in
                value.withCString { valuePtr in
                    _ = av_dict_set(&opts, keyPtr, valuePtr, 0)
                }
            }
        }

        var ret = url.withCString { avformat_open_input(&pFormatContext, $0, nil, &opts) }

        if ret != 0 {
            log("FFmpeg## File Open Failed")
            stopDecoding()
            if currentState != 7 { sendState(.error) }
            return
        }

        let maxRetry = 3
        for i in 0..<maxRetry {
            ret = avformat_find_stream_info(pFormatContext, nil)

            var hasVideoParams = false
            if let ctx = pFormatContext {
                for s in 0..<Int(ctx.pointee.nb_streams) {
                    if let stream = ctx.pointee.streams[s],
                       let par = stream.pointee.codecpar,
                       par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                       par.pointee.width > 0, par.pointee.height > 0 {
                        hasVideoParams = true
                        break
                    }
                }
            }

            if hasVideoParams {
                log("FFmpeg## Stream info found on attempt \(i + 1)")
                break
            }

            log("FFmpeg## Retrying find_stream_info (\(i + 1)/\(maxRetry))...")
            avformat_close_input(&pFormatContext)
            pFormatContext = avformat_alloc_context()
            pFormatContext?.pointee.interrupt_callback.callback = ffmpeg_interrupt_check
            pFormatContext?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(stoppedFlag)

            ret = url.withCString { avformat_open_input(&pFormatContext, $0, nil, &opts) }
            if ret != 0 { break }
        }

        if ret < 0 {
            log("FFmpeg## Fail to get Stream Info")
            stopDecoding()
            return
        }

        openCodec()
    }

    private func openCodec() {
        vidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        aidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_AUDIO, -1, vidx, nil, 0)

        if vidx >= 0 {
            pVStream = pFormatContext?.pointee.streams[Int(vidx)]
            guard let pVPara = pVStream?.pointee.codecpar else {
                if currentState != 7 { sendState(.error) }
                return
            }
            log("FFmpeg## 비디오 codec_id: \(pVPara.pointee.codec_id.rawValue) (\(String(cString: avcodec_get_name(pVPara.pointee.codec_id))))")

            guard let vCodec = avcodec_find_decoder(pVPara.pointee.codec_id) else {
                log("FFmpeg## 비디오 코덱을 찾을 수 없습니다. codec_id = \(pVPara.pointee.codec_id.rawValue)")
                if currentState != 7 { sendState(.error) }
                return
            }
            pVCtx = avcodec_alloc_context3(vCodec)
            avcodec_parameters_to_context(pVCtx, pVPara)
            avcodec_open2(pVCtx, vCodec, nil)
            log("FFmpeg## 비디오 코덱: \(vCodec.pointee.id.rawValue), \(String(cString: vCodec.pointee.name))")
        }

        if aidx >= 0 {
            pAStream = pFormatContext?.pointee.streams[Int(aidx)]
            guard let pAPara = pAStream?.pointee.codecpar else {
                if currentState != 7 { sendState(.error) }
                return
            }
            log("FFmpeg## 오디오 codec_id: \(pAPara.pointee.codec_id.rawValue) (\(String(cString: avcodec_get_name(pAPara.pointee.codec_id))))")

            guard let aCodec = avcodec_find_decoder(pAPara.pointee.codec_id) else {
                log("FFmpeg## 오디오 코덱을 찾을 수 없습니다. codec_id = \(pAPara.pointee.codec_id.rawValue)")
                if currentState != 7 { sendState(.error) }
                return
            }
            pACtx = avcodec_alloc_context3(aCodec)
            avcodec_parameters_to_context(pACtx, pAPara)
            avcodec_open2(pACtx, aCodec, nil)
            log("FFmpeg## 오디오 코덱: \(aCodec.pointee.id.rawValue), \(String(cString: aCodec.pointee.name))")
        }

        decoding()
    }

    // MARK: - Private: Decode loop

    private func decoding() {
        if currentState != 1 { sendState(.preparing) }

        vFrame = av_frame_alloc()
        aFrame = av_frame_alloc()
        packet = av_packet_alloc()

        if let vCtx = pVCtx {
            outputFrameSize = CGSize(width: CGFloat(vCtx.pointee.width), height: CGFloat(vCtx.pointee.height))
        }
        log("FFmpeg## Video Resolution: \(Int(outputFrameSize.width)) x \(Int(outputFrameSize.height))")

        while !decodingStopped, pFormatContext != nil {
            if currentState != 2 { sendState(.readyToPlay) }

            while !decodingStopped, let pkt = packet, readFrame(pkt) >= 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    delegate?.receivedVideoSize(outputFrameSize)
                }

                pauseCondition.lock()
                if !decodingStopped && isPaused {
                    if isPlayingInternal {
                        _ = readPause()
                        if player?.isPlaying == true { player?.pause() }
                    }
                }
                while !decodingStopped && isPaused {
                    if isSeeking {
                        log("FFmpeg## readSeek")
                        isSeeking = false
                        _ = readSeek(seekTarget)
                    }
                    pauseCondition.wait()
                }
                pauseCondition.unlock()

                if !isPlayingInternal {
                    _ = readPlay()
                    if currentState != 2 { sendState(.readyToPlay) }
                    avcodec_flush_buffers(pVCtx)
                    frameStartPTS = -1
                }

                guard let pkt = packet else { continue }

                if pkt.pointee.stream_index == vidx, let vCtx = pVCtx, let vF = vFrame {
                    if avcodec_send_packet(vCtx, pkt) >= 0,
                       avcodec_receive_frame(vCtx, vF) >= 0 {
                        if let vStream = pVStream {
                            getCurrentTime(vF, stream: vStream)
                            throttleVideo(frame: vF, stream: vStream)
                        }
                        drawImage()
                    }
                }
                if pkt.pointee.stream_index == aidx, let aCtx = pACtx, let aF = aFrame {
                    if avcodec_send_packet(aCtx, pkt) >= 0 {
                        while avcodec_receive_frame(aCtx, aF) == 0 {
                            drawAudio()
                        }
                    }
                }
                av_packet_unref(pkt)
            }
        }
        clearResources()
    }

    // MARK: - Private: Decode helpers

    @discardableResult
    private func readFrame(_ pkt: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard pFormatContext != nil else { return -1 }
        let ret = av_read_frame(pFormatContext, pkt)
        if ret == kFFmpegErrorEOF {
            log("FFmpeg## readFrame EOF")
            stopDecoding()
            if currentState != 6 { sendState(.playedToTheEnd) }
        }
        return ret
    }

    @discardableResult
    private func readPlay() -> Int32 {
        log("FFmpeg## readPlay")
        isPlayingInternal = true
        if currentState != 4 { sendState(.bufferFinished) }
        guard sourceURL.hasPrefix("rtsp"), rtspPaused else { return 0 }
        rtspPaused = false
        let ret = av_read_play(pFormatContext)
        if ret < 0 {
            log("FFmpeg## av_read_play error \(ret)")
            if currentState != 7 { sendState(.error) }
        } else {
            log("FFmpeg## av_read_play: \(ret)")
            if currentState != 4 { sendState(.bufferFinished) }
        }
        return ret
    }

    @discardableResult
    private func readPause() -> Int32 {
        log("FFmpeg## readPause")
        isPlayingInternal = false
        if currentState != 5 { sendState(.paused) }
        guard sourceURL.hasPrefix("rtsp"), !rtspPaused else { return 0 }
        rtspPaused = true
        let ret = av_read_pause(pFormatContext)
        if ret < 0 {
            log("FFmpeg## av_read_pause error \(ret)")
            if currentState != 7 { sendState(.error) }
        } else {
            log("FFmpeg## av_read_pause: \(ret)")
            if currentState != 5 { sendState(.paused) }
        }
        return ret
    }

    @discardableResult
    private func readSeek(_ seconds: Double) -> Int32 {
        guard seconds >= 0, pFormatContext != nil else {
            log("FFmpeg## Invalid seek time or context is NULL")
            if currentState != 7 { sendState(.error) }
            return -1
        }

        lastRescaledPTS = -1
        ptsOffset = 0
        hasPendingSeek = true
        pendingSeekSeconds = seconds
        frameStartPTS = -1  // seek 후 타이밍 기준점 리셋

        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        avcodec_flush_buffers(pVCtx)
        avcodec_flush_buffers(pACtx)

        let ret = av_seek_frame(pFormatContext, -1, timestamp,
                                AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY)
        log("FFmpeg## av_seek_frame to \(String(format: "%.2f", seconds)) sec (ts: \(timestamp)): \(ret)")

        if ret < 0 {
            log("FFmpeg## Seek failed")
            if currentState != 7 { sendState(.error) }
            hasPendingSeek = false
        } else {
            hasEverSeeked = true
            DispatchQueue.main.sync { [weak self] in
                self?.delegate?.receivedSeekingState(true)
            }
        }
        return ret
    }

    // MARK: - Private: Time / Video / Audio

    private func getCurrentTime(_ frame: UnsafeMutablePointer<AVFrame>,
                                 stream: UnsafeMutablePointer<AVStream>) {
        if hasEverSeeked {
            let totalDuration = (pFormatContext?.pointee.duration ?? 0) / Int64(AV_TIME_BASE)
            let rawPts = frame.pointee.pts != kFFmpegNoPTSValue
                ? frame.pointee.pts
                : frame.pointee.best_effort_timestamp

            let currentTime: Int64
            if rawPts == kFFmpegNoPTSValue {
                currentTime = lastRescaledPTS != -1 ? (lastRescaledPTS + ptsOffset) : 0
            } else {
                let rescaled = rescaleQ(rawPts, stream.pointee.time_base,
                                        AVRational(num: 1, den: 1))
                if hasPendingSeek {
                    ptsOffset = Int64(pendingSeekSeconds) - rescaled
                    lastRescaledPTS = rescaled
                    hasPendingSeek = false
                } else {
                    if lastRescaledPTS != -1 && rescaled < lastRescaledPTS {
                        ptsOffset += lastRescaledPTS
                    }
                    lastRescaledPTS = rescaled
                }
                currentTime = rescaled + ptsOffset
            }

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.receivedCurrentTime(currentTime, duration: totalDuration)
            }
        } else {
            guard frame.pointee.pkt_dts != 0 || frame.pointee.pts != 0 else { return }
            let pts = frame.pointee.pts == kFFmpegNoPTSValue
                ? frame.pointee.pkt_dts
                : frame.pointee.pts
            guard pts != kFFmpegNoPTSValue else { return }

            var currentTime = rescaleQ(pts, stream.pointee.time_base,
                                       AVRational(num: 1, den: 1000))
            var duration: Int64 = 0
            if let ctx = pFormatContext, ctx.pointee.duration > 0 {
                duration = rescaleQ(ctx.pointee.duration,
                                    AVRational(num: 1, den: Int32(AV_TIME_BASE)),
                                    AVRational(num: 1, den: 1000))
            }
            currentTime /= 1000
            duration /= 1000

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.receivedCurrentTime(currentTime, duration: duration)
            }
        }
    }

    private func drawImage() {
        guard !decodingStopped, let vF = vFrame, let vCtx = pVCtx else { return }

        let width = vF.pointee.width
        let height = vF.pointee.height

        if swsCtx == nil {
            swsCtx = sws_getContext(
                vCtx.pointee.width, vCtx.pointee.height, vCtx.pointee.pix_fmt,
                Int32(outputFrameSize.width), Int32(outputFrameSize.height),
                AV_PIX_FMT_RGBA, SWS_FAST_BILINEAR, nil, nil, nil
            )
            dst_data.withUnsafeMutableBufferPointer { dataBuf in
                dst_linesize.withUnsafeMutableBufferPointer { sizeBuf in
                    _ = av_image_alloc(dataBuf.baseAddress, sizeBuf.baseAddress,
                                       vCtx.pointee.width, vCtx.pointee.height,
                                       AV_PIX_FMT_RGBA, 1)
                }
            }
        }

        // Extract frame data pointers from the fixed-size tuple
        var srcData = [UnsafePointer<UInt8>?](repeating: nil, count: 8)
        withUnsafeBytes(of: vF.pointee.data) { raw in
            let ptrs = raw.bindMemory(to: UnsafePointer<UInt8>?.self)
            for i in 0..<min(8, ptrs.count) { srcData[i] = ptrs[i] }
        }
        var srcStride = [Int32](repeating: 0, count: 8)
        withUnsafeBytes(of: vF.pointee.linesize) { raw in
            let sizes = raw.bindMemory(to: Int32.self)
            for i in 0..<min(8, sizes.count) { srcStride[i] = sizes[i] }
        }

        srcData.withUnsafeBufferPointer { srcBuf in
            srcStride.withUnsafeBufferPointer { strideBuf in
                dst_data.withUnsafeBufferPointer { dstBuf in
                    dst_linesize.withUnsafeBufferPointer { dstStrideBuf in
                        _ = sws_scale(swsCtx, srcBuf.baseAddress, strideBuf.baseAddress,
                                      0, height, dstBuf.baseAddress, dstStrideBuf.baseAddress)
                    }
                }
            }
        }

        guard let firstPtr = dst_data[0] else { return }
        let linesize = dst_linesize[0]
        let imageData = Data(bytes: firstPtr, count: Int(linesize) * Int(height))

        DispatchQueue.main.async { [weak self] in
            guard let self, !decodingStopped else { return }
            let ci = CIImage(bitmapData: imageData,
                             bytesPerRow: Int(linesize),
                             size: CGSize(width: Int(width), height: Int(height)),
                             format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            delegate?.receivedDecodedCIImage(ci)
        }
    }

    private func drawAudio() {
        guard !decodingStopped, let aF = aFrame, let aCtx = pACtx else { return }

        let sampleFmt = aCtx.pointee.sample_fmt
        let nbSamples = Int(aF.pointee.nb_samples)
        let nbChannels = Int(aCtx.pointee.ch_layout.nb_channels)
        let sampleRate = Double(aF.pointee.sample_rate)

        guard nbSamples > 0, nbChannels > 0 else { return }

        let channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   interleaved: false,
                                   channelLayout: channelLayout)

        if engine == nil || engine?.isRunning != true {
            let eng = AVAudioEngine()
            let pNode = AVAudioPlayerNode()
            pNode.volume = 1.0
            let vsNode = AVAudioUnitVarispeed()
            vsNode.rate = Float(playbackRate)
            engine = eng
            player = pNode
            varispeedNode = vsNode
            eng.attach(pNode)
            eng.attach(vsNode)
            eng.connect(pNode, to: vsNode, format: format)
            eng.connect(vsNode, to: eng.mainMixerNode, format: format)
            eng.prepare()
            do {
                try eng.start()
            } catch {
                log("FFmpeg## AVAudioEngine start failed: \(error)")
                engine = nil
                player = nil
                return
            }
            pNode.play()
        } else if player?.isPlaying != true {
            player?.play()
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(nbSamples))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(nbSamples)
        guard let outChannels = pcmBuffer.floatChannelData else { return }

        // Extract per-plane data pointers from AVFrame's fixed-size tuple
        var srcPlanes = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 8)
        withUnsafeBytes(of: aF.pointee.data) { raw in
            let ptrs = raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)
            for i in 0..<min(8, ptrs.count) { srcPlanes[i] = ptrs[i] }
        }

        let isPlanar = av_sample_fmt_is_planar(sampleFmt) != 0

        // Fill stereo output; mono input is duplicated to both channels
        for outCh in 0..<2 {
            let srcCh = min(outCh, nbChannels - 1)
            let planeIdx = isPlanar ? srcCh : 0
            guard let plane = srcPlanes[planeIdx] else { continue }

            switch sampleFmt {
            case AV_SAMPLE_FMT_FLTP:
                plane.withMemoryRebound(to: Float.self, capacity: nbSamples) { src in
                    outChannels[outCh].update(from: src, count: nbSamples)
                }
            case AV_SAMPLE_FMT_S16P:
                plane.withMemoryRebound(to: Int16.self, capacity: nbSamples) { src in
                    for i in 0..<nbSamples { outChannels[outCh][i] = Float(src[i]) / 32768.0 }
                }
            case AV_SAMPLE_FMT_FLT:
                plane.withMemoryRebound(to: Float.self, capacity: nbSamples * nbChannels) { src in
                    for i in 0..<nbSamples { outChannels[outCh][i] = src[i * nbChannels + srcCh] }
                }
            case AV_SAMPLE_FMT_S16:
                plane.withMemoryRebound(to: Int16.self, capacity: nbSamples * nbChannels) { src in
                    for i in 0..<nbSamples { outChannels[outCh][i] = Float(src[i * nbChannels + srcCh]) / 32768.0 }
                }
            case AV_SAMPLE_FMT_S32P:
                plane.withMemoryRebound(to: Int32.self, capacity: nbSamples) { src in
                    for i in 0..<nbSamples { outChannels[outCh][i] = Float(src[i]) / 2147483648.0 }
                }
            case AV_SAMPLE_FMT_S32:
                plane.withMemoryRebound(to: Int32.self, capacity: nbSamples * nbChannels) { src in
                    for i in 0..<nbSamples { outChannels[outCh][i] = Float(src[i * nbChannels + srcCh]) / 2147483648.0 }
                }
            default:
                log("FFmpeg## Unsupported audio sample format: \(sampleFmt.rawValue)")
                return
            }
        }

        player?.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    // MARK: - Private: PTS-based frame timing

    // RTSP 스트림은 네트워크 자체가 패킷 속도를 제한하므로 추가 조절 불필요.
    // file:// / http:// 는 av_read_frame이 즉시 리턴하기 때문에 PTS를 보고 슬립해야 함.
    private func throttleVideo(frame: UnsafeMutablePointer<AVFrame>,
                                stream: UnsafeMutablePointer<AVStream>) {
        guard !sourceURL.hasPrefix("rtsp") else { return }

        let pts = frame.pointee.best_effort_timestamp != kFFmpegNoPTSValue
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        guard pts != kFFmpegNoPTSValue, pts > 0 else { return }

        let timeBaseD = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
        let ptsSeconds = Double(pts) * timeBaseD

        if frameStartPTS < 0 {
            frameStartWallTime = CFAbsoluteTimeGetCurrent()
            frameStartPTS = ptsSeconds
            return
        }

        let elapsed = ptsSeconds - frameStartPTS
        let targetWall = frameStartWallTime + elapsed / playbackRate
        let now = CFAbsoluteTimeGetCurrent()
        let sleepSec = targetWall - now
        if sleepSec > 0.001 {
            usleep(UInt32(min(sleepSec, 1.0) * 1_000_000))
        }
    }

    // MARK: - Private: av_rescale_q equivalent using av_rescale_rnd (avoids static inline)

    private func rescaleQ(_ a: Int64, _ bq: AVRational, _ cq: AVRational) -> Int64 {
        let num = Int64(bq.num) * Int64(cq.den)
        let den = Int64(bq.den) * Int64(cq.num)
        return av_rescale_rnd(a, num, den, AV_ROUND_NEAR_INF)
    }

    // MARK: - Private: Cleanup

    private func clearResources() {
        log("FFmpeg## clear")
        av_frame_free(&vFrame)
        av_frame_free(&aFrame)
        if packet != nil { av_packet_free(&packet) }
        if pVCtx != nil { avcodec_close(pVCtx); avcodec_free_context(&pVCtx) }
        if pACtx != nil { avcodec_close(pACtx); avcodec_free_context(&pACtx) }
        avformat_close_input(&pFormatContext)
        if let ctx = swsCtx { sws_freeContext(ctx); swsCtx = nil }
        if let ptr = dst_data[0] { av_free(UnsafeMutableRawPointer(ptr)); dst_data[0] = nil }
        if engine?.isRunning == true { engine?.stop() }
        if player?.isPlaying == true { player?.stop() }
        varispeedNode = nil
        ffmpeg_remove_log_callback()
    }

    private func sendState(_ state: PlayerState) {
        currentState = state.rawValue
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.receivedState(state)
        }
    }
}
