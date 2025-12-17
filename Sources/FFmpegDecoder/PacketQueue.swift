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
    private(set) var isAborted = false

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    // MARK: - Push

    func push(_ packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        defer { lock.unlock() }

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        
        if isAborted {
            av_packet_free(&pkt)
            return
        }

        if queue.count >= maxSize {
            av_packet_free(&pkt)
            return
        }

        queue.append(packet)
        condition.signal()
    }

    // MARK: - Pop (blocking)

    func pop(blocking: Bool = true) -> UnsafeMutablePointer<AVPacket>? {
        lock.lock()
        defer { lock.unlock() }

        while queue.isEmpty && !isAborted {
            if !blocking {
                return nil
            }
            condition.wait()
        }

        if isAborted {
            return nil
        }

        return queue.removeFirst()
    }

    // MARK: - Control

    func flush() {
        lock.lock()
        defer { lock.unlock() }

        for pkt in queue {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        queue.removeAll()
    }

    func abort() {
        lock.lock()
        isAborted = true
        condition.broadcast()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        let c = queue.count
        lock.unlock()
        return c
    }

    var isFull: Bool {
        return count >= maxSize
    }

    var isEmpty: Bool {
        return count == 0
    }
}


