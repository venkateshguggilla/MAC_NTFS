// BlockDevice.swift - feeds an FSBlockDeviceResource to the engine as an mn_io.
//
// An FSKit extension is sandboxed and cannot open /dev nodes itself; all disk
// I/O must go through the resource FSKit hands to loadResource().

import Foundation
import FSKit

final class BlockDevice {
    let resource: FSBlockDeviceResource

    init(_ resource: FSBlockDeviceResource) {
        self.resource = resource
    }

    /// An mn_io that keeps this object alive until the engine releases it.
    func makeIO(writable: Bool) -> mn_io {
        var io = mn_io()
        io.ctx = Unmanaged.passRetained(self).toOpaque()
        io.block_size = UInt32(resource.blockSize)
        io.size = resource.blockSize * resource.blockCount
        io.read = { ctx, buf, offset, len, done in
            let dev = Unmanaged<BlockDevice>.fromOpaque(ctx!).takeUnretainedValue()
            do {
                let n = try dev.resource.read(into: UnsafeMutableRawBufferPointer(start: buf, count: len),
                                              startingAt: off_t(offset), length: len)
                done!.pointee = n
                return 0
            } catch {
                return posixCode(error)
            }
        }
        if writable {
            io.write = { ctx, buf, offset, len in
                let dev = Unmanaged<BlockDevice>.fromOpaque(ctx!).takeUnretainedValue()
                do {
                    var written = 0
                    while written < len {
                        let n = try dev.resource.write(
                            from: UnsafeRawBufferPointer(start: buf! + written, count: len - written),
                            startingAt: off_t(offset) + off_t(written), length: len - written)
                        if n <= 0 { return EIO }
                        written += n
                    }
                    return 0
                } catch {
                    return posixCode(error)
                }
            }
        }
        // Plain reads/writes on the resource go straight to the device.
        io.sync = { _ in 0 }
        io.release = { ctx in
            Unmanaged<BlockDevice>.fromOpaque(ctx!).release()
        }
        return io
    }

    /// Read the first block(s), enough for the NTFS boot sector.
    func readBootSector() throws -> Data {
        let len = max(512, Int(resource.blockSize))
        var data = Data(count: len)
        let n = try data.withUnsafeMutableBytes {
            try resource.read(into: $0, startingAt: 0, length: len)
        }
        return data.prefix(n)
    }
}

func posixCode(_ error: Error) -> Int32 {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain, ns.code > 0 { return Int32(ns.code) }
    return EIO
}
