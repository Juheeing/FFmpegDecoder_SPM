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
