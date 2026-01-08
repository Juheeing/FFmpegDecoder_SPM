//
//  StreamRecorder.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 1/8/2569 BE.
//

import Foundation
import FFmpegHeaders

public final class StreamRecorder: @unchecked Sendable {

    private weak var decoder: FFmpegDecoder?
    
    // MARK: - FFmpeg Context
    private var inCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outCtx: UnsafeMutablePointer<AVFormatContext>?

    // MARK: - State
    private var recording = false
    private var streamMap: [Int32] = []

    // MARK: - Segment
    private var segmentIndex: Int = 0
    private var segmentStartPtsMs: Int64 = 0
    private let segmentDurationMs: Int64 = 5_000   // 5초 세그먼트
    private var outputDir: String = ""

    // MARK: - Queue
    private let queue = DispatchQueue(label: "ffmpeg.recorder.queue")

    // MARK: - Public

    public init() {
        avformat_network_init()
    }

    public func bindDecoder(_ decoder: FFmpegDecoder) {
        self.decoder = decoder
    }
    
    public func start(rtspUrl: String, outputDir: String) {
        self.outputDir = outputDir

        queue.async { [weak self] in
            self?.recordLoop(rtspUrl: rtspUrl)
        }
    }

    public func stop() {
        recording = false
    }

    // MARK: - Main Loop

    private func recordLoop(rtspUrl: String) {

        recording = true

        while recording {

            if !openInput(rtspUrl) {
                sleep(1)
                continue
            }

            openNewSegment()

            var pkt = AVPacket()

            while recording {

                let ret = av_read_frame(inCtx, &pkt)

                if ret < 0 {
                    print("Recorder## RTSP read error → reconnect")
                    break
                }

                let nowMs = packetTimeMs(pkt)

                if nowMs - segmentStartPtsMs >= segmentDurationMs {
                    closeSegment()
                    openNewSegment()
                }

                writePacket(pkt)
                av_packet_unref(&pkt)
            }

            closeInput()
        }

        cleanup()
        print("Recorder## stopped")
    }

    // MARK: - Input

    private func openInput(_ url: String) -> Bool {

        var opt: OpaquePointer?
        av_dict_set(&opt, "rtsp_transport", "tcp", 0)
        av_dict_set(&opt, "stimeout", "5000000", 0)

        if avformat_open_input(&inCtx, url, nil, &opt) < 0 {
            print("Recorder## open input fail")
            return false
        }

        guard let inCtx else { return false }

        if avformat_find_stream_info(inCtx, nil) < 0 {
            print("Recorder## find stream info fail")
            return false
        }

        streamMap = Array(repeating: -1, count: Int(inCtx.pointee.nb_streams))
        return true
    }

    private func closeInput() {
        if inCtx != nil {
            avformat_close_input(&inCtx)
            inCtx = nil
        }
    }

    // MARK: - Segment

    private func openNewSegment() {

        guard let inCtx else { return }

        let path = "\(outputDir)/seg_\(segmentIndex).ts"
        segmentIndex += 1

        print("Recorder## new segment: \(path)")

        avformat_alloc_output_context2(&outCtx, nil, "mpegts", path)

        guard let outCtx else { return }

        avio_open(&outCtx.pointee.pb, path, AVIO_FLAG_WRITE)

        for i in 0..<Int(inCtx.pointee.nb_streams) {

            guard let inStream = inCtx.pointee.streams[i] else { continue }

            let outStream = avformat_new_stream(outCtx, nil)
            avcodec_parameters_copy(outStream?.pointee.codecpar, inStream.pointee.codecpar)
            outStream?.pointee.time_base = inStream.pointee.time_base

            streamMap[i] = Int32(outStream!.pointee.index)
        }

        avformat_write_header(outCtx, nil)

        segmentStartPtsMs = currentInputTimeMs()
    }

    private func closeSegment() {

        guard let outCtx else { return }

        av_write_trailer(outCtx)

        if outCtx.pointee.pb != nil {
            avio_closep(&outCtx.pointee.pb)
        }

        avformat_free_context(outCtx)
        self.outCtx = nil

        let finishedPath = "\(outputDir)/seg_\(segmentIndex - 1).ts"
        decoder?.appendSegment(finishedPath)
    }

    // MARK: - Write

    private func writePacket(_ pkt: AVPacket) {

        guard let inCtx, let outCtx else { return }

        let inIndex = pkt.stream_index
        let outIndex = streamMap[Int(inIndex)]

        if outIndex < 0 { return }

        let inStream = inCtx.pointee.streams[Int(inIndex)]!
        let outStream = outCtx.pointee.streams[Int(outIndex)]!

        var pkt = pkt
        pkt.stream_index = outIndex

        pkt.pts = av_rescale_q_rnd(pkt.pts,
                                   inStream.pointee.time_base,
                                   outStream.pointee.time_base,
                                   AVRounding(AV_ROUND_NEAR_INF.rawValue))

        pkt.dts = av_rescale_q_rnd(pkt.dts,
                                   inStream.pointee.time_base,
                                   outStream.pointee.time_base,
                                   AVRounding(AV_ROUND_NEAR_INF.rawValue))

        pkt.duration = av_rescale_q(pkt.duration,
                                    inStream.pointee.time_base,
                                    outStream.pointee.time_base)

        av_interleaved_write_frame(outCtx, &pkt)
    }

    // MARK: - Time

    private func packetTimeMs(_ pkt: AVPacket) -> Int64 {

        guard let inCtx else { return 0 }

        let stream = inCtx.pointee.streams[Int(pkt.stream_index)]!
        let tb = stream.pointee.time_base

        let pts = pkt.pts == Int64.min ? pkt.dts : pkt.pts
        return av_rescale_q(pts, tb, AVRational(num: 1, den: 1000))
    }

    private func currentInputTimeMs() -> Int64 {
        guard let inCtx else { return 0 }
        return Int64(inCtx.pointee.start_time)
    }

    // MARK: - Cleanup

    private func cleanup() {
        closeSegment()
        closeInput()
    }
}
