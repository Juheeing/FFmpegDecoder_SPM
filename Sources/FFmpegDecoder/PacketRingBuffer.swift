//
//  PacketRingBuffer.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 1/8/2569 BE.
//

import Foundation
import FFmpegHeaders

final class PacketRingBuffer {

    final class Item {
        var pkt: UnsafeMutablePointer<AVPacket>?
        let ptsMs: Int64
        let isKey: Bool
        
        init(pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {
            self.pkt = pkt
            self.ptsMs = ptsMs
            self.isKey = isKey
        }
    }

    private var buffer: [Item] = []
    private let maxCount = 3600
    private let lock = NSLock()
    private var readIndex: Int = 0
    
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return readIndex >= buffer.count
    }
    
    var bufferedDurationMs: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let first = buffer.first, let last = buffer.last else { return 0 }
        return last.ptsMs - first.ptsMs
    }
    
    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {
        let item = Item(pkt: pkt, ptsMs: ptsMs, isKey: isKey)

        lock.lock()
        buffer.append(item)

        // 읽은 영역 정리
        if buffer.count > maxCount {
            let cleanupCount = min(readIndex, buffer.count - maxCount)
            if cleanupCount > 0 {
                for i in 0..<cleanupCount {
                    var pkt = buffer[i].pkt
                    av_packet_free(&pkt)
                    buffer[i].pkt = nil
                }
                buffer.removeFirst(cleanupCount)
                readIndex -= cleanupCount
            }
        }
        lock.unlock()
    }

    func pop() -> Item? {
        lock.lock()
        
        guard readIndex < buffer.count else {
            return nil
        }

        let item = buffer[readIndex]
        readIndex += 1
        
        lock.unlock()
        return item
    }
    
    func clear() {
        lock.lock()
        for i in 0..<buffer.count {
            av_packet_free(&buffer[i].pkt)
            buffer[i].pkt = nil
        }
        buffer.removeAll()
        lock.unlock()
    }
}

extension PacketRingBuffer {

    func contains(ptsMs: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let first = buffer.first, let last = buffer.last else {
            return false
        }
        return first.ptsMs <= ptsMs && ptsMs <= last.ptsMs
    }

    func seekToNearestKeyFrame(before ptsMs: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }

        var candidate: Int?

        for i in 0..<buffer.count {
            let item = buffer[i]
            if item.isKey && item.ptsMs <= ptsMs {
                candidate = i
            }
        }

        if let idx = candidate {
            readIndex = idx
            return true
        }
        return false
    }
}
