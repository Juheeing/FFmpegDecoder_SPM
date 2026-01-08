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
    private var readStopped = false
    private var isPaused = false

    // MARK: - Video Convert
    private var swsCtx: OpaquePointer?
    private var dstBuffer: UnsafeMutableRawPointer?
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
    
    private let packetBuffer = PacketRingBuffer()
    
    // MARK: - Thrades
    private let decodeQueue = DispatchQueue(label: "ffmpeg.decode.queue")
    private let readQueue = DispatchQueue(label: "ffmpeg.read.queue")
    
    public init() {
        avformat_network_init()
    }
    
    // MARK: - Open File
    
    public func open(url: String) {
        state = .preparing

        readQueue.async { [weak self] in
            self?.openAndRead(url: url)
        }

        decodeQueue.async { [weak self] in
            self?.decodingLoop()
        }
    }

    private func openAndRead(url: String) {

        var opt: OpaquePointer?
        av_dict_set(&opt, "rtsp_transport", "tcp", 0)
        av_dict_set(&opt, "fflags", "nobuffer", 0)
        av_dict_set(&opt, "flags", "low_delay", 0)

        var fmt: UnsafeMutablePointer<AVFormatContext>?

        if avformat_open_input(&fmt, url, nil, &opt) < 0 {
            state = .error
            return
        }

        formatCtx = fmt
        avformat_find_stream_info(fmt, nil)

        for i in 0..<Int(fmt!.pointee.nb_streams) {
            let st = fmt!.pointee.streams[i]!
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                videoStream = st
            }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndex = Int32(i)
            }
        }

        prepareVideoDecoder()
        if audioStreamIndex >= 0 { prepareAudioDecoder() }

        state = .readyToPlay
        startReadLoop()
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
    
    // MARK: - Read Loop
    
    private func startReadLoop() {

        guard let formatCtx else { return }

        var readPkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()

        while !readStopped {

            guard let pkt = readPkt else { break }

            let ret = av_read_frame(formatCtx, pkt)
            if ret < 0 {
                usleep(50_000)
                continue
            }

            let ptsMs = packetTimeMs(pkt)
            let isKey = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0

            if let clone = av_packet_clone(pkt) {
                packetBuffer.push(clone, ptsMs: ptsMs, isKey: isKey)
            }

            // read용 packet은 재사용
            av_packet_unref(pkt)
        }

        if readPkt != nil {
            var p = readPkt
            av_packet_free(&p)
            readPkt = nil
        }
    }

    
    private func packetTimeMs(_ pkt: UnsafeMutablePointer<AVPacket>) -> Int64 {
        guard let stream = videoStream else { return 0 }
        return av_rescale_q(pkt.pointee.pts, stream.pointee.time_base,
                            AVRational(num: 1, den: 1000))
    }
    
    // MARK: - Decoding Loop
    
    private func decodingLoop() {

        vFrame = av_frame_alloc()
        aFrame = av_frame_alloc()

        while !decodingStopped {

            pauseCondition.lock()
            while isPaused {
                if state != .paused { state = .paused }
                pauseCondition.wait()
            }
            pauseCondition.unlock()
            
            if state != .readyToPlay { state = .readyToPlay }

            guard let pkt = packetBuffer.pop() else {
                usleep(10_000)
                continue
            }

            processPacket(pkt)

            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }

        clear()
    }
    
    private func processPacket(_ pkt: UnsafeMutablePointer<AVPacket>) {

        let idx = pkt.pointee.stream_index

        if idx == videoStreamIndex {
            if avcodec_send_packet(videoCodecCtx, pkt) >= 0 {
                while avcodec_receive_frame(videoCodecCtx, vFrame) >= 0 {
                    drawImage()
                }
            }
        }

        if idx == audioStreamIndex {
            if avcodec_send_packet(audioCodecCtx, pkt) >= 0 {
                while avcodec_receive_frame(audioCodecCtx, aFrame) >= 0 {
                    drawAudio()
                }
            }
        }
    }
    
    // MARK: - FFmpeg Functions
    
    func readFrame(packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let fmt = formatCtx else {
            if state != .error { state = .error }
            print("FFmpeg## readFrame: formatCtx is nil")
            return -1
        }

        let ret = av_read_frame(fmt, packet)

        if ret < 0 {
            if ret == EOF {
                print("FFmpeg## readFrame: EOF reached")
                if state != .playedToTheEnd { state = .playedToTheEnd }
                stopDecoding()
            } else {
                if state != .error { state = .error }
                print("FFmpeg## readFrame error: \(ret)")
            }
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

            let buffer = av_malloc(Int(bufSize))
            if buffer == nil {
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
                av_image_fill_arrays(px, &dstLineSize, buffer!.assumingMemoryBound(to: UInt8.self), dstFormat, Int32(srcWidth), Int32(srcHeight), 1)
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

        player?.stop()
        engine?.stop()
        player = nil
        engine = nil

        print("FFmpeg## clear")
    }

}
