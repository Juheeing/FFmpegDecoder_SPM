//
//  PacketQueue.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 12/17/2568 BE.
//

import Foundation
import FFmpegHeaders

final class PacketQueue {
    private var queue: [UnsafeMutablePointer<AVPacket>] = []
    private let lock = NSLock()
    private let condition = NSCondition()
    let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    func push(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if queue.count >= maxSize {
            return false
        }

        let ref = av_packet_alloc()
        av_packet_ref(ref, pkt)
        queue.append(ref!)
        condition.signal()
        return true
    }

    func pop(blocking: Bool = true) -> UnsafeMutablePointer<AVPacket>? {
        lock.lock()
        defer { lock.unlock() }

        while queue.isEmpty {
            if !blocking { return nil }
            condition.wait()
        }

        return queue.removeFirst()
    }

    func clear() {
        lock.lock()
        for pkt in queue {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        queue.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }
}


