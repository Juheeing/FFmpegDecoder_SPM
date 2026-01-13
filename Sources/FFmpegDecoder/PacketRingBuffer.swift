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
    
    var isEmpty: Bool {
        lock.lock()
        let empty = buffer.isEmpty
        lock.unlock()
        return empty
    }
    
    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {

        // 반드시 clone/ref 해서 소유권 분리
        guard let copy = av_packet_clone(pkt) else { return }

        let item = Item(pkt: copy, ptsMs: ptsMs, isKey: isKey)

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
        for i in 0..<buffer.count {
            av_packet_free(&buffer[i].pkt)
            buffer[i].pkt = nil
        }
        buffer.removeAll()
        lock.unlock()
    }
}
