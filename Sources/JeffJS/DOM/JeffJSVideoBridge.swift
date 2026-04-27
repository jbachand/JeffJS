// JeffJSVideoBridge.swift
// JeffJS Video Bridge — Registers __nativeVideo on a JeffJS context.
//
// Bridges video playback to JavaScript running in JeffJS, providing
// play/pause/seek/volume/muted/playbackRate/loop control and firing media
// events (timeupdate, play, pause, ended, loadedmetadata, canplay, etc.)
// back to JS via event callbacks.

import Foundation

// MARK: - Video Provider Protocol

/// Protocol for providing video playback capabilities.
/// The host app conforms to this to supply native video playback.
/// When no provider is set, all video APIs are registered but inert.
@MainActor
public protocol JeffJSVideoProvider: AnyObject {
    func play(nodeID: UUID)
    func pause(nodeID: UUID)
    func seek(nodeID: UUID, to time: Double)
    func currentTime(nodeID: UUID) -> Double
    func duration(nodeID: UUID) -> Double
    func isPaused(nodeID: UUID) -> Bool
    func setVolume(nodeID: UUID, volume: Float)
    func volume(nodeID: UUID) -> Float
    func setMuted(nodeID: UUID, muted: Bool)
    func isMuted(nodeID: UUID) -> Bool
    func setPlaybackRate(nodeID: UUID, rate: Float)
    func playbackRate(nodeID: UUID) -> Float
    func setLoop(nodeID: UUID, loop: Bool)
    func isLoop(nodeID: UUID) -> Bool
    func readyState(nodeID: UUID) -> Int
    func videoWidth(nodeID: UUID) -> Double
    func videoHeight(nodeID: UUID) -> Double
    func hasPlayer(nodeID: UUID) -> Bool
    func setEventCallback(nodeID: UUID, callback: @escaping (String, [String: Any]) -> Void)
    func destroyAll()
}

// MARK: - JeffJSVideoBridge

/// Registers `__nativeVideo` on a JeffJS context so the JS media element
/// API (play/pause/currentTime/etc.) can control native video instances.
@MainActor
final class JeffJSVideoBridge {

    // MARK: - State

    private weak var ctx: JeffJSContext?
    private weak var provider: JeffJSVideoProvider?
    /// Event callbacks keyed by node UUID string, duped to prevent GC.
    private var eventCallbacks: [String: JeffJSValue] = [:]

    // MARK: - Init

    init(provider: JeffJSVideoProvider? = nil) {
        self.provider = provider
    }

    // MARK: - Registration

    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        let global = ctx.getGlobalObject()
        let videoObj = ctx.newPlainObject()

        // play(nodeID) -> Promise<undefined>
        ctx.setPropertyFunc(obj: videoObj, name: "play", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            self.provider?.play(nodeID: nodeID)
            return self.resolvedPromise(ctx: ctx)
        }, length: 1)

        // pause(nodeID)
        ctx.setPropertyFunc(obj: videoObj, name: "pause", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            self.provider?.pause(nodeID: nodeID)
            return JeffJSValue.undefined
        }, length: 1)

        // seek(nodeID, time)
        ctx.setPropertyFunc(obj: videoObj, name: "seek", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            let time = args.count > 1 ? (ctx.toFloat64(args[1]) ?? 0) : 0
            self.provider?.seek(nodeID: nodeID, to: time)
            return JeffJSValue.undefined
        }, length: 2)

        // getCurrentTime(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getCurrentTime", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(0) }
            return JeffJSValue.newFloat64(self.provider?.currentTime(nodeID: nodeID) ?? 0)
        }, length: 1)

        // getDuration(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getDuration", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(0) }
            return JeffJSValue.newFloat64(self.provider?.duration(nodeID: nodeID) ?? 0)
        }, length: 1)

        // isPaused(nodeID) -> boolean
        ctx.setPropertyFunc(obj: videoObj, name: "isPaused", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.JS_TRUE }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.JS_TRUE }
            return (self.provider?.isPaused(nodeID: nodeID) ?? true) ? JeffJSValue.JS_TRUE : JeffJSValue.JS_FALSE
        }, length: 1)

        // setVolume(nodeID, volume)
        ctx.setPropertyFunc(obj: videoObj, name: "setVolume", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            let vol = args.count > 1 ? Float(ctx.toFloat64(args[1]) ?? 1) : 1
            self.provider?.setVolume(nodeID: nodeID, volume: vol)
            return JeffJSValue.undefined
        }, length: 2)

        // getVolume(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getVolume", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(1) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(1) }
            return JeffJSValue.newFloat64(Double(self.provider?.volume(nodeID: nodeID) ?? 1))
        }, length: 1)

        // setMuted(nodeID, muted)
        ctx.setPropertyFunc(obj: videoObj, name: "setMuted", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            let muted = args.count > 1 ? ctx.toBool(args[1]) : false
            self.provider?.setMuted(nodeID: nodeID, muted: muted)
            return JeffJSValue.undefined
        }, length: 2)

        // isMuted(nodeID) -> boolean
        ctx.setPropertyFunc(obj: videoObj, name: "isMuted", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.JS_FALSE }
            return (self.provider?.isMuted(nodeID: nodeID) ?? false) ? JeffJSValue.JS_TRUE : JeffJSValue.JS_FALSE
        }, length: 1)

        // setPlaybackRate(nodeID, rate)
        ctx.setPropertyFunc(obj: videoObj, name: "setPlaybackRate", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            let rate = args.count > 1 ? Float(ctx.toFloat64(args[1]) ?? 1) : 1
            self.provider?.setPlaybackRate(nodeID: nodeID, rate: rate)
            return JeffJSValue.undefined
        }, length: 2)

        // getPlaybackRate(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getPlaybackRate", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(1) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(1) }
            return JeffJSValue.newFloat64(Double(self.provider?.playbackRate(nodeID: nodeID) ?? 1))
        }, length: 1)

        // setLoop(nodeID, loop)
        ctx.setPropertyFunc(obj: videoObj, name: "setLoop", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.undefined }
            let loop = args.count > 1 ? ctx.toBool(args[1]) : false
            self.provider?.setLoop(nodeID: nodeID, loop: loop)
            return JeffJSValue.undefined
        }, length: 2)

        // isLoop(nodeID) -> boolean
        ctx.setPropertyFunc(obj: videoObj, name: "isLoop", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.JS_FALSE }
            return (self.provider?.isLoop(nodeID: nodeID) ?? false) ? JeffJSValue.JS_TRUE : JeffJSValue.JS_FALSE
        }, length: 1)

        // getReadyState(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getReadyState", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newInt32(0) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newInt32(0) }
            return JeffJSValue.newInt32(Int32(self.provider?.readyState(nodeID: nodeID) ?? 0))
        }, length: 1)

        // getVideoWidth(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getVideoWidth", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(0) }
            return JeffJSValue.newFloat64(self.provider?.videoWidth(nodeID: nodeID) ?? 0)
        }, length: 1)

        // getVideoHeight(nodeID) -> number
        ctx.setPropertyFunc(obj: videoObj, name: "getVideoHeight", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.newFloat64(0) }
            return JeffJSValue.newFloat64(self.provider?.videoHeight(nodeID: nodeID) ?? 0)
        }, length: 1)

        // hasPlayer(nodeID) -> boolean
        ctx.setPropertyFunc(obj: videoObj, name: "hasPlayer", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let nodeID = self.extractNodeID(ctx: ctx, args: args) else { return JeffJSValue.JS_FALSE }
            return (self.provider?.hasPlayer(nodeID: nodeID) ?? false) ? JeffJSValue.JS_TRUE : JeffJSValue.JS_FALSE
        }, length: 1)

        // registerEventCallback(nodeID, callback)
        ctx.setPropertyFunc(obj: videoObj, name: "registerEventCallback", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard let idStr = args.count > 0 ? ctx.toSwiftString(args[0]) : nil,
                  let nodeID = UUID(uuidString: idStr) else {
                return JeffJSValue.undefined
            }
            let callback = args.count > 1 ? args[1] : JeffJSValue.undefined
            guard !callback.isUndefined && !callback.isNull else { return JeffJSValue.undefined }

            let duped = callback.dupValue()
            self.eventCallbacks[idStr] = duped

            self.provider?.setEventCallback(nodeID: nodeID) { [weak self] eventName, detail in
                Task { @MainActor [weak self] in
                    self?.fireEventCallback(nodeIDStr: idStr, eventName: eventName, detail: detail)
                }
            }
            return JeffJSValue.undefined
        }, length: 2)

        ctx.setPropertyStr(obj: global, name: "__nativeVideo", value: videoObj)
    }

    // MARK: - Event Dispatch

    private func fireEventCallback(nodeIDStr: String, eventName: String, detail: [String: Any]) {
        guard let ctx, let cb = eventCallbacks[nodeIDStr] else { return }
        let nameArg = ctx.newStringValue(eventName)
        let detailObj = ctx.newPlainObject()
        for (key, value) in detail {
            if let d = value as? Double {
                ctx.setPropertyStr(obj: detailObj, name: key, value: .newFloat64(d))
            } else if let s = value as? String {
                ctx.setPropertyStr(obj: detailObj, name: key, value: ctx.newStringValue(s))
            } else if let b = value as? Bool {
                ctx.setPropertyStr(obj: detailObj, name: key, value: b ? .JS_TRUE : .JS_FALSE)
            }
        }
        _ = ctx.call(cb, this: JeffJSValue.undefined, args: [nameArg, detailObj])
        _ = ctx.rt.executePendingJobs()
    }

    // MARK: - Teardown

    func teardown() {
        for (_, cb) in eventCallbacks {
            cb.freeValue()
        }
        eventCallbacks.removeAll()
        provider?.destroyAll()
    }

    // MARK: - Helpers

    private func extractNodeID(ctx: JeffJSContext, args: [JeffJSValue]) -> UUID? {
        guard args.count > 0, let idStr = ctx.toSwiftString(args[0]) else { return nil }
        return UUID(uuidString: idStr)
    }

    private func resolvedPromise(ctx: JeffJSContext) -> JeffJSValue {
        return ctx.eval(input: "Promise.resolve()", filename: "<video-bridge>", evalFlags: 0)
    }
}
