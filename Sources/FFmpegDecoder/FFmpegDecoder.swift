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
    private var packet = AVPacket()
    private var pktPtr: UnsafeMutablePointer<AVPacket>? = nil
    
    // MARK: - State
    private var decodingStopped = false
    private var isPaused = false
    private var isPlaying = false
    private var currentState: Int = 0

    // MARK: - Video Convert
    private var swsCtx: OpaquePointer?
    private var dstData = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
    private var dstLineSize = [Int32](repeating: 0, count: 4)

    // MARK: - Audio
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    // MARK: - Pause Condition
    private let pauseCondition = NSCondition()

    // 디코딩 스레드
    private let decodeQueue = DispatchQueue(label: "ffmpeg.decode.queue")
    
    public init() {
        avformat_network_init()
    }

    // MARK: - Open File
    public func open(url: String) {
        state = .preparing

        decodeQueue.async {
            self.openFileInternal(url: url)
        }
    }

    private func openFileInternal(url: String) {
        print("FFmpeg## openFileInternal: \(url)")
        
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()

        // 파일 열기
        var options: OpaquePointer? = nil
        av_dict_set(&options, "rtsp_transport", "tcp", 0)
        av_dict_set(&options, "max_delay", "500000", 0)

        let openResult = avformat_open_input(&fmtCtx, url, nil, &options)
        if openResult != 0 {
            print("FFmpeg## avformat_open_input 실패: \(openResult)")
            state = .error
            return
        }
        print("FFmpeg## avformat_open_input 성공")
        
        guard let formatCtx = fmtCtx else {
            print("FFmpeg## formatCtx nil")
            return
        }
        self.formatCtx = formatCtx

        // 스트림 정보 읽기
        let infoResult = avformat_find_stream_info(formatCtx, nil)
        if infoResult < 0 {
            print("FFmpeg## avformat_find_stream_info 실패: \(infoResult)")
        } else {
            print("FFmpeg## avformat_find_stream_info 성공")
        }

        // 비디오 오디오 스트림 찾기
        for i in 0 ..< Int(formatCtx.pointee.nb_streams) {
            guard let stream = formatCtx.pointee.streams[i] else { continue }
            let codecType = stream.pointee.codecpar.pointee.codec_type

            if codecType == AVMEDIA_TYPE_VIDEO && videoStreamIndex == -1 {
                videoStreamIndex = Int32(i)
                print("FFmpeg## 비디오 스트림 발견 index: \(videoStreamIndex)")
            }

            if codecType == AVMEDIA_TYPE_AUDIO && audioStreamIndex == -1 {
                audioStreamIndex = Int32(i)
                print("FFmpeg## 오디오 스트림 발견 index: \(audioStreamIndex)")
            }
        }

        if videoStreamIndex == -1 {
            print("FFmpeg## 비디오 스트림을 찾지 못함")
            state = .error
            return
        }
        
        if audioStreamIndex == -1 {
            print("FFmpeg## 오디오 스트림을 찾지 못함")
            state = .error
            return
        }

        // duration 계산
        let duration = formatCtx.pointee.duration
        let AV_TIME_BASE_Q = AVRational(num: 1, den: Int32(AV_TIME_BASE))
        //let AV_TIME_BASE_Q = av_make_q(1, AV_TIME_BASE)

        if duration > 0 {
            durationMs = Int64(av_rescale_q(duration, AV_TIME_BASE_Q, AVRational(num: 1, den: 1000)))
            print("FFmpeg## duration(ms): \(durationMs)")
        } else {
            print("FFmpeg## duration 정보 없음(duration <= 0)")
        }

        // 비디오 오디오 디코더 준비
        prepareVideoDecoder()
        prepareAudioDecoder()
        
        print("FFmpeg## 디코딩 준비 완료 → readyToPlay")
        state = .readyToPlay
        
        decoding()
    }
    
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

        print("FFmpeg## sample rate: \(codecCtx.pointee.sample_rate)")
        print("FFmpeg## channels: \(codecCtx.pointee.ch_layout.nb_channels)")
        print("FFmpeg## channel layout: \(codecCtx.pointee.ch_layout)")
        print("FFmpeg## sample format: \(codecCtx.pointee.sample_fmt.rawValue)")

    }
    
    func decoding() {

        if currentState != 1 { sendCurrentState(1) }

        pktPtr = av_packet_alloc()
        vFrame = av_frame_alloc()
        aFrame = av_frame_alloc()
        guard pktPtr != nil, vFrame != nil, aFrame != nil else {
            print("FFmpeg## alloc fail")
            stopDecoding()
            return
        }
        
        guard let formatCtx = formatCtx else {
            print("FFmpeg## formatCtx nil")
            stopDecoding();
            return
        }

        guard let videoCodecCtx = videoCodecCtx, let audioCodecCtx = audioCodecCtx else {
            print("FFmpeg## codecCtx nil")
            stopDecoding();
            return
        }
        
        while !decodingStopped {
            
            let ret = av_read_frame(formatCtx, pktPtr)
                        
            if ret < 0 {
                if ret == EOF {
                    print("FFmpeg## EOF")
                    if currentState != 6 { sendCurrentState(6) }
                } else {
                    print("FFmpeg## read error \(ret)")
                    if currentState != 7 { sendCurrentState(7) }
                }
                break
            }

            let streamIndex = pktPtr!.pointee.stream_index

            if streamIndex == videoStreamIndex {

                let sendRet = avcodec_send_packet(videoCodecCtx, pktPtr)

                if sendRet >= 0 {
                    while true {
                        let recvRet = avcodec_receive_frame(videoCodecCtx, vFrame)
                        
                        if recvRet < 0 { break }
                        
                        getCurrentTime(frame: vFrame, stream: videoStream)
                        drawImage()
                    }
                }
            } else if streamIndex == audioStreamIndex {

                let sendRet = avcodec_send_packet(audioCodecCtx, pktPtr)

                if sendRet >= 0 {
                    while true {
                        let recvRet = avcodec_receive_frame(audioCodecCtx, aFrame)

                        if recvRet < 0 { break }

                        drawAudio()
                    }
                }
            }

            av_packet_unref(pktPtr)
        }
        clear()
    }

    // MARK: - Read Frame
    func readFrame(packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let fmt = formatCtx else { return -1 }

        let ret = av_read_frame(fmt, packet)

        if ret == EOF {
            print("FFmpeg## readFrame EOF")
            stopDecoding()
            if currentState != 6 { sendCurrentState(6) }
        }

        return ret
    }

    func sendPacket(ctx: UnsafeMutablePointer<AVCodecContext>?,
                    packet: UnsafeMutablePointer<AVPacket>) -> Int32 {

        guard let ctx else { return -1 }
        return avcodec_send_packet(ctx, packet)
    }

    func receiveFrame(ctx: UnsafeMutablePointer<AVCodecContext>?,
                      frame: UnsafeMutablePointer<AVFrame>?) -> Int32 {

        guard let ctx else { return -1 }
        return avcodec_receive_frame(ctx, frame)
    }

    // MARK: - Play / Pause
    func readPlay() -> Int32 {
        guard let fmt = formatCtx else { return -1 }

        isPlaying = true
        let ret = av_read_play(fmt)

        if ret >= 0 {
            if currentState != 4 { sendCurrentState(4) }
        } else {
            if currentState != 7 { sendCurrentState(7) }
            print("FFmpeg## av_read_play error: \(ret)")
        }
        return ret
    }

    func readPause() -> Int32 {
        guard let fmt = formatCtx else { return -1 }

        isPlaying = false
        let ret = av_read_pause(fmt)

        if ret >= 0 {
            if currentState != 5 { sendCurrentState(5) }
        } else {
            if currentState != 7 { sendCurrentState(7) }
            print("FFmpeg## av_read_pause error: \(ret)")
        }

        return ret
    }

    // MARK: - Get Current Time
    func getCurrentTime(frame: UnsafeMutablePointer<AVFrame>?,
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

            let rawBuffer = av_malloc(Int(bufSize))
            if rawBuffer == nil {
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
                av_image_fill_arrays(px, &dstLineSize, rawBuffer!.assumingMemoryBound(to: UInt8.self), dstFormat, Int32(srcWidth), Int32(srcHeight), 1)
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

        // UnsafeRawPointer로 Data 생성
        let rawPointer = UnsafeRawPointer(dst0)
        let imageData = Data(bytes: rawPointer, count: dataSize)

        // CGImage 생성 (BGRA, little endian, premultiplied first)
        guard let provider = CGDataProvider(data: imageData as CFData) else {
            print("FFmpeg## CGDataProvider 생성 실패")
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)

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
        ) else {
            print("FFmpeg## CGImage 생성 실패")
            return
        }

        let ciImage = CIImage(cgImage: cgImage)

        DispatchQueue.main.sync {
            self.delegate?.decoder(self, didReceiveDecodedImage: ciImage)
        }
    }

    // MARK: - Draw Audio
    func drawAudio() {

    }

    func playAudioFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> Data {
        let bytesPerSample = Int(av_get_bytes_per_sample(audioCodecCtx!.pointee.sample_fmt))
        let channels = Int(audioCodecCtx!.pointee.ch_layout.nb_channels)
        let count = bytesPerSample * channels * Int(frame.pointee.nb_samples)

        return Data(bytes: frame.pointee.data.0!, count: count)
    }

    // MARK: - Utility

    func sendCurrentState(_ state: Int) {
        currentState = state
        print("FFmpeg## State -> \(state)")
    }

    func stopDecoding() {
        decodingStopped = true
    }

    func clear() {
        av_frame_free(&vFrame)
        av_frame_free(&aFrame)
        sws_freeContext(swsCtx)
    }
}
