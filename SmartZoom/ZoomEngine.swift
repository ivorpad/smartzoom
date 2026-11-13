import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

/// Turns Option + scroll into synthetic trackpad pinch (magnify) gestures and
/// Option + middle-click into a Smart Zoom (two-finger double-tap) gesture.
/// The app under the cursor re-renders at full resolution, unlike Accessibility Zoom.
///
/// Gesture events have no public constructor. Field numbers come from
/// Mac Mouse Fix's TouchSimulator.m (undocumented CGEventFields):
///   55  = event type (29 = NSEventTypeGesture)
///   110 = IOHIDEventType (8 = zoom/pinch, 22 = zoom toggle / smart zoom)
///   113 = magnification amount (double)
///   132 = IOHIDEventPhase (1 began, 2 changed, 4 ended)
@MainActor
final class ZoomEngine: ObservableObject {
    static let shared = ZoomEngine()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var invert: Bool { didSet { defaults.set(invert, forKey: "invert") } }
    @Published private(set) var tapRunning = false

    private let defaults = UserDefaults.standard
    private var tap: CFMachPort?
    private var inGesture = false
    private var endWork: DispatchWorkItem?
    private var swallowMiddleUp = false
    private var retryTimer: Timer?

    private init() {
        defaults.register(defaults: ["enabled": true, "sensitivity": 1.0, "invert": false])
        enabled = defaults.bool(forKey: "enabled")
        sensitivity = defaults.double(forKey: "sensitivity")
        invert = defaults.bool(forKey: "invert")
        installTap()
        if !tapRunning {
            requestPermission()
            // Poll until the user grants Accessibility, then install the tap.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.installTap()
                    if self.tapRunning { self.retryTimer?.invalidate(); self.retryTimer = nil }
                }
            }
        }
    }

    func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.scrollWheel, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapRunning = true
    }

    /// Only Option held (Shift/Control/Command not held).
    private static func onlyOption(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
        return flags.intersection(relevant) == .maskAlternate
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if inGesture && !event.flags.contains(.maskAlternate) { endGesture() }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            guard enabled, Self.onlyOption(event.flags) else {
                if inGesture { endGesture() }
                return Unmanaged.passUnretained(event)
            }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let delta: Double
            if continuous {
                // Trackpad / Magic Mouse: pixel deltas, small per event.
                delta = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * 0.004
            } else {
                // Wheel mouse: one line per notch (accelerated values can be larger).
                delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 0.06
            }
            if delta != 0 {
                magnify(by: (invert ? -delta : delta) * sensitivity)
            }
            return nil // swallow the scroll

        case .otherMouseDown:
            if enabled, Self.onlyOption(event.flags),
               event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                swallowMiddleUp = true
                postSmartZoom()
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseUp:
            if swallowMiddleUp, event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                swallowMiddleUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func magnify(by amount: Double) {
        if !inGesture {
            inGesture = true
            postMagnify(0, phase: 1)
        }
        postMagnify(amount, phase: 2)
        // End the pinch shortly after the last scroll so apps commit the zoom.
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endGesture() }
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func endGesture() {
        endWork?.cancel(); endWork = nil
        guard inGesture else { return }
        inGesture = false
        postMagnify(0, phase: 4)
    }

    private func postMagnify(_ amount: Double, phase: Int64) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 29)!
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
        e.post(tap: .cgSessionEventTap)
    }

    func postSmartZoom() {
        guard let e = CGEvent(source: nil) else { return }
        e.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 22)
        e.post(tap: .cgSessionEventTap)
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<ZoomEngine>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { engine.handle(type, event) }
}
