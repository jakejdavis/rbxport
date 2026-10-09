import AppKit
import Foundation

// The glue between Cocoa Scripting's Objective-C world and `ScriptHost`: value conversion, the
// object specifiers Cocoa wants back, failing and suspending commands. Cocoa calls all of it on
// the main thread, so the entry points assume the main actor.

/// Runs `body` on the main actor from an Objective-C entry point. Cocoa Scripting runs on the
/// main thread; anywhere else this traps.
func onMain<T>(_ body: @MainActor () -> T) -> T {
    precondition(Thread.isMainThread, "Cocoa Scripting runs on the main thread")
    // Cocoa hands us non-Sendable objects on the main thread; this runs `body` there without
    // asking the compiler to prove it, as `MainActor.assumeIsolated` would.
    return withoutActuallyEscaping(body) { unsafeBitCast($0, to: (() -> T).self)() }
}

/// Fails the running command (or, when a KVC setter is running, the `set` that called it).
func failCommand(_ error: ScriptError) {
    guard let command = NSScriptCommand.current() else { return }
    command.scriptErrorNumber = error.code
    command.scriptErrorString = error.message
}

/// Runs `body` with the host; a thrown error fails the running command and the result is nil.
func scripted<T>(_ body: @MainActor (ScriptHost) throws -> T?) -> T? {
    onMain {
        guard let host = ScriptHost.current else {
            failCommand(.notReady)
            return nil
        }
        do { return try body(host) } catch {
            failCommand(ScriptError(error))
            return nil
        }
    }
}

// MARK: - Values

enum ScriptingValues {
    /// What a KVC getter hands Cocoa for a value. `missing value` is nil.
    @MainActor static func object(_ value: ScriptValue) -> Any? {
        switch value {
        case .missing: return nil
        case .bool(let b): return NSNumber(value: b)
        case .int(let n): return NSNumber(value: n)
        case .real(let n): return NSNumber(value: n)
        case .enumerator(let code): return NSNumber(value: code)
        case .text(let text): return text as NSString
        case .file(let path): return NSURL(fileURLWithPath: path)
        case .list(let items): return items.compactMap { object($0) } as NSArray
        case .track(let id, let playlist): return RbxTrack(id: id, playlist: playlist)
        case .playlist(let id): return RbxPlaylist(id: id)
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func isFloat(_ number: NSNumber) -> Bool {
        let encoding = String(cString: number.objCType)
        return encoding == "d" || encoding == "f"
    }

    /// Whatever Cocoa handed a setter or a command, as a value.
    static func value(_ object: Any?) -> ScriptValue {
        guard let object else { return .missing }
        if let descriptor = object as? NSAppleEventDescriptor { return value(descriptor) }
        if let number = object as? NSNumber {
            if isBoolean(number) { return .bool(number.boolValue) }
            if isFloat(number) { return .real(number.doubleValue) }
            return .int(number.int64Value)
        }
        if let text = object as? NSString { return .text(text as String) }
        if let items = object as? NSArray { return .list(items.map { value($0) }) }
        if let url = object as? URL, url.isFileURL { return .file(url.path) }
        if let track = object as? RbxTrack { return .track(id: track.id, playlist: track.playlist) }
        if let playlist = object as? RbxPlaylist { return .playlist(playlist.id) }
        return .missing
    }

    /// An Apple event value Cocoa passed through uncoerced, which it does for a property typed `any`.
    static func value(_ descriptor: NSAppleEventDescriptor) -> ScriptValue {
        switch descriptor.descriptorType {
        case fourCC("true"): return .bool(true)
        case fourCC("fals"): return .bool(false)
        case fourCC("bool"): return .bool(descriptor.booleanValue)
        case fourCC("shor"), fourCC("long"): return .int(Int64(descriptor.int32Value))
        case fourCC("comp"), fourCC("doub"), fourCC("sing"): return .real(descriptor.doubleValue)
        case fourCC("list"):
            return .list((0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1) }.map { value($0) })
        case fourCC("null"), fourCC("msng"), fourCC("type"): return .missing
        default: return descriptor.stringValue.map(ScriptValue.text) ?? .missing
        }
    }

    /// A value as an Apple event descriptor, for a property typed `any`.
    static func descriptor(_ value: ScriptValue) -> NSAppleEventDescriptor {
        switch value {
        case .bool(let b): return NSAppleEventDescriptor(boolean: b)
        case .int(let n):
            if let small = Int32(exactly: n) { return NSAppleEventDescriptor(int32: small) }
            return NSAppleEventDescriptor(double: Double(n))
        case .real(let n): return NSAppleEventDescriptor(double: n)
        case .text(let text): return NSAppleEventDescriptor(string: text)
        case .list(let items):
            let list = NSAppleEventDescriptor.list()
            for (at, item) in items.enumerated() { list.insert(descriptor(item), at: at + 1) }
            return list
        // `missing value`, which AppleScript carries as the type `msng`.
        default: return NSAppleEventDescriptor(typeCode: fourCC("msng"))
        }
    }

    /// An id as a unique-id specifier carries it.
    static func id(_ object: Any?) -> String? { ScriptMapping.canonicalID(value(object)) }

    /// The objects a parameter names. The dictionary types the commands' parameters as specifiers,
    /// so Cocoa hands them over unevaluated: typed as its classes, a deck or playlist named in an
    /// argument was refused ("Can't get deck 1"), and one named as the direct parameter was sent
    /// the command as a receiver instead of to the command's own class. Lists are flattened:
    /// `every track whose ...` is one specifier for many tracks, and `{track 1, track 2}` a list.
    static func resolve(_ object: Any?) -> [Any] {
        var out: [Any] = []
        func walk(_ object: Any) {
            if let specifier = object as? NSScriptObjectSpecifier {
                if let found = specifier.objectsByEvaluatingSpecifier { walk(found) }
            } else if let items = object as? NSArray {
                items.forEach(walk)
            } else {
                out.append(object)
            }
        }
        if let object { walk(object) }
        return out
    }
}

// MARK: - Commands

extension NSScriptCommand {
    /// The command's direct parameter as objects: its receivers when Cocoa made it one, as it does
    /// with any object named there.
    var directObjects: [Any] {
        if let receivers = evaluatedReceivers { return ScriptingValues.resolve(receivers) }
        return ScriptingValues.resolve(directParameter)
    }

    /// Whether the command was given `key` at all, found or not.
    func given(_ key: String) -> Bool { arguments?[key] != nil }

    func argument(_ key: String) -> Any? { ScriptingValues.resolve(arguments?[key]).first }
}

/// Carries out a command once, however many of its receivers Cocoa asks. An object named as a
/// command's direct parameter is its receiver, and a receiver's class has to say it handles the
/// command (`responds-to` in the dictionary) or Cocoa refuses it. With several (`add (every track
/// whose ...) to ...`) Cocoa calls each one's handler; the first does the whole command for all of
/// them, the rest do nothing.
@MainActor
enum Once {
    private static var seen = Set<ObjectIdentifier>()

    static func run(_ command: NSScriptCommand, _ body: () -> Void) {
        let key = ObjectIdentifier(command)
        guard seen.insert(key).inserted else { return }
        // Forgotten once this pass over the run loop ends, after Cocoa has called every receiver;
        // an address can be a new command's next time.
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = seen.remove(key) } }
        body()
    }
}

/// Holds a command while the work it started runs, and resumes it with the result. A script waits,
/// the window does not.
@MainActor
enum Deferred {
    private final class Held {
        let command: NSScriptCommand
        /// Pieces of work still out: the reply waits for the last.
        var pending = 0
        var result: ScriptValue?
        var error: ScriptError?
        init(_ command: NSScriptCommand) { self.command = command }
    }

    private static var held: [ObjectIdentifier: Held] = [:]

    /// Runs `work` and holds the running command's reply until it, and anything else the same
    /// command started, is done. The last result is the command's; the first error is.
    static func run(_ work: @escaping @MainActor () async throws -> ScriptValue) {
        guard let command = NSScriptCommand.current() else {
            // Reached outside a command, which Cocoa does not do; do the work anyway.
            Task { _ = try? await work() }
            return
        }
        let key = ObjectIdentifier(command)
        let entry: Held
        if let existing = held[key] {
            entry = existing
        } else {
            command.suspendExecution()
            entry = Held(command)
            held[key] = entry
        }
        entry.pending += 1
        Task { @MainActor in
            let outcome: Result<ScriptValue, ScriptError>
            do { outcome = .success(try await work()) } catch { outcome = .failure(ScriptError(error)) }
            finish(key, outcome)
        }
    }

    private static func finish(_ key: ObjectIdentifier, _ outcome: Result<ScriptValue, ScriptError>) {
        guard let entry = held[key] else { return }
        entry.pending -= 1
        switch outcome {
        case .success(let value): entry.result = value
        case .failure(let error): entry.error = entry.error ?? error
        }
        guard entry.pending <= 0 else { return }
        held[key] = nil
        if let error = entry.error {
            entry.command.scriptErrorNumber = error.code
            entry.command.scriptErrorString = error.message
        }
        entry.command.resumeExecution(withResult: entry.result.flatMap { ScriptingValues.object($0) })
    }
}

// MARK: - Specifiers

enum ScriptingSpecifiers {
    static func applicationDescription() -> NSScriptClassDescription? {
        NSScriptClassDescription(for: NSApplication.self)
    }

    static func description(of cls: AnyClass) -> NSScriptClassDescription? {
        NSScriptClassDescription(for: cls)
    }

    static func uniqueID(
        container: (NSScriptClassDescription, NSScriptObjectSpecifier)? = nil, key: String, id: Any
    ) -> NSScriptObjectSpecifier? {
        guard let application = applicationDescription() else { return nil }
        let (description, specifier) = container.map { ($0.0, Optional($0.1)) } ?? (application, nil)
        return NSUniqueIDSpecifier(
            containerClassDescription: description, containerSpecifier: specifier, key: key, uniqueID: id)
    }

    static func name(key: String, _ name: String) -> NSScriptObjectSpecifier? {
        guard let application = applicationDescription() else { return nil }
        return NSNameSpecifier(
            containerClassDescription: application, containerSpecifier: nil, key: key, name: name)
    }

    static func index(key: String, _ index: Int) -> NSScriptObjectSpecifier? {
        guard let application = applicationDescription() else { return nil }
        return NSIndexSpecifier(
            containerClassDescription: application, containerSpecifier: nil, key: key, index: index)
    }
}
