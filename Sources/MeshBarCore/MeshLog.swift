import Foundation

/// Process-wide log for JNAP shape surprises.
///
/// Messages name fields. They never include payload values, so a passphrase,
/// serial, or MAC that shows up in an unexpected object cannot land in the log.
public enum MeshLog {
    public static var handler: (String) -> Void = { message in
        fputs(message + "\n", stderr)
    }

    private static let lock = NSLock()
    private static var seen: Set<String> = []

    public static func debug(_ message: String) {
        handler("[MeshBar] \(message)")
    }

    /// Log field names we do not model yet. Safe to call on every poll; each
    /// `context.field` pair is reported once per process.
    public static func unknownShape(_ context: String, keys: [String], known: Set<String>) {
        let novel = keys.filter { !known.contains($0) }.sorted()
        guard !novel.isEmpty else { return }
        lock.lock()
        let fresh = novel.filter { seen.insert("\(context).\($0)").inserted }
        lock.unlock()
        guard !fresh.isEmpty else { return }
        debug("Unknown \(context) field(s): \(fresh.joined(separator: ", ")). Ignored so a firmware change cannot crash parsing.")
    }

    /// Log a shape problem (wrong JSON type, skipped entry). The message must
    /// be written by us and must not include router payload values.
    public static func shape(_ message: String) {
        lock.lock()
        let fresh = seen.insert("msg:\(message)").inserted
        lock.unlock()
        guard fresh else { return }
        debug(message)
    }

    static func resetForTests() {
        lock.lock()
        seen.removeAll()
        lock.unlock()
    }
}
