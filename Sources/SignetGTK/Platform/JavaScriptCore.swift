import CJavaScriptCore
import Foundation

// The part of JavaScriptCore's Objective-C API that `TaquitoBridge` uses (`JSContext`,
// `JSValue`), over the GLib API WebKitGTK ships for the same engine. Names follow the Mac so the
// two bridges read alike. Like the GLib objects underneath, none of this is thread-safe: a
// context and its values are only ever touched on the thread that made the context.

/// A JavaScript exception, as `JSContext.exception` and the exception handler see it.
final class JSException {
    fileprivate let raw: OpaquePointer

    fileprivate init(retaining raw: OpaquePointer) {
        g_object_ref(UnsafeMutableRawPointer(raw))
        self.raw = raw
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(raw)) }

    /// `Name: message`, as `JSValue.toString()` gives for an Error on the Mac.
    func toString() -> String { takeString(jsc_exception_to_string(raw)) ?? "unknown error" }
}

final class JSContext {
    fileprivate let raw: OpaquePointer

    /// Called for every exception thrown in the context. As on the Mac, a handler is what hears
    /// about exceptions; unlike the Mac, the exception is also kept for `exception` afterwards,
    /// so a call that throws synchronously is reported to its caller and not only logged.
    var exceptionHandler: ((JSContext, JSException) -> Void)?

    init?() {
        guard let raw = jsc_context_new() else { return nil }
        self.raw = raw
        let box = Unmanaged.passUnretained(self).toOpaque()
        jsc_context_push_exception_handler(raw, { context, exception, userData in
            guard let context, let exception, let userData else { return }
            let owner = Unmanaged<JSContext>.fromOpaque(userData).takeUnretainedValue()
            owner.exceptionHandler?(owner, JSException(retaining: exception))
            jsc_context_throw_exception(context, exception)
        }, box, nil)
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(raw)) }

    /// The pending exception, if the last evaluation or call threw. Set to nil to clear it.
    var exception: JSException? {
        get { jsc_context_get_exception(raw).map(JSException.init(retaining:)) }
        set { if newValue == nil { jsc_context_clear_exception(raw) } }
    }

    @discardableResult
    func evaluateScript(_ source: String, withSourceURL url: URL? = nil) -> JSValue? {
        let value = url.map { jsc_context_evaluate_with_source_uri(raw, source, -1, $0.absoluteString, 1) }
            ?? jsc_context_evaluate(raw, source, -1)
        return value.map { JSValue(taking: $0, in: self) }
    }

    /// A global variable.
    func objectForKeyedSubscript(_ name: String) -> JSValue? {
        jsc_context_get_value(raw, name).map { JSValue(taking: $0, in: self) }
    }

    /// Sets a global variable; `value` is converted as `JSValue(_:in:)` describes.
    func setObject(_ value: Any?, forKeyedSubscript name: String) {
        jsc_context_set_value(raw, name, JSValue(value, in: self).raw)
    }
}

final class JSValue {
    fileprivate let raw: OpaquePointer
    let context: JSContext

    fileprivate init(taking raw: OpaquePointer, in context: JSContext) {
        self.raw = raw
        self.context = context
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(raw)) }

    /// Converts a Swift value: a `JSValue` stays itself, nil is `undefined`, `NSNull` is `null`,
    /// strings, booleans and numbers map across, and arrays and dictionaries go through JSON.
    convenience init(_ value: Any?, in context: JSContext) {
        let raw: OpaquePointer
        switch value {
        case nil:
            raw = jsc_value_new_undefined(context.raw)
        case let value as JSValue:
            g_object_ref(UnsafeMutableRawPointer(value.raw))
            raw = value.raw
        case is NSNull:
            raw = jsc_value_new_null(context.raw)
        case let string as String:
            raw = jsc_value_new_string(context.raw, string)
        case let bool as Bool:
            raw = jsc_value_new_boolean(context.raw, bool ? 1 : 0)
        case let int as Int:
            raw = jsc_value_new_number(context.raw, Double(int))
        case let double as Double:
            raw = jsc_value_new_number(context.raw, double)
        case let number as NSNumber:
            raw = number.isJSONBoolean ? jsc_value_new_boolean(context.raw, number.boolValue ? 1 : 0)
                : jsc_value_new_number(context.raw, number.doubleValue)
        default:
            if let value, JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let parsed = jsc_value_new_from_json(context.raw, String(decoding: data, as: UTF8.self)) {
                raw = parsed
            } else {
                raw = jsc_value_new_string(context.raw, String(describing: value!))
            }
        }
        self.init(taking: raw, in: context)
    }

    /// An empty object, `{}`.
    convenience init(newObjectIn context: JSContext) {
        self.init(taking: jsc_value_new_object(context.raw, nil, nil), in: context)
    }

    /// A JavaScript function that runs `body` with its arguments. What `body` returns is
    /// converted back as `init(_:in:)` describes. This stands in for the Mac's
    /// `@convention(block)` closures, which need the Objective-C runtime.
    convenience init(function name: String, in context: JSContext, _ body: @escaping ([JSValue]) -> Any?) {
        final class Box {
            let body: ([JSValue]) -> Any?
            weak var context: JSContext?
            init(_ body: @escaping ([JSValue]) -> Any?, _ context: JSContext) { self.body = body; self.context = context }
        }
        let box = Unmanaged.passRetained(Box(body, context)).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GPtrArray>?, gpointer?) -> OpaquePointer? = { args, userData in
            let box = Unmanaged<Box>.fromOpaque(userData!).takeUnretainedValue()
            // A context the bridge has let go of runs nothing more; the call returns undefined.
            guard let context = box.context else { return nil }
            var values: [JSValue] = []
            if let args {
                for i in 0..<Int(args.pointee.len) {
                    guard let item = args.pointee.pdata[i] else { continue }
                    let raw = OpaquePointer(item)
                    g_object_ref(item)
                    values.append(JSValue(taking: raw, in: context))
                }
            }
            let result = JSValue(box.body(values), in: context)
            // The caller takes a reference to the returned value.
            g_object_ref(UnsafeMutableRawPointer(result.raw))
            return result.raw
        }
        let raw = jsc_value_new_function_variadic(
            context.raw, name, unsafeBitCast(callback, to: GCallback.self), box,
            { userData in Unmanaged<AnyObject>.fromOpaque(userData!).release() },
            jsc_value_get_type())!
        self.init(taking: raw, in: context)
    }

    var isUndefined: Bool { jsc_value_is_undefined(raw) != 0 }
    var isNull: Bool { jsc_value_is_null(raw) != 0 }
    var isObject: Bool { jsc_value_is_object(raw) != 0 }
    var isString: Bool { jsc_value_is_string(raw) != 0 }

    func toString() -> String { takeString(jsc_value_to_string(raw)) ?? "" }
    func toDouble() -> Double { jsc_value_to_double(raw) }

    /// The value as Foundation types, the way the Mac's `toObject()` hands it over: through
    /// JSON, so numbers are `NSNumber`, objects are dictionaries and `undefined` is nil.
    func toObject() -> Any? {
        if isUndefined { return nil }
        guard let json = takeString(jsc_value_to_json(raw, 0)) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    }

    func objectForKeyedSubscript(_ name: String) -> JSValue? {
        guard isObject else { return nil }
        return jsc_value_object_get_property(raw, name).map { JSValue(taking: $0, in: context) }
    }

    func setObject(_ value: Any?, forKeyedSubscript name: String) {
        jsc_value_object_set_property(raw, name, JSValue(value, in: context).raw)
    }

    @discardableResult
    func call(withArguments arguments: [Any?]) -> JSValue? {
        withRawArguments(arguments) { count, pointers in
            jsc_value_function_callv(raw, count, pointers).map { JSValue(taking: $0, in: context) }
        }
    }

    @discardableResult
    func invokeMethod(_ name: String, withArguments arguments: [Any?]) -> JSValue? {
        withRawArguments(arguments) { count, pointers in
            jsc_value_object_invoke_methodv(raw, name, count, pointers).map { JSValue(taking: $0, in: context) }
        }
    }

    private func withRawArguments<T>(_ arguments: [Any?], _ body: (guint, UnsafeMutablePointer<OpaquePointer?>?) -> T) -> T {
        let values = arguments.map { JSValue($0, in: context) }
        var pointers: [OpaquePointer?] = values.map { $0.raw }
        return withExtendedLifetime(values) {
            pointers.withUnsafeMutableBufferPointer { body(guint($0.count), $0.baseAddress) }
        }
    }
}

/// Takes ownership of a GLib-allocated string.
private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { g_free(pointer) }
    return String(cString: pointer)
}
