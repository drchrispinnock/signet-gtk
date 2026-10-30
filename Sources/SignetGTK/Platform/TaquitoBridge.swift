import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hosts the bundled Taquito script (`taquito-bridge.js`) inside JavaScriptCore and exposes
/// its exported functions to Swift as async calls.
///
/// The Linux counterpart of upstream's `Signet/Services/TaquitoBridge.swift`, kept in the same
/// order with the same names so the two can be read side by side. The differences:
/// - JavaScriptCore is reached through its GLib API (`JavaScriptCore.swift` here), whose
///   context must stay on the thread that made it, so the bridge runs on a `ThreadQueue` (one
///   dedicated thread) instead of a `DispatchQueue`.
/// - Natives are `JSValue(function:in:)` closures over their arguments, not
///   `@convention(block)` blocks, which need the Objective-C runtime.
/// - swift-corelibs-foundation never calls a task's own delegate, so fetches share one session
///   whose delegate hands each task's events to its `ResponseCollector`.
/// - Randomness is `SystemRandomNumberGenerator` (getrandom or arc4random), not `SecRandom`.
/// - The log is `$XDG_STATE_HOME/signet/bridge.log` rather than `~/Library/Logs/Signet`.
///
/// The polyfills in `TaquitoBridge/src/polyfills.js` call back into the `__signet` native object
/// installed here for timers, HTTP and randomness; those run on the same thread.
///
/// Secret keys enter the JavaScript runtime only for the one operation they sign (Taquito's
/// `InMemorySigner`, see `src/signers.js`) and are not kept there; Ledger keys never leave the
/// device.
final class TaquitoBridge: @unchecked Sendable {
    enum BridgeError: LocalizedError {
        case bundleMissing
        case loadFailed(String)
        case javaScript(String)
        case notAFunction(String)
        case notASigningCall(String)
        case timedOut(String, TimeInterval)
        case responseTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .bundleMissing: "taquito-bridge.js is missing from the app bundle (run `npm run build` in TaquitoBridge/)"
            case .loadFailed(let message): "Taquito bridge failed to load: \(message)"
            case .javaScript(let message): message
            case .notAFunction(let name): "TaquitoBridge.\(name) is not a function"
            case .notASigningCall(let name): "TaquitoBridge.\(name) is not declared as a signing call"
            case .timedOut(let name, let seconds): "\(name) did not finish within \(Int(seconds)) seconds."
            case .responseTooLarge(let limit): "The server's reply was larger than \(limit / (1024 * 1024)) MB and was dropped."
            }
        }
    }

    /// The most a single HTTP reply may carry into JavaScript (S19). Blocks fetched while waiting
    /// for an operation are the largest legitimate replies and stay well under this.
    static let maxResponseBytes = 32 * 1024 * 1024

    static let shared = TaquitoBridge()

    private let callGate = BridgeCallGate()
    private let queue = ThreadQueue(label: "org.tezos.signet.taquito-bridge")
    private let session: URLSession
    private let fetchDelegate = FetchDelegate()
    private var context: JSContext?
    private var loadError: Error?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var fetches: [Int: URLSessionDataTask] = [:]
    private var publicFetches: [Int: Task<Void, Never>] = [:]
    private let requirePublicEndpoints: Bool
    private var contextGeneration = UUID()
    private var ledgerLeases: [Int: (UUID, String)] = [:]
    private var ledgerWaiters: [Int: Task<Void, Never>] = [:]
    private var activeCallID: UUID?
    private var cancelCurrentCall: (() -> Void)?
    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    /// Per-fetch collectors that stop a reply at `maxResponseBytes`; keyed like `fetches`.
    private var collectors: [Int: ResponseCollector] = [:]

    /// Backing store for the Octez Connect SDK. Set before the first call that loads the bundle.
    var storage: any BridgeStorage {
        get { lock.withLock { _storage } }
        set { lock.withLock { _storage = newValue } }
    }
    private var _storage: any BridgeStorage

    /// Receives JSON events pushed from JavaScript (dApp requests). Called on the bridge thread.
    var eventHandler: (@Sendable (String) -> Void)? {
        get { lock.withLock { _eventHandler } }
        set { lock.withLock { _eventHandler = newValue } }
    }
    private var _eventHandler: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    var operationJournal = OperationJournal()
    private var logURL: URL?
    private let systemLog: @Sendable (String) -> Void
    var configuredLogURL: URL? { lock.withLock { logURL } }
    func configureLog(at url: URL?) {
        lock.withLock {
            try? logHandle?.close()
            logHandle = nil
            logURL = url
            logBytes = 0
        }
    }

    init(session: URLSession = .shared, storage: any BridgeStorage = InMemoryBridgeStorage(), logURL: URL? = nil, requirePublicEndpoints: Bool = false,
         systemLog: @escaping @Sendable (String) -> Void = { NSLog("TaquitoBridge %@", $0) }) {
        // The caller's configuration (protocol classes included) with our delegate in charge.
        self.session = URLSession(configuration: session.configuration, delegate: fetchDelegate, delegateQueue: nil)
        self.requirePublicEndpoints = requirePublicEndpoints
        self._storage = storage
        self.logURL = logURL
        self.systemLog = systemLog
    }

    // MARK: - Public API

    /// What a bridge export may do, which decides how its call is treated (S30): a read gets a
    /// deadline and is cancelled with the caller; a signing call runs to its outcome.
    enum CallKind: Sendable { case read, signing }

    /// Every export that signs, injects or holds a Ledger session. A call to one of these has no
    /// deadline and is never cancelled: abandoning it could lose an operation outcome or release
    /// a device still signing. `npm test` (signing-exports.cjs) checks the JavaScript sources against this
    /// list, so a new export that signs cannot be left out unnoticed.
    static let signingCalls: Set<String> = [
        "sendTransfer", "sendStakingOperation", "sendRawOperation", "sendGovernanceOperation", "sendEtherlinkDeposit", "sendEtherlinkLink", "sendEtherlinkGovernance", "sendShieldDeposit", "sendOutboxExecution",
        "injectSignedBytes", "multisigOriginate", "multisigSubmit", "multisigSign", "signPayload", "provePossession",
        "octezConnectExecute", "octezConnectSign", "ledgerGetAddress", "ledgerAppVersion",
    ]

    static func kind(of name: String) -> CallKind { signingCalls.contains(name) ? .signing : .read }

    /// The entry point for a signing or injecting call: `name` must be declared in
    /// `signingCalls`, so a caller cannot sign through a cancellable read by mistake.
    func sign(_ name: String, _ args: [any Sendable] = []) async throws -> JSONValue {
        guard Self.kind(of: name) == .signing else { throw BridgeError.notASigningCall(name) }
        return try await call(name, args)
    }

    /// Calls `TaquitoBridge.<name>(...args)` and awaits the result, unwrapping promises.
    ///
    /// Read/preparation deadlines cancel HTTP work and discard the context before reuse.
    /// Signing, injection and complete Ledger sessions (`signingCalls`) have no generic
    /// deadline, whichever entry point they come through.
    func call(_ name: String, _ args: [any Sendable] = [], timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await callGate.acquire()
        defer { Task { await callGate.release() } }
        try Task.checkCancellation()
        // Hardware approval and any call that can sign/inject must complete with an outcome.
        let signing = Self.kind(of: name) == .signing
        let deadline = signing ? nil : (timeout ?? 60)
        guard args.reduce(0, { $0 + (($1 as? String)?.utf8.count ?? 0) }) <= 2 << 20 else {
            throw BridgeError.javaScript("Bridge arguments exceed the input budget")
        }
        let callID = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            queue.async {
                do {
                    if cancellation.isCancelled { throw CancellationError() }
                    self.activeCallID = callID
                    let context = try self.loadedContext()
                    guard let api = context.objectForKeyedSubscript("TaquitoBridge"),
                          let function = api.objectForKeyedSubscript(name),
                          !function.isUndefined
                    else { throw BridgeError.notAFunction(name) }

                    context.exception = nil
                    guard let result = function.call(withArguments: args.map { $0 as Any? }) else {
                        throw BridgeError.javaScript("no result from \(name)")
                    }
                    if let exception = context.exception {
                        context.exception = nil
                        throw BridgeError.javaScript(exception.toString())
                    }
                    self.resolve(result, in: context, name: name, timeout: deadline, continuation: continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
          }
        } onCancel: {
            cancellation.cancel()
            // Signing cannot be abandoned after crossing the signing/injection boundary.
            if !signing {
                self.queue.async { if self.activeCallID == callID { self.cancelCurrentCall?() } }
            }
        }
    }

    // MARK: - Promise handling

    private func resolve(_ value: JSValue, in context: JSContext, name: String, timeout: TimeInterval?, continuation: CheckedContinuation<JSONValue, Error>) {
        guard value.isObject, let then = value.objectForKeyedSubscript("then"), !then.isUndefined else {
            continuation.resume(returning: JSONValue(bridged: value.toObject()))
            return
        }
        // Box the continuation so exactly one of the closures consumes it.
        final class Once: @unchecked Sendable {
            var continuation: CheckedContinuation<JSONValue, Error>?
            init(_ c: CheckedContinuation<JSONValue, Error>) { continuation = c }
        }
        let once = Once(continuation)
        self.cancelCurrentCall = { [weak self] in
            guard let c = once.continuation else { return }
            once.continuation = nil
            self?.cancelCurrentCall = nil
            self?.discardContext()
            c.resume(throwing: CancellationError())
        }
        let onFulfilled = JSValue(function: "onFulfilled", in: context) { args in
            guard let c = once.continuation else { return nil }
            once.continuation = nil
            self.cancelCurrentCall = nil
            c.resume(returning: JSONValue(bridged: args.first?.toObject()))
            return nil
        }
        let onRejected = JSValue(function: "onRejected", in: context) { args in
            guard let c = once.continuation else { return nil }
            once.continuation = nil
            self.cancelCurrentCall = nil
            let reason = args.first
            let message = reason?.objectForKeyedSubscript("message").flatMap { $0.isUndefined ? nil : $0.toString() }
                ?? reason?.toString() ?? "unknown error"
            c.resume(throwing: BridgeError.javaScript(message))
            return nil
        }
        context.exception = nil
        // Must be invoked as a method so `this` is the promise; a bare `then.call` throws and
        // would leak the continuation.
        value.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        if let exception = context.exception, let c = once.continuation {
            once.continuation = nil
            context.exception = nil
            c.resume(throwing: BridgeError.javaScript(exception.toString()))
        }
        if let timeout, once.continuation != nil {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let c = once.continuation else { return }
                once.continuation = nil
                self?.cancelCurrentCall = nil
                self?.discardContext()
                self?.note("\(name) timed out after \(Int(timeout)) s")
                c.resume(throwing: BridgeError.timedOut(name, timeout))
            }
        }
    }

    private func discardContext() {
        contextGeneration = UUID()
        for waiter in ledgerWaiters.values { waiter.cancel() }
        for lease in ledgerLeases.values { Task { await LedgerSessions.shared.release(id: lease.0, device: lease.1) } }
        ledgerWaiters.removeAll(); ledgerLeases.removeAll()
        for task in fetches.values { task.cancel() }
        for task in publicFetches.values { task.cancel() }
        for timer in timers.values { timer.cancel() }
        fetches.removeAll(); publicFetches.removeAll(); collectors.removeAll(); timers.removeAll()
        context = nil
        eventHandler?("{\"kind\":\"stopped\",\"message\":\"The dApp connection timed out; reconnect before signing.\"}")
    }

    // MARK: - Loading

    private func loadedContext() throws -> JSContext {
        precondition(queue.isCurrent)
        if let context { return context }
        if let loadError { throw loadError }
        do {
            let context = try makeContext()
            self.context = context
            return context
        } catch {
            loadError = error
            throw error
        }
    }

    private func makeContext() throws -> JSContext {
        guard let url = Bundle.module.url(forResource: "taquito-bridge", withExtension: "js")
        else { throw BridgeError.bundleMissing }
        let source = try String(contentsOf: url, encoding: .utf8)

        guard let context = JSContext() else { throw BridgeError.loadFailed("could not create JSContext") }
        var firstException: String?
        context.exceptionHandler = { _, exception in
            if firstException == nil { firstException = exception.toString() }
        }
        installConsole(in: context)
        installNatives(in: context)

        context.evaluateScript(source, withSourceURL: url)
        if let firstException { throw BridgeError.loadFailed(firstException) }
        guard let api = context.objectForKeyedSubscript("TaquitoBridge"), api.isObject else {
            throw BridgeError.loadFailed("TaquitoBridge global not defined after evaluating bundle")
        }
        // Route later uncaught exceptions to the log instead of silently swallowing them; like
        // every other line they are redacted and capped before any sink sees them (S11).
        context.exceptionHandler = { [weak self] _, exception in
            self?.record("[exception] \(exception.toString())")
        }
        return context
    }

    /// Last few hundred console lines from JavaScript, newest last. Handy when the system log is
    /// not available (tests, support).
    var consoleLines: [String] { lock.withLock { _consoleLines } }
    private var _consoleLines: [String] = []

    private func installConsole(in context: JSContext) {
        let log = JSValue(function: "__signet_log", in: context) { [weak self] args in
            self?.record("[\(args.string(0))] \(args.string(1))")
            return nil
        }
        context.setObject(log, forKeyedSubscript: "__signet_log")
        context.evaluateScript("""
        var console = (function () {
          function fmt(args) { return Array.prototype.map.call(args, function (a) {
            if (a instanceof Error) return a.message + (a.stack ? "\\n" + a.stack : "");
            if (typeof a === "object") { try { return JSON.stringify(a); } catch (e) { return String(a); } }
            return String(a);
          }).join(" "); }
          return {
            log: function () { __signet_log("log", fmt(arguments)); },
            info: function () { __signet_log("info", fmt(arguments)); },
            warn: function () { __signet_log("warn", fmt(arguments)); },
            error: function () { __signet_log("error", fmt(arguments)); },
            debug: function () { __signet_log("debug", fmt(arguments)); },
            trace: function () { __signet_log("trace", fmt(arguments)); },
            group: function () { __signet_log("group", fmt(arguments)); },
            groupCollapsed: function () { __signet_log("group", fmt(arguments)); },
            groupEnd: function () {},
            table: function () { __signet_log("table", fmt(arguments)); },
            dir: function () { __signet_log("dir", fmt(arguments)); },
            assert: function (ok) { if (!ok) __signet_log("assert", fmt(Array.prototype.slice.call(arguments, 1))); },
            count: function () {}, countReset: function () {},
            time: function () {}, timeEnd: function () {}, timeLog: function () {},
          };
        })();
        """)
    }

    private func installNatives(in context: JSContext) {
        let native = JSValue(newObjectIn: context)
        func define(_ name: String, _ body: @escaping ([JSValue]) -> Any?) {
            native.setObject(JSValue(function: name, in: context, body), forKeyedSubscript: name)
        }

        define("setTimer") { [weak self] args in
            guard let self else { return nil }
            let id = args.int(0), ms = args.double(1)
            let generation = self.contextGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.contextGeneration == generation, self.timers.removeValue(forKey: id) != nil else { return }
                self.context?.objectForKeyedSubscript("__signet_timerFired")?.call(withArguments: [id])
            }
            self.timers[id] = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: work)
            return nil
        }
        define("clearTimer") { [weak self] args in
            self?.timers.removeValue(forKey: args.int(0))?.cancel()
            return nil
        }
        define("randomBytes") { args in
            let count = args.int(0)
            guard count >= 0, count <= 1 << 20 else { return [UInt8]() }
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        define("fetch") { [weak self] args in
            self?.startFetch(id: args.int(0), urlString: args.string(1), method: args.string(2), headersJSON: args.string(3), body: args.count > 4 ? args[4] : nil)
            return nil
        }
        define("cancelFetch") { [weak self] args in
            let id = args.int(0)
            self?.fetches.removeValue(forKey: id)?.cancel()
            self?.publicFetches.removeValue(forKey: id)?.cancel()
            return nil
        }

        define("operationRead") { [weak self] _ in
            do { return try self?.operationJournal.read() ?? "[]" }
            catch { return "{\"error\":\"Operation recovery storage cannot be read\"}" }
        }
        define("operationSave") { [weak self] args in
            do { guard let self else { return "Bridge unavailable" }; try self.operationJournal.save(args.string(0)); return "" }
            catch { return "Could not persist the signed operation; nothing was injected" }
        }
        define("operationRemove") { [weak self] args in
            do { try self?.operationJournal.remove(args.string(0)); return "" }
            catch { return "Could not update operation recovery storage" }
        }

        define("storageGet") { [weak self] args in self?.storage.get(args.string(0)) ?? NSNull() }
        define("storageSet") { [weak self] args in self?.storage.set(args.string(0), args.string(1)); return nil }
        define("storageDelete") { [weak self] args in self?.storage.delete(args.string(0)); return nil }
        define("octezConnectEvent") { [weak self] args in self?.eventHandler?(args.string(0)); return nil }

        define("ledgerSessionBegin") { [weak self] args in
            guard let self else { return nil }
            let id = args.int(0), device = args.string(1)
            let generation = self.contextGeneration
            self.ledgerWaiters[id] = Task {
                do {
                    let token = try await LedgerSessions.shared.acquire(device: device)
                    self.queue.async {
                        guard self.contextGeneration == generation else {
                            Task { await LedgerSessions.shared.release(id: token, device: device) }
                            return
                        }
                        self.ledgerWaiters[id] = nil
                        self.ledgerLeases[id] = (token, device)
                        self.context?.objectForKeyedSubscript("__signet_ledgerSessionReady")?.call(withArguments: [id, NSNull()])
                    }
                } catch {
                    let message = error.localizedDescription
                    self.queue.async {
                        guard self.contextGeneration == generation else { return }
                        self.ledgerWaiters[id] = nil
                        self.context?.objectForKeyedSubscript("__signet_ledgerSessionReady")?.call(withArguments: [id, message])
                    }
                }
            }
            return nil
        }
        define("ledgerSessionEnd") { [weak self] args in
            guard let lease = self?.ledgerLeases.removeValue(forKey: args.int(0)) else { return nil }
            Task { await LedgerSessions.shared.release(id: lease.0, device: lease.1) }
            return nil
        }

        // Ledger: USB HID is native (LedgerHID); the bridge's Transport subclass calls these.
        define("ledgerDevices") { _ in
            let list = LedgerHID.shared.devices().map { ["id": $0.id, "name": $0.name, "model": $0.model, "productID": $0.productID] as [String: Any] }
            return (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        define("ledgerExchange") { [weak self] args in
            guard let self else { return nil }
            let id = args.int(0), deviceID = args.string(1), apduHex = args.string(2), timeoutMs = args.double(3)
            self.trace("ledger #\(id) → \(apduHex.prefix(8)) \(apduHex.count / 2) bytes")
            LedgerHID.shared.exchange(deviceID: deviceID, apdu: Self.bytes(fromHex: apduHex), timeout: timeoutMs / 1000, completionQueue: self.queue) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let bytes):
                    let hex = bytes.map { String(format: "%02x", $0) }.joined()
                    self.trace("ledger #\(id) ← \(hex.suffix(4))")
                    self.context?.objectForKeyedSubscript("__signet_ledgerDone")?.call(withArguments: [id, hex, NSNull()])
                case .failure(let error):
                    self.trace("ledger #\(id) ← \(error.localizedDescription)")
                    self.context?.objectForKeyedSubscript("__signet_ledgerDone")?.call(withArguments: [id, "", error.localizedDescription])
                }
            }
            return nil
        }
        context.setObject(native, forKeyedSubscript: "__signet")
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }

    // MARK: - fetch

    /// Collects a reply as it streams and cancels the task once it passes the size limit (S19),
    /// so an oversized or endless body never reaches JavaScript or memory.
    private final class ResponseCollector: @unchecked Sendable {
        let limit: Int
        var data = Data()
        var overflowed = false
        let completion: (Data?, URLResponse?, Error?, Bool) -> Void

        init(limit: Int, completion: @escaping (Data?, URLResponse?, Error?, Bool) -> Void) {
            self.limit = limit
            self.completion = completion
        }

        func received(_ chunk: Data, on dataTask: URLSessionDataTask) {
            data.append(chunk)
            if data.count > limit {
                overflowed = true
                data = Data()
                dataTask.cancel()
            }
        }

        func completed(_ task: URLSessionTask, error: Error?) {
            completion(overflowed ? nil : data, task.response, error, overflowed)
        }
    }

    /// The session's delegate: hands each task's events to the collector registered for it.
    private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var collectors: [Int: ResponseCollector] = [:]

        func register(_ collector: ResponseCollector, for task: URLSessionTask) {
            lock.withLock { collectors[task.taskIdentifier] = collector }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.withLock { collectors[dataTask.taskIdentifier] }?.received(chunk, on: dataTask)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock { collectors.removeValue(forKey: task.taskIdentifier) }?.completed(task, error: error)
        }
    }

    private func startFetch(id: Int, urlString: String, method: String, headersJSON: String, body: JSValue?) {
        precondition(queue.isCurrent)
        trace("fetch #\(id) \(method) \(Self.redacted(urlString))")
        guard let url = URL(string: urlString) else {
            finishFetch(id: id, error: "Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let data = headersJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        if let body, !body.isNull, !body.isUndefined {
            request.httpBody = body.toString().data(using: .utf8)
        }

        guard fetches.count + publicFetches.count < 32 else {
            finishFetch(id: id, error: "Too many active bridge HTTP requests")
            return
        }
        let generation = contextGeneration
        if requirePublicEndpoints {
            let request = request
            publicFetches[id] = Task {
                do {
                    let reply = try await PublicHTTPClient.data(for: request, limit: Self.maxResponseBytes)
                    self.queue.async {
                        guard self.contextGeneration == generation, self.publicFetches.removeValue(forKey: id) != nil else { return }
                        guard JSONBudget.accepts(reply.data) else {
                            self.finishFetch(id: id, error: "The server's reply exceeds the JSON parsing budget")
                            return
                        }
                        let headers = (try? JSONSerialization.data(withJSONObject: reply.headers)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        self.finishFetch(id: id, status: reply.status, statusText: "", headersJSON: headers, body: String(decoding: reply.data, as: UTF8.self))
                    }
                } catch {
                    let message = error.localizedDescription
                    self.queue.async {
                        guard self.contextGeneration == generation, self.publicFetches.removeValue(forKey: id) != nil else { return }
                        self.finishFetch(id: id, error: message)
                    }
                }
            }
            return
        }

        let collector = ResponseCollector(limit: Self.maxResponseBytes) { [weak self] data, response, error, overflowed in
            guard let self else { return }
            nonisolated(unsafe) let response = response
            self.queue.async {
                guard self.contextGeneration == generation else { return }
                self.collectors.removeValue(forKey: id)
                guard self.fetches.removeValue(forKey: id) != nil else { return } // cancelled
                if overflowed {
                    self.finishFetch(id: id, error: BridgeError.responseTooLarge(Self.maxResponseBytes).localizedDescription)
                    return
                }
                if let error {
                    self.finishFetch(id: id, error: error.localizedDescription)
                    return
                }
                if let data, !JSONBudget.accepts(data) {
                    self.finishFetch(id: id, error: "The server's reply exceeds the JSON parsing budget")
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                let headerPairs = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { acc, pair in
                    acc[String(describing: pair.key).lowercased()] = String(describing: pair.value)
                }
                let headersJSON = (try? JSONSerialization.data(withJSONObject: headerPairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.finishFetch(id: id, status: status, statusText: HTTPURLResponse.localizedString(forStatusCode: status), headersJSON: headersJSON, body: text)
            }
        }
        let task = session.dataTask(with: request)
        fetchDelegate.register(collector, for: task)
        collectors[id] = collector
        fetches[id] = task
        task.resume()
    }

    /// A URL as it may appear in the log: scheme, host and path only. Query strings and
    /// fragments can carry tokens (the relay's sync endpoint does) and are dropped (S11).
    static func redacted(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host() else { return "<url>" }
        var path = url.path(percentEncoded: true)
        if path.count > 80 { path = String(path.prefix(80)) + "…" }
        return "\(url.scheme ?? "")://\(host)\(path)"
    }

    /// A log line with anything that could be a secret or private content kept out: at most
    /// `maxLineLength` characters, and hex or base58 runs long enough to be keys, signatures or
    /// payloads replaced by their length (S11).
    static let maxLineLength = 1024
    static func redactedLine(_ line: String) -> String {
        var text = line.replacing(/[0-9a-fA-F]{48,}/) { "<\($0.output.count) hex chars>" }
        text = text.replacing(/\b(edsk|edesk|spsk|spesk|p2sk|p2esk|BLsk|BLesk|mdsk|mdesk|edsig|spsig1|p2sig|BLsig|mdsig|sig)[1-9A-HJ-NP-Za-km-z]{20,}/) { "\($0.output.1)<redacted>" }
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
        return text
    }

    /// Appends a line to `consoleLines` from Swift (fetch tracing).
    private func trace(_ line: String) {
        record("[host] \(line)")
    }

    /// Lets Swift code leave a line in the bridge log next to the JavaScript traffic.
    func note(_ line: String) {
        record("[app] \(line)")
    }

    /// Rolling log of bridge activity for support: `$XDG_STATE_HOME/signet/bridge.log`
    /// (`~/.local/state/signet` by default), readable by this user only, rotated to
    /// `bridge.log.1` once it passes `maxLogBytes` (S11).
    static let logFileURL: URL = {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state", isDirectory: true)
        return state.appendingPathComponent("signet/bridge.log")
    }()
    static let maxLogBytes = 5_000_000
    private var logHandle: FileHandle?
    private var logBytes = 0

    private func openLog() -> FileHandle? {
        guard let url = logURL else { return nil }
        guard (try? PrivateFile.hardenDirectory(url.deletingLastPathComponent())) != nil else { return nil }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        logBytes = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotateLogIfNeeded() {
        guard logBytes > Self.maxLogBytes else { return }
        try? logHandle?.close()
        logHandle = nil
        guard let url = logURL else { return }
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        logBytes = 0
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// The one way a line reaches any sink: the system log, `consoleLines` and the bridge
    /// file all get the same redacted, capped text (S11). Nothing calls `NSLog` directly.
    private func record(_ rawLine: String) {
        let line = Self.redactedLine(rawLine)
        systemLog(line)
        lock.withLock {
            _consoleLines.append(line)
            if _consoleLines.count > 300 { _consoleLines.removeFirst(_consoleLines.count - 300) }
            rotateLogIfNeeded()
            if logHandle == nil { logHandle = openLog() }
            if let data = "\(Self.stamp.string(from: Date())) \(line)\n".data(using: .utf8) {
                try? logHandle?.write(contentsOf: data)
                logBytes += data.count
            }
        }
    }

    private func finishFetch(id: Int, status: Int = 0, statusText: String = "", headersJSON: String = "{}", body: String = "", error: String? = nil) {
        trace("fetch #\(id) ← \(error ?? "\(status) \(body.utf8.count) bytes")")
        context?.objectForKeyedSubscript("__signet_fetchDone")?.call(withArguments: [
            id, status, statusText, headersJSON, body, error ?? NSNull(),
        ])
    }
}

/// Typed access to a native's arguments, standing in for the parameter types of the Mac's
/// `@convention(block)` signatures. A missing argument reads as JavaScript `undefined` would.
private extension Array where Element == JSValue {
    func string(_ index: Int) -> String { index < count ? self[index].toString() : "undefined" }
    func double(_ index: Int) -> Double { index < count ? self[index].toDouble() : .nan }
    func int(_ index: Int) -> Int {
        let value = double(index)
        return value.isFinite ? Int(value) : 0
    }
}
