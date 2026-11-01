import Foundation

/// Tiny line-based JSON protocol over a Unix domain socket. One request, one reply, close.
/// The agent serves it; the CLI (which needs no permissions) is the client.
enum Sock {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < 104 else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, path) }
        }
        return addr
    }
    static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if buf[n - 1] == 10 { break }
        }
        return data
    }
    static func writeAll(_ fd: Int32, _ data: Data) {
        var off = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while off < data.count {
                let n = write(fd, base + off, data.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}

final class ControlServer {
    private let fd: Int32

    init?(path: String, handler: @escaping ([String: Any]) -> [String: Any]) {
        unlink(path)
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        fd = sfd
        guard sfd >= 0, var addr = Sock.address(path) else { return nil }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, len) } }
        guard bound == 0, listen(sfd, 8) == 0 else { close(sfd); return nil }
        chmod(path, 0o600)
        let t = Thread {
            while true {
                let c = accept(sfd, nil, nil)
                if c < 0 { usleep(100_000); continue }
                Thread { ControlServer.serve(c, handler) }.start()
            }
        }
        t.name = "mgnov-control"
        t.start()
    }

    private static func serve(_ c: Int32, _ handler: ([String: Any]) -> [String: Any]) {
        defer { close(c) }
        let data = Sock.readLine(c)
        let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var resp = handler(req)
        if resp["ok"] == nil { resp["ok"] = true }
        guard var out = try? JSONSerialization.data(withJSONObject: resp) else {
            Sock.writeAll(c, Data("{\"ok\":false,\"error\":\"unserializable reply\"}\n".utf8)); return
        }
        out.append(10)
        Sock.writeAll(c, out)
    }
}

enum ControlClient {
    static func send(_ req: [String: Any], path: String) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = Sock.address(path) else { return nil }
        defer { close(fd) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        guard r == 0, var d = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        d.append(10)
        Sock.writeAll(fd, d)
        let resp = Sock.readLine(fd)
        return (try? JSONSerialization.jsonObject(with: resp)) as? [String: Any]
    }
}
