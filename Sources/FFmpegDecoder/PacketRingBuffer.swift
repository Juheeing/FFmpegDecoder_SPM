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
        let streamIndex: Int32
        
        init(pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool, streamIndex: Int32) {
            self.pkt = pkt
            self.ptsMs = ptsMs
            self.isKey = isKey
            self.streamIndex = streamIndex
        }
    }

    private var buffer: [Item] = []
    private let maxCount = 3600
    private let lock = NSLock()
    private var readStart = false
    
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readStart && buffer.isEmpty
    }
    
    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool, streamIndex: Int32) {

        // 반드시 clone/ref 해서 소유권 분리
        guard let copy = av_packet_clone(pkt) else { return }

        readStart = true
        
        let item = Item(pkt: copy, ptsMs: ptsMs, isKey: isKey, streamIndex: streamIndex)

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
