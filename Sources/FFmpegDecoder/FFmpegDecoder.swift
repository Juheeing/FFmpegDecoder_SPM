// FFmpegDecoder.swift
// Requires: FFmpeg headers available via bridging header and linked libs.
// NOTE: This is a best-effort, pragmatic Swift async/await rewrite of the provided objc decoder.

import Foundation
import AVFoundation
import CoreImage
import FFmpegHeaders

// MARK: - Public types

@objc
public enum FFmpegDecoderState: Int {
    case initialized = 0, preparing, readyToPlay, buffering, bufferFinished, paused, playedToTheEnd, error, stop
}

public protocol FFmpegDecoderDelegate: AnyObject {
    func decoder(_ decoder: FFmpegDecoder, didChangeState state: FFmpegDecoderState)
    func decoder(_ decoder: FFmpegDecoder, didUpdateCurrentTime seconds: Int64, duration: Int64)
    func decoder(_ decoder: FFmpegDecoder, didReceiveVideoSize size: CGSize)
    func decoder(_ decoder: FFmpegDecoder, didReceiveSeeking isSeeking: Bool)
    func decoder(_ decoder: FFmpegDecoder, didReceiveDecodedImage image: CIImage)
}

// MARK: - FFmpegDecoder

public final class FFmpegDecoder: @unchecked Sendable {
    
    public weak var delegate: FFmpegDecoderDelegate?
    public private(set) var state: FFmpegDecoderState = .initialized {
        didSet { delegate?.decoder(self, didChangeState: state) }
    }
    public private(set) var isSeeking = false {
        didSet { delegate?.decoder(self, didReceiveSeeking: isSeeking) }
    }
    public private(set) var durationMs: Int64 = 0
    public private(set) var currentTimeMs: Int64 = 0

    // MARK: - FFmpeg C contexts (UnsafeMutablePointer)
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1
    private var videoStream: UnsafeMutablePointer<AVStream>?
    private var audioStream: UnsafeMutablePointer<AVStream>?
    
    // MARK: - Frames / Packet
    private var vFrame: UnsafeMutablePointer<AVFrame>?
    private var aFrame: UnsafeMutablePointer<AVFrame>?
    private var pktPtr: UnsafeMutablePointer<AVPacket>? = nil
    
    // MARK: - State
    private var decodingStopped = false
    private var isPaused = false

    // MARK: - Video Convert
    private var swsCtx: OpaquePointer?
    private var dstData = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
    private var dstLineSize = [Int32](repeating: 0, count: 4)

    // MARK: - Audio
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var audioSampleRate: Double = 0
    private var audioChannels: Int = 0

    // MARK: - Pause Condition
    private let pauseCondition = NSCondition()

    // MARK: - Segment Buffer
    private var segmentQueue: [String] = []
    private let segmentLock = NSLock()
    
    private var videoDstBuffer: UnsafeMutableRawPointer?
    
    // 디코딩 스레드
    private let decodeQueue = DispatchQueue(label: "ffmpeg.decode.queue")
    
    public init() {
        avformat_network_init()
    }

    public func appendSegment(_ path: String) {
        segmentLock.lock()
        segmentQueue.append(path)
        segmentLock.unlock()
    }
    
    private func nextSegment() -> String? {
        segmentLock.lock()
        defer { segmentLock.unlock() }
        if segmentQueue.isEmpty { return nil }
        return segmentQueue.removeFirst()
    }
    
    // MARK: - Open File
    
    public func open() {
        state = .preparing

        decodeQueue.async {
            self.decoding()
        }
    }

    private func openFileInternal(url: String) {

        print("FFmpeg## open segment:", url)

        var fmt: UnsafeMutablePointer<AVFormatContext>?
        if avformat_open_input(&fmt, url, nil, nil) < 0 { return }

        guard let fmt else { return }
        formatCtx = fmt

        avformat_find_stream_info(fmt, nil)

        videoStreamIndex = -1
        audioStreamIndex = -1

        for i in 0..<Int(fmt.pointee.nb_streams) {
            let st = fmt.pointee.streams[i]!
            let type = st.pointee.codecpar.pointee.codec_type

            if type == AVMEDIA_TYPE_VIDEO && videoStreamIndex == -1 {
                videoStreamIndex = Int32(i)
            }
            if type == AVMEDIA_TYPE_AUDIO && audioStreamIndex == -1 {
                audioStreamIndex = Int32(i)
            }
        }

        prepareVideoDecoder()
        if audioStreamIndex >= 0 { prepareAudioDecoder() }

        state = .readyToPlay
    }
    
    func closeCurrentFile() {

        if formatCtx != nil {
            avformat_close_input(&formatCtx)
            formatCtx = nil
        }

        videoStreamIndex = -1
        audioStreamIndex = -1
    }
    
    // MARK: - Check Codec
    
    private func prepareVideoDecoder() {
        guard let formatCtx else { return }

        let stream = formatCtx.pointee.streams[Int(videoStreamIndex)]
        let codecPar = stream?.pointee.codecpar
        videoStream = stream

        guard let codec = avcodec_find_decoder(codecPar?.pointee.codec_id ?? AV_CODEC_ID_NONE) else {
            print("FFmpeg## 지원하지 않는 video codec: \(String(describing: codecPar?.pointee.codec_id.rawValue))")
            state = .error
            return
        }
        print("FFmpeg## video codec 발견: \(String(cString: codec.pointee.name))")

        videoCodecCtx = avcodec_alloc_context3(codec)
        guard let codecCtx = videoCodecCtx else {
            print("FFmpeg## avcodec_alloc_context3(video) 실패")
            return
        }

        avcodec_parameters_to_context(codecCtx, codecPar)
        
        let openRet = avcodec_open2(codecCtx, codec, nil)
        if openRet < 0 {
            print("FFmpeg## avcodec_open2(video) 실패: \(openRet)")
        }
        
        let width = codecCtx.pointee.width
        let height = codecCtx.pointee.height
        print("FFmpeg## 비디오 해상도: \(width)x\(height)")
        
        // 해상도 delegate 전달
        let size = CGSize(width: Int(width),
                          height: Int(height))
        delegate?.decoder(self, didReceiveVideoSize: size)
    }
    
    private func prepareAudioDecoder() {
        guard let formatCtx else { return }

        let stream = formatCtx.pointee.streams[Int(audioStreamIndex)]
        let codecPar = stream?.pointee.codecpar
        audioStream = stream

        guard let codec = avcodec_find_decoder(codecPar?.pointee.codec_id ?? AV_CODEC_ID_NONE) else {
            print("FFmpeg## 지원하지 않는 audio codec: \(String(describing: codecPar?.pointee.codec_id.rawValue))")
            state = .error
            return
        }
        print("FFmpeg## audio codec 발견: \(String(cString: codec.pointee.name))")

        audioCodecCtx = avcodec_alloc_context3(codec)
        guard let codecCtx = audioCodecCtx else {
            print("FFmpeg## avcodec_alloc_context3(audio) 실패")
            return
        }

        avcodec_parameters_to_context(codecCtx, codecPar)

        let openRet = avcodec_open2(codecCtx, codec, nil)
        if openRet < 0 {
            print("FFmpeg## avcodec_open2(audio) 실패: \(openRet)")
            return
        }

        let rate = codecCtx.pointee.sample_rate
        let channels = codecCtx.pointee.ch_layout.nb_channels
        
        print("FFmpeg## sample rate: \(rate)")
        print("FFmpeg## channels: \(channels)")
        print("FFmpeg## channel layout: \(codecCtx.pointee.ch_layout)")
        print("FFmpeg## sample format: \(codecCtx.pointee.sample_fmt.rawValue)")
        
        audioSampleRate = Double(rate)
        audioChannels = Int(channels)

    }
    
    // MARK: - Decoding Loop
    
    func decoding() {

        pktPtr = av_packet_alloc()
        vFrame = av_frame_alloc()
        aFrame = av_frame_alloc()

        guard pktPtr != nil else {
            print("FFmpeg## alloc fail")
            stopDecoding()
            return
        }

        while !decodingStopped {
            autoreleasepool {
                decodeStep()
            }
        }

        clear()
    }

    private func decodeStep() {

        pauseCondition.lock()
        while isPaused {
            if state != .paused {
                player?.pause()
                engine?.pause()
            }
            pauseCondition.wait()
        }
        pauseCondition.unlock()

        // ---------- segment 대기 ----------
        if formatCtx == nil {
            if let next = nextSegment() {
                openFileInternal(url: next)
            } else {
                usleep(50_000)
                return
            }
        }

        guard let pktPtr else { return }

        let readRet = readFrame(packet: pktPtr)

        if readRet == EOF {
            av_packet_unref(pktPtr)
            return
        }

        if readRet < 0 {
            av_packet_unref(pktPtr)
            usleep(30_000)
            return
        }

        let streamIndex = pktPtr.pointee.stream_index

        if streamIndex == videoStreamIndex {

            let sendRet = sendPacket(ctx: videoCodecCtx, packet: pktPtr)

            if sendRet >= 0 {
                while true {
                    let recvRet = receiveFrame(ctx: videoCodecCtx, frame: vFrame)
                    if recvRet < 0 { break }

                    getCurrentTime(frame: vFrame, stream: videoStream)
                    drawImage()
                }
            }

        } else if streamIndex == audioStreamIndex {

            let sendRet = sendPacket(ctx: audioCodecCtx, packet: pktPtr)

            if sendRet >= 0 {
                while true {
                    let recvRet = receiveFrame(ctx: audioCodecCtx, frame: aFrame)
                    if recvRet < 0 { break }

                    drawAudio()
                }
            }
        }

        av_packet_unref(pktPtr)
    }

    
    // MARK: - FFmpeg Functions
    
    func readFrame(packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let fmt = formatCtx else {
            return EOF
        }

        let ret = av_read_frame(fmt, packet)

        if ret == EOF || ret < 0 {

            print("FFmpeg## segment EOF")

            closeCurrentFile()

            // flush decoder state
            if let v = videoCodecCtx { avcodec_flush_buffers(v) }
            if let a = audioCodecCtx { avcodec_flush_buffers(a) }

            return EOF
        }

        return ret
    }


    func sendPacket(ctx: UnsafeMutablePointer<AVCodecContext>?,
                    packet: UnsafeMutablePointer<AVPacket>) -> Int32 {

        guard let ctx else {
            if state != .error { state = .error }
            print("FFmpeg## sendPacket: codec context is nil")
            return -1
        }

        let ret = avcodec_send_packet(ctx, packet)
        
        return ret
    }

    func receiveFrame(ctx: UnsafeMutablePointer<AVCodecContext>?,
                      frame: UnsafeMutablePointer<AVFrame>?) -> Int32 {

        guard let ctx else {
            if state != .error { state = .error }
            print("FFmpeg## receiveFrame: codec context is nil")
            return -1
        }

        let ret = avcodec_receive_frame(ctx, frame)

        return ret
    }
    
    // MARK: - Get Current Time
    
    private func getCurrentTime(frame: UnsafeMutablePointer<AVFrame>?,
                        stream: UnsafeMutablePointer<AVStream>?) {

        guard let frame = frame else { return }

        let streamRef = stream ?? videoStream
        guard let stream = streamRef else { return }
        
        let AV_NOPTS_VALUE: Int64 = Int64.min
        var pts = frame.pointee.best_effort_timestamp
        
        if pts == AV_NOPTS_VALUE {
            pts = frame.pointee.pts
            
            if pts == AV_NOPTS_VALUE {
                return
            }
        }
        
        let ms = av_rescale_q(pts, stream.pointee.time_base, AVRational(num: 1, den: 1000))
        let seconds = Double(ms) / 1000.0
        
        DispatchQueue.main.sync {
            self.delegate?.decoder(self, didUpdateCurrentTime: Int64(seconds), duration: self.durationMs / 1000)
        }
    }

    // MARK: - Draw Image
    
    private func drawImage() {
        guard let vFrame = vFrame else { return }

        let srcWidth = Int(vFrame.pointee.width)
        let srcHeight = Int(vFrame.pointee.height)
        let srcFormat = AVPixelFormat(rawValue: vFrame.pointee.format)
        let dstFormat = AV_PIX_FMT_BGRA // BGRA -> CGImage/CIImage에 적합

        // prepare swsCtx and dst buffers once
        if swsCtx == nil {
            swsCtx = sws_getContext(
                Int32(srcWidth), Int32(srcHeight), srcFormat,
                Int32(srcWidth), Int32(srcHeight), dstFormat,
                SWS_BILINEAR, nil, nil, nil
            )

            if swsCtx == nil {
                print("FFmpeg## sws_getContext 실패")
                return
            }

            // 버퍼 사이즈 계산 및 할당
            let bufSize = av_image_get_buffer_size(dstFormat, Int32(srcWidth), Int32(srcHeight), 1)
            if bufSize <= 0 {
                print("FFmpeg## av_image_get_buffer_size 실패")
                return
            }

            videoDstBuffer = av_malloc(Int(bufSize))
            if videoDstBuffer == nil {
                print("FFmpeg## av_malloc 실패")
                return
            }

            // dstData와 dstLineSize를 av_image_fill_arrays로 채운다.
            // dstData는 [UnsafeMutablePointer<UInt8>?] 타입이므로, withUnsafeMutableBufferPointer로 포인터를 넘겨준다.
            dstData = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
            dstLineSize = [Int32](repeating: 0, count: 4)

            // av_image_fill_arrays expects UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
            dstData.withUnsafeMutableBufferPointer { ptr in
                let px = ptr.baseAddress!
                av_image_fill_arrays(px, &dstLineSize, videoDstBuffer!.assumingMemoryBound(to: UInt8.self), dstFormat, Int32(srcWidth), Int32(srcHeight), 1)
            }
        }

        // MARK: - 튜플 → 배열 변환
        let srcDataArray: [UnsafePointer<UInt8>?] = [
            vFrame.pointee.data.0.map { UnsafePointer($0) },
            vFrame.pointee.data.1.map { UnsafePointer($0) },
            vFrame.pointee.data.2.map { UnsafePointer($0) },
            vFrame.pointee.data.3.map { UnsafePointer($0) },
            vFrame.pointee.data.4.map { UnsafePointer($0) },
            vFrame.pointee.data.5.map { UnsafePointer($0) },
            vFrame.pointee.data.6.map { UnsafePointer($0) },
            vFrame.pointee.data.7.map { UnsafePointer($0) }
        ]

        let srcLinesizeArray: [Int32] = [
            vFrame.pointee.linesize.0,
            vFrame.pointee.linesize.1,
            vFrame.pointee.linesize.2,
            vFrame.pointee.linesize.3,
            vFrame.pointee.linesize.4,
            vFrame.pointee.linesize.5,
            vFrame.pointee.linesize.6,
            vFrame.pointee.linesize.7
        ]

        // MARK: - sws_scale 호출
        let scaled = dstData.withUnsafeMutableBufferPointer { dstPtr -> Int32 in
            return sws_scale(
                swsCtx,
                srcDataArray,
                srcLinesizeArray,
                0,
                Int32(srcHeight),
                dstPtr.baseAddress,
                &dstLineSize
            )
        }

        if scaled <= 0 {
            print("FFmpeg## sws_scale 실패 또는 0 frames: \(scaled)")
            return
        }

        guard let dst0 = dstData[0] else {
            print("FFmpeg## dstData[0] nil")
            return
        }

        // bytesPerRow & dataSize
        let bytesPerRow = Int(dstLineSize[0])
        let dataSize = bytesPerRow * srcHeight

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: dst0,
            size: dataSize,
            releaseData: { _, _, _ in }
        ) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        guard let cgImage = CGImage(
            width: srcWidth,
            height: srcHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return }

        let ciImage = CIImage(cgImage: cgImage)

        DispatchQueue.main.async {
            self.delegate?.decoder(self, didReceiveDecodedImage: ciImage)
        }
    }

    // MARK: - Draw Audio
    
    private func drawAudio() {
        guard let aFrame = aFrame?.pointee,
              let audioCodecCtx = audioCodecCtx?.pointee else {
            print("FFmpeg## drawAudio: aFrame 또는 audioCodecCtx nil")
            return
        }
        
        // AudioEngine 준비
        if engine == nil {
            setupAudioEngine(sampleRate: audioSampleRate, channels: audioChannels)
        }
        guard let engine, let player else {
            print("FFmpeg## engine 또는 player nil")
            return
        }

        let sampleRate = Double(audioCodecCtx.sample_rate)
        let channels = Int(audioCodecCtx.ch_layout.nb_channels)
        let frameCount = AVAudioFrameCount(aFrame.nb_samples)

        // sample format
        let sampleFormat = audioCodecCtx.sample_fmt
        let isPlanar = av_sample_fmt_is_planar(sampleFormat) != 0
        let bytesPerSample = av_get_bytes_per_sample(sampleFormat)

        // AVAudioFormat 생성
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            print("FFmpeg## audioFormat 생성 실패")
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            print("FFmpeg## AVAudioPCMBuffer 생성 실패")
            return
        }
        buffer.frameLength = frameCount

        // FFmpeg → Float32 변환
        for ch in 0..<channels {
            let outPtr = buffer.floatChannelData![ch]
            
            if isPlanar {
                guard let inPtr = frameDataPointer(aFrame, channel: ch) else { continue }
                memcpy(outPtr, inPtr, Int(frameCount) * Int(bytesPerSample))
            } else {
                guard let basePtr = frameDataPointer(aFrame, channel: 0) else { return }

                let inPtr = UnsafeMutableRawPointer(basePtr)
                    .assumingMemoryBound(to: Float.self)
                
                for i in 0..<Int(frameCount) {
                    outPtr[i] = inPtr[i * channels + ch]
                }
            }
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("FFmpeg## engine.start 실패: \(error)")
            }
        }

        if !player.isPlaying {
            player.play()
        }
    }
    
    private func setupAudioEngine(sampleRate: Double, channels: Int) {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()

        guard let engine, let player else {
            print("FFmpeg## setupAudioEngine 실패 — engine 또는 player nil")
            return
        }

        engine.attach(player)

        // FFmpeg 오디오 정보 기반으로 AVAudioFormat 생성
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        
        print("FFmpeg## inputFormat: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        let mixer = engine.mainMixerNode
        
        print("FFmpeg## Player → Mixer 연결 수행")

        // Player → Mixer 연결
        engine.connect(player, to: mixer, format: inputFormat)

        do {
            try engine.start()
            print("FFmpeg## AudioEngine start OK")
        } catch {
            print("FFmpeg## AudioEngine start 실패: \(error)")
        }
    }
    
    private func frameDataPointer(_ frame: AVFrame, channel: Int) -> UnsafeMutablePointer<UInt8>? {
        let ptr = [
            frame.data.0, frame.data.1, frame.data.2, frame.data.3,
            frame.data.4, frame.data.5, frame.data.6, frame.data.7
        ]

        let p = ptr.indices.contains(channel) ? ptr[channel] : nil
        return p
    }

    // MARK: - Utility
    
    public func pause() {
        if isPaused { return }
        
        pauseCondition.lock()
        isPaused = true

        pauseCondition.signal()
        pauseCondition.unlock()
        
        print("FFmpeg## Pause")
    }

    public func resume() {
        if !isPaused { return }
        
        pauseCondition.lock()
        isPaused = false
            
        pauseCondition.signal()
        pauseCondition.unlock()
        print("FFmpeg## Resume")
    }

    public func stopDecoding() {
        pauseCondition.lock()
        decodingStopped = true
        pauseCondition.signal()
        pauseCondition.unlock()
        print("FFmpeg## stopDecoding requested")
    }
    
    public func isPlaying() -> Bool {
        !isPaused
    }

    func clear() {

        if vFrame != nil {
            av_frame_free(&vFrame)
        }
        if aFrame != nil {
            av_frame_free(&aFrame)
        }

        if videoCodecCtx != nil {
            avcodec_free_context(&videoCodecCtx)
        }
        if audioCodecCtx != nil {
            avcodec_free_context(&audioCodecCtx)
        }

        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }

        if swsCtx != nil {
            sws_freeContext(swsCtx)
            swsCtx = nil
        }

        if pktPtr != nil {
            av_packet_free(&pktPtr)
            pktPtr = nil
        }
        
        if let buf = videoDstBuffer {
            av_free(buf)
            videoDstBuffer = nil
        }

        player?.stop()
        engine?.stop()
        player = nil
        engine = nil

        print("FFmpeg## clear")
    }

}
