//
//  PacketRingBuffer.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 1/8/2569 BE.
//

import Foundation
import FFmpegHeaders

final class PacketRingBuffer {

    // MARK: - Item
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

    // MARK: - Storage
    private var buffer: [Item] = []          // seek용 전체 버퍼
    private var decodeQueue: [Item] = []     // 실제 소비 큐
    
    private let maxCount = 3600
    private let lock = NSLock()
    private var readStart = false

    // MARK: - State

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readStart && decodeQueue.isEmpty
    }
    
    var bufferedDurationMs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let first = buffer.first, let last = buffer.last else { return 0 }
        return last.ptsMs - first.ptsMs
    }

    // MARK: - Push

    func push(_ pkt: UnsafeMutablePointer<AVPacket>, ptsMs: Int64, isKey: Bool) {
        let item = Item(pkt: pkt, ptsMs: ptsMs, isKey: isKey)

        lock.lock()
        defer { lock.unlock() }

        readStart = true
        
        buffer.append(item)
        decodeQueue.append(item)

        // 오래된 패킷 drop
        if buffer.count > maxCount {
            let drop = buffer.removeFirst()
            
            // decodeQueue에도 존재하면 같이 제거
            if let idx = decodeQueue.firstIndex(where: { $0 === drop }) {
                decodeQueue.remove(at: idx)
            }

            av_packet_free(&drop.pkt)
            drop.pkt = nil
        }
    }

    // MARK: - Pop (decode 전용)

    func pop() -> Item? {
        lock.lock()
        defer { lock.unlock() }

        guard !decodeQueue.isEmpty else { return nil }
        return decodeQueue.removeFirst()
    }

    // MARK: - Seek

    func seek(to targetMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return false }

        // target 이전 가장 가까운 keyframe 찾기
        var foundIndex: Int?

        for i in stride(from: buffer.count - 1, through: 0, by: -1) {
            let item = buffer[i]
            if item.ptsMs <= targetMs && item.isKey {
                foundIndex = i
                break
            }
        }

        guard let index = foundIndex else {
            return false
        }

        // decodeQueue 재구성
        decodeQueue.removeAll(keepingCapacity: true)
        decodeQueue.append(contentsOf: buffer[index...])

        print("FFmpeg## PacketBuffer local seek success → \(buffer[index].ptsMs)ms")
        return true
    }

    // MARK: - Clear

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        readStart = false

        for item in buffer {
            av_packet_free(&item.pkt)
            item.pkt = nil
        }

        buffer.removeAll()
        decodeQueue.removeAll()
    }
}

