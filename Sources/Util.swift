import Foundation

let mgnovVersion = "0.1.0"

enum Clock {
    /// Monotonic seconds.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// A Double rounded to `digits` decimal places.
func num(_ x: Double, _ digits: Int = 1) -> Double {
    let p = pow(10.0, Double(digits))
    return (x * p).rounded() / p
}

func short(_ id: String) -> String {
    id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
      .replacingOccurrences(of: "com.apple.inputmethod.", with: "")
}

/// Run `f` on the main thread synchronously (the event tap and all agent state live there).
func onMain<T>(_ f: () -> T) -> T {
    if Thread.isMainThread { return f() }
    return DispatchQueue.main.sync(execute: f)
}

enum Log {
    private static let lock = NSLock()
    private static var ring: [String] = []
    private static var handle: FileHandle?
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return d }()

    static func setup(file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        handle?.seekToEndOfFile()
    }
    static func info(_ m: String) { write("INFO", m) }
    static func warn(_ m: String) { write("WARN", m) }
    static func error(_ m: String) { write("ERR ", m) }
    private static func write(_ level: String, _ m: String) {
        let line = "\(df.string(from: Date())) [\(level)] \(m)"
        lock.lock()
        ring.append(line)
        if ring.count > 3000 { ring.removeFirst(1000) }
        lock.unlock()
        if let d = (line + "\n").data(using: .utf8) {
            handle?.write(d)
            FileHandle.standardError.write(d)
        }
    }
    static func recent(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring.suffix(n))
    }
}
