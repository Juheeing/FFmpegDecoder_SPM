//
//  PacketRingBuffer.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 1/8/2569 BE.
//

import Foundation
import FFmpegHeaders

final class PacketRingBuffer {

    struct Item {
        let pkt: UnsafeMutablePointer<AVPacket>
        let ptsMs: Int64
        let isKey: Bool
    }

    private var items: [Item] = []
    private let maxDurationMs: Int64 = 90_000   // 90초 타임시프트

    private let lock = NSLock()

    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {
        lock.lock()
        let clone = av_packet_clone(pkt)!
        items.append(Item(pkt: clone, ptsMs: ptsMs, isKey: isKey))
        trimIfNeeded(currentPts: ptsMs)
        lock.unlock()
    }

    func pop() -> UnsafeMutablePointer<AVPacket>? {
        lock.lock()
        defer { lock.unlock() }

        guard !items.isEmpty else { return nil }
        return items.removeFirst().pkt
    }

    func clear() {
        lock.lock()
        for i in items {
            var p: UnsafeMutablePointer<AVPacket>? = i.pkt
            av_packet_free(&p)
        }
        items.removeAll()
        lock.unlock()
    }

    private func trimIfNeeded(currentPts: Int64) {

        // keyframe 기준으로 trim (seek 안전)
        while items.count > 2 {
            let first = items[0]
            if currentPts - first.ptsMs > maxDurationMs {
                if items[1].isKey {
                    var p: UnsafeMutablePointer<AVPacket>? = first.pkt
                    av_packet_free(&p)
                    items.removeFirst()
                } else {
                    break
                }
            } else {
                break
            }
        }
    }
}
