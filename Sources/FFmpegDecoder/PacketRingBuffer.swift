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
    private var readStart = false
    
    var isEmpty: Bool {
        if !readStart { return false }
        lock.lock()
        let empty = buffer.isEmpty
        lock.unlock()
        return empty
    }
    
    var bufferedDurationMs: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let first = buffer.first, let last = buffer.last else { return 0 }
        return last.ptsMs - first.ptsMs
    }
    
    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {

        readStart = true
        
        let item = Item(pkt: pkt, ptsMs: ptsMs, isKey: isKey)

        lock.lock()
        buffer.append(item)

        if buffer.count > maxCount {
            let drop = buffer.removeFirst()
            av_packet_free(&drop.pkt)
            drop.pkt = nil
        }
        lock.unlock()
    }

    func pop() -> Item? {
        lock.lock()
        let item = buffer.isEmpty ? nil : buffer.removeFirst()
        lock.unlock()
        return item
    }
    
    func seek(to targetMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return false }

        // target 이전 패킷 중 가장 가까운 keyframe 찾기
        var index: Int?

        for i in stride(from: buffer.count - 1, through: 0, by: -1) {
            let item = buffer[i]
            if item.ptsMs <= targetMs && item.isKey {
                index = i
                break
            }
        }

        guard let foundIndex = index else {
            return false
        }

        // foundIndex 이전 패킷 제거
        for i in 0..<foundIndex {
            av_packet_free(&buffer[i].pkt)
            buffer[i].pkt = nil
        }
        buffer.removeFirst(foundIndex)

        print("FFmpeg## PacketBuffer local seek success → \(buffer.first?.ptsMs ?? 0)ms")
        return true
    }
    
    func clear() {
        lock.lock()
        readStart = false
        for i in 0..<buffer.count {
            av_packet_free(&buffer[i].pkt)
            buffer[i].pkt = nil
        }
        buffer.removeAll()
        lock.unlock()
    }
}
