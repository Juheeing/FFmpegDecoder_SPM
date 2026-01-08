//
//  StreamRecorder.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 1/8/2569 BE.
//

import Foundation
import FFmpegHeaders

public final class StreamRecorder: @unchecked Sendable {
    private var inCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outCtx: UnsafeMutablePointer<AVFormatContext>?
    private var streamMap: [Int32] = []
    private var recording = false

    private let queue = DispatchQueue(label: "ffmpeg.recorder")

    public func start(rtspUrl: String, outputPath: String) {

        queue.async { [weak self] in
            guard let self else { return }
            self.record(rtspUrl: rtspUrl, outputPath: outputPath)
        }
    }
    
    public func stop() {
        recording = false
    }
    
    private func record(rtspUrl: String, outputPath: String) {

        recording = true

        // ---------- INPUT (RTSP) ----------
        var opt: OpaquePointer?
        av_dict_set(&opt, "rtsp_transport", "tcp", 0)
        av_dict_set(&opt, "stimeout", "5000000", 0)

        if avformat_open_input(&inCtx, rtspUrl, nil, &opt) < 0 {
            print("Recorder## open input fail")
            return
        }

        guard let inCtx else { return }

        if avformat_find_stream_info(inCtx, nil) < 0 {
            print("Recorder## find stream info fail")
            return
        }

        // ---------- OUTPUT (TS FILE) ----------
        if avformat_alloc_output_context2(&outCtx, nil, "mpegts", outputPath) < 0 {
            print("Recorder## alloc output fail")
            return
        }

        guard let outCtx else { return }

        if avio_open(&outCtx.pointee.pb, outputPath, AVIO_FLAG_WRITE) < 0 {
            print("Recorder## avio_open fail")
            return
        }

        // ---------- STREAM COPY ----------
        streamMap = Array(repeating: -1, count: Int(inCtx.pointee.nb_streams))

        for i in 0..<Int(inCtx.pointee.nb_streams) {

            guard let inStream = inCtx.pointee.streams[i] else { continue }

            let outStream = avformat_new_stream(outCtx, nil)
            avcodec_parameters_copy(outStream?.pointee.codecpar, inStream.pointee.codecpar)
            outStream?.pointee.time_base = inStream.pointee.time_base

            streamMap[i] = Int32(outStream!.pointee.index)
        }

        if avformat_write_header(outCtx, nil) < 0 {
            print("Recorder## write header fail")
            return
        }

        // ---------- PACKET LOOP ----------
        var pkt = AVPacket()

        while recording && av_read_frame(inCtx, &pkt) >= 0 {

            let inIndex = pkt.stream_index
            let outIndex = streamMap[Int(inIndex)]

            guard outIndex >= 0 else {
                av_packet_unref(&pkt)
                continue
            }

            let inStream = inCtx.pointee.streams[Int(inIndex)]!
            let outStream = outCtx.pointee.streams[Int(outIndex)]!

            pkt.stream_index = outIndex

            pkt.pts = av_rescale_q_rnd(pkt.pts, inStream.pointee.time_base, outStream.pointee.time_base, AVRounding(AV_ROUND_NEAR_INF.rawValue))
            pkt.dts = av_rescale_q_rnd(pkt.dts, inStream.pointee.time_base, outStream.pointee.time_base, AVRounding(AV_ROUND_NEAR_INF.rawValue))
            pkt.duration = av_rescale_q(pkt.duration, inStream.pointee.time_base, outStream.pointee.time_base)

            av_interleaved_write_frame(outCtx, &pkt)
            av_packet_unref(&pkt)
        }

        // ---------- CLEAN ----------
        av_write_trailer(outCtx)

        if let pb = outCtx.pointee.pb {
            avio_closep(&outCtx.pointee.pb)
        }

        avformat_close_input(&self.inCtx)
        avformat_free_context(outCtx)

        print("Recorder## finished")
    }
}
