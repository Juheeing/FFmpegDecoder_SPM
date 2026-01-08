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
        print("Recorder## start called")

        queue.async { [weak self] in
            guard let self else { return }
            print("Recorder## queue started")
            self.record(rtspUrl: rtspUrl, outputPath: outputPath)
        }
    }

    public func stop() {
        print("Recorder## stop called")
        recording = false
    }

    private func record(rtspUrl: String, outputPath: String) {

        print("Recorder## record begin")
        recording = true

        // ---------- INPUT ----------
        var opt: OpaquePointer?
        av_dict_set(&opt, "rtsp_transport", "tcp", 0)
        av_dict_set(&opt, "stimeout", "5000000", 0)

        print("Recorder## opening RTSP:", rtspUrl)

        let openRet = avformat_open_input(&inCtx, rtspUrl, nil, &opt)
        if openRet < 0 {
            print("Recorder## open input fail:", openRet)
            return
        }

        print("Recorder## open input success")

        guard let inCtx else {
            print("Recorder## inCtx nil after open")
            return
        }

        let infoRet = avformat_find_stream_info(inCtx, nil)
        if infoRet < 0 {
            print("Recorder## find stream info fail:", infoRet)
            return
        }

        print("Recorder## stream info found")
        print("Recorder## stream count:", inCtx.pointee.nb_streams)

        // ---------- OUTPUT ----------
        print("Recorder## create output:", outputPath)

        let allocRet = avformat_alloc_output_context2(&outCtx, nil, "mpegts", outputPath)
        if allocRet < 0 {
            print("Recorder## alloc output fail:", allocRet)
            return
        }

        guard let outCtx else {
            print("Recorder## outCtx nil")
            return
        }

        let ioRet = avio_open(&outCtx.pointee.pb, outputPath, AVIO_FLAG_WRITE)
        if ioRet < 0 {
            print("Recorder## avio_open fail:", ioRet)
            return
        }

        print("Recorder## avio_open success")

        // ---------- STREAM COPY ----------
        streamMap = Array(repeating: -1, count: Int(inCtx.pointee.nb_streams))

        for i in 0..<Int(inCtx.pointee.nb_streams) {

            guard let inStream = inCtx.pointee.streams[i] else {
                print("Recorder## inStream nil:", i)
                continue
            }

            let outStream = avformat_new_stream(outCtx, nil)
            avcodec_parameters_copy(outStream?.pointee.codecpar, inStream.pointee.codecpar)
            outStream?.pointee.time_base = inStream.pointee.time_base

            streamMap[i] = Int32(outStream!.pointee.index)

            print("Recorder## stream mapped:", i, "->", outStream!.pointee.index)
        }

        let headerRet = avformat_write_header(outCtx, nil)
        if headerRet < 0 {
            print("Recorder## write header fail:", headerRet)
            return
        }

        print("Recorder## write header success")

        // ---------- PACKET LOOP ----------
        var pkt = AVPacket()
        var packetCount = 0

        print("Recorder## packet loop start")

        while recording {

            let readRet = av_read_frame(inCtx, &pkt)
            if readRet < 0 {
                print("Recorder## av_read_frame end or error:", readRet)
                break
            }

            packetCount += 1

            if packetCount % 30 == 0 {
                print("Recorder## packet count:", packetCount)
            }

            let inIndex = pkt.stream_index
            let outIndex = streamMap[Int(inIndex)]

            guard outIndex >= 0 else {
                av_packet_unref(&pkt)
                continue
            }

            let inStream = inCtx.pointee.streams[Int(inIndex)]!
            let outStream = outCtx.pointee.streams[Int(outIndex)]!

            pkt.stream_index = outIndex

            pkt.pts = av_rescale_q_rnd(
                pkt.pts,
                inStream.pointee.time_base,
                outStream.pointee.time_base,
                AVRounding(AV_ROUND_NEAR_INF.rawValue)
            )

            pkt.dts = av_rescale_q_rnd(
                pkt.dts,
                inStream.pointee.time_base,
                outStream.pointee.time_base,
                AVRounding(AV_ROUND_NEAR_INF.rawValue)
            )

            pkt.duration = av_rescale_q(
                pkt.duration,
                inStream.pointee.time_base,
                outStream.pointee.time_base
            )

            let writeRet = av_interleaved_write_frame(outCtx, &pkt)
            if writeRet < 0 {
                print("Recorder## write frame fail:", writeRet)
            }

            av_packet_unref(&pkt)
        }

        print("Recorder## packet loop end")

        // ---------- CLEAN ----------
        av_write_trailer(outCtx)
        print("Recorder## trailer written")

        if let _ = outCtx.pointee.pb {
            avio_closep(&outCtx.pointee.pb)
            print("Recorder## io closed")
        }

        avformat_close_input(&self.inCtx)
        avformat_free_context(outCtx)

        print("Recorder## finished")
    }
}
