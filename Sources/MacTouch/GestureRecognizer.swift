import Foundation
import CoreGraphics

/// A touch point already mapped to global display coordinates.
struct TouchPoint {
    let id: Int
    var point: CGPoint
}

enum Edge { case left, right, top, bottom }

protocol GestureSink: AnyObject {
    func pointerMoved(to p: CGPoint)
    func discrete(_ g: Gesture, at p: CGPoint, clickCount: Int)
    func continuousBegan(_ g: Gesture, at p: CGPoint)
    func continuousChanged(_ g: Gesture, to p: CGPoint, delta: CGVector)
    func continuousEnded(_ g: Gesture, at p: CGPoint, velocity: CGVector)
    func isMapped(_ g: Gesture) -> Bool
}

/// Turns a stream of multi-contact frames into gestures. Pure logic apart from DispatchQueue timers,
/// so it can be driven synthetically in tests (pass `now` explicitly and call `tick`).
final class GestureRecognizer {
    weak var sink: GestureSink?
    var tuning: Tuning
    var displayBounds: CGRect = .zero

    private enum State { case idle, single, dragging, longPressed, multi, done }
    private var state: State = .idle
    private struct Finger { var start: CGPoint; var cur: CGPoint; var t0: TimeInterval }
    private var fingers: [Int: Finger] = [:]
    private var order: [Int] = []            // finger ids in order of arrival
    private var downTime: TimeInterval = 0
    private var origin: CGPoint = .zero
    private var dragArmed = false
    private var lastTapTime: TimeInterval = -1
    private var lastTapPoint: CGPoint = .zero
    private var clickCount = 0
    private var lastPoint: CGPoint = .zero
    private var lastTime: TimeInterval = 0
    private var velocity: CGVector = .zero
    // multi
    private enum MultiSub { case undecided, scrolling, pinching, rotating, swiped, longPressed, done }
    private var sub: MultiSub = .undecided
    private var maxFingers = 0
    private var centroidRef: CGPoint = .zero      // centroid at last rebase
    private var centroidOffset: CGVector = .zero  // accumulated travel before last rebase
    private var multiStart: CGPoint = .zero
    private var startDist: CGFloat = 0
    private var pinchRef: CGFloat = 0
    private var startAngle: CGFloat = 0
    private var rotRef: CGFloat = 0
    private var lastCentroid: CGPoint = .zero
    private var gen = 0                           // timer generation
    var timerQueue: DispatchQueue? = DispatchQueue.main

    init(tuning: Tuning) { self.tuning = tuning }
    var isActive: Bool { state != .idle }

    // MARK: input

    func frame(_ pts: [TouchPoint], now: TimeInterval) {
        let ids = Set(pts.map { $0.id })
        // update / add
        for p in pts {
            if fingers[p.id] == nil {
                fingers[p.id] = Finger(start: p.point, cur: p.point, t0: now)
                order.append(p.id)
                fingerAdded(p.id, now: now)
            } else {
                fingers[p.id]!.cur = p.point
            }
        }
        let removed = order.filter { !ids.contains($0) }
        for id in removed { fingers[id] = nil }
        order.removeAll { !ids.contains($0) }
        if !removed.isEmpty { fingersRemoved(now: now) }
        if !pts.isEmpty { moved(now: now) }
        if fingers.isEmpty && state != .idle { reset() }
    }

    func tick(now: TimeInterval) { timerFired(now: now) }

    private func reset() {
        state = .idle; sub = .undecided; dragArmed = false; maxFingers = 0; gen += 1
        fingers.removeAll(); order.removeAll()
    }

    private func schedule(after s: TimeInterval) {
        gen += 1
        let g = gen
        timerQueue?.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self = self, self.gen == g else { return }
            self.timerFired(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: events

    private func fingerAdded(_ id: Int, now: TimeInterval) {
        let n = fingers.count
        switch state {
        case .idle:
            state = .single
            downTime = now
            origin = fingers[id]!.start
            lastPoint = origin; lastTime = now; velocity = .zero
            dragArmed = false
            if tuning.moveCursorOnTouch { sink?.pointerMoved(to: origin) }
            schedule(after: tuning.longPressDuration)
        case .single:
            enterMulti(now: now)
        case .multi:
            maxFingers = max(maxFingers, n)
            rebaseCentroid()
            if n == 2 && sub == .undecided { initPinch() }
        case .dragging, .longPressed, .done:
            break   // extra fingers during a one-finger gesture are ignored
        }
    }

    private func enterMulti(now: TimeInterval) {
        state = .multi; sub = .undecided
        maxFingers = fingers.count
        multiStart = centroid()
        centroidRef = multiStart; centroidOffset = .zero; lastCentroid = multiStart
        lastTime = now; velocity = .zero
        initPinch()
        schedule(after: tuning.longPressDuration)
    }

    private func initPinch() {
        let (d, a) = pairMetrics()
        startDist = d; pinchRef = d; startAngle = a; rotRef = a
    }

    private func fingersRemoved(now: TimeInterval) {
        let n = fingers.count
        switch state {
        case .single:
            // one finger lifted: tap?
            let dur = now - downTime
            let dist = hypot(lastPoint.x - origin.x, lastPoint.y - origin.y)
            if dur <= tuning.longPressDuration && dist <= tuning.tapMoveTolerance {
                if now - lastTapTime <= tuning.doubleTapInterval && hypot(origin.x - lastTapPoint.x, origin.y - lastTapPoint.y) <= tuning.tapMoveTolerance * 2 {
                    clickCount += 1
                } else { clickCount = 1 }
                lastTapTime = now; lastTapPoint = origin
                if clickCount == 2, sink?.isMapped(.doubleTap1) == true, let s = sink, s.isDoubleTapCustom() {
                    s.discrete(.doubleTap1, at: origin, clickCount: 2)
                } else {
                    sink?.discrete(.tap1, at: origin, clickCount: clickCount)
                }
            } else if dragArmed {
                // armed but window not elapsed; treat as a short drag: begin + end
                beginDrag(now: now)
                sink?.continuousEnded(.drag1, at: lastPoint, velocity: velocity)
            }
            state = .done
        case .dragging:
            sink?.continuousEnded(.drag1, at: lastPoint, velocity: velocity)
            state = .done
        case .multi:
            if n == 0 {
                finishMulti(now: now)
            } else {
                switch sub {
                case .scrolling:
                    sink?.continuousEnded(.scroll2, at: lastCentroid, velocity: velocity)
                    sub = .done
                case .undecided:
                    // keep waiting for the rest to lift (tap classification happens at n == 0)
                    rebaseCentroid()
                default:
                    rebaseCentroid()
                }
            }
        default: break
        }
    }

    private func finishMulti(now: TimeInterval) {
        let dur = now - downTime
        switch sub {
        case .undecided:
            let travel = hypot(centroidOffset.dx, centroidOffset.dy)
            if dur <= tuning.tapMaxDuration * 2 && travel <= tuning.tapMoveTolerance * 2 {
                let g: Gesture? = [2: .tap2, 3: .tap3, 4: .tap4, 5: .tap5][maxFingers]
                if let g = g { sink?.discrete(g, at: multiStart, clickCount: 1) }
            }
        case .scrolling:
            sink?.continuousEnded(.scroll2, at: lastCentroid, velocity: velocity)
        default: break
        }
        sub = .done
    }

    private func moved(now: TimeInterval) {
        switch state {
        case .single:
            guard let f = fingers[order.first ?? -1] else { return }
            let p = f.cur
            updateVelocity(p, now: now)
            let dist = hypot(p.x - origin.x, p.y - origin.y)
            if dist > tuning.dragThreshold {
                if let e = edge(of: origin), movesInward(from: e, to: p), let g = edgeGesture(e), sink?.isMapped(g) == true {
                    sink?.discrete(g, at: p, clickCount: 1)
                    state = .done; gen += 1
                    return
                }
                if now - downTime >= tuning.multiFingerWindow {
                    beginDrag(now: now)
                    sink?.continuousChanged(.drag1, to: p, delta: CGVector(dx: p.x - lastPoint.x, dy: p.y - lastPoint.y))
                } else if !dragArmed {
                    dragArmed = true
                    schedule(after: tuning.multiFingerWindow - (now - downTime))
                }
            }
            lastPoint = p
        case .dragging:
            guard let f = fingers[order.first ?? -1] else { return }
            let p = f.cur
            updateVelocity(p, now: now)
            if p != lastPoint { sink?.continuousChanged(.drag1, to: p, delta: CGVector(dx: p.x - lastPoint.x, dy: p.y - lastPoint.y)) }
            lastPoint = p
        case .multi:
            multiMoved(now: now)
        default: break
        }
    }

    private func beginDrag(now: TimeInterval) {
        state = .dragging; gen += 1
        sink?.continuousBegan(.drag1, at: origin)
    }

    private func multiMoved(now: TimeInterval) {
        let c = centroid()
        let n = fingers.count
        let travel = CGVector(dx: centroidOffset.dx + c.x - centroidRef.x, dy: centroidOffset.dy + c.y - centroidRef.y)
        let delta = CGVector(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)
        updateVelocity(c, now: now)
        switch sub {
        case .undecided:
            let dist = hypot(travel.dx, travel.dy)
            let (d, a) = pairMetrics()
            if n == 2 && startDist > 0 {
                let pinchDelta = abs(d - startDist) / startDist
                let rotDelta = abs(angleDiff(a, startAngle))
                if pinchDelta > tuning.pinchStep && pinchDelta * startDist > dist {
                    sub = .pinching; gen += 1; pinchRef = startDist; pinchStep(d)
                    break
                }
                if rotDelta > CGFloat(tuning.rotateStep) * .pi / 180 && dist < tuning.dragThreshold * 2 && (sink?.isMapped(.rotateCW) == true || sink?.isMapped(.rotateCCW) == true) {
                    sub = .rotating; gen += 1; rotRef = startAngle; rotateStep(a)
                    break
                }
            }
            if dist > tuning.dragThreshold {
                gen += 1
                if maxFingers >= 3 {
                    // swipe candidate: wait for enough distance within the time budget
                    if dist >= tuning.swipeMinDistance {
                        if now - downTime <= tuning.swipeMaxDuration, let g = swipeGesture(travel) {
                            sink?.discrete(g, at: c, clickCount: 1)
                            sub = .swiped
                        } else { sub = .done }
                    }
                } else {
                    sub = .scrolling
                    sink?.continuousBegan(.scroll2, at: c)
                    sink?.continuousChanged(.scroll2, to: c, delta: travel)
                }
            }
        case .scrolling:
            if delta.dx != 0 || delta.dy != 0 { sink?.continuousChanged(.scroll2, to: c, delta: delta) }
        case .pinching:
            if n == 2 { pinchStep(pairMetrics().0) }
        case .rotating:
            if n == 2 { rotateStep(pairMetrics().1) }
        default: break
        }
        lastCentroid = c
    }

    private func pinchStep(_ d: CGFloat) {
        guard pinchRef > 0 else { return }
        let step = CGFloat(tuning.pinchStep) * startDist
        while d - pinchRef >= step { pinchRef += step; sink?.discrete(.pinchOut, at: lastCentroid, clickCount: 1) }
        while pinchRef - d >= step { pinchRef -= step; sink?.discrete(.pinchIn, at: lastCentroid, clickCount: 1) }
    }

    private func rotateStep(_ a: CGFloat) {
        let step = CGFloat(tuning.rotateStep) * .pi / 180
        var diff = angleDiff(a, rotRef)
        while diff >= step { rotRef += step; diff -= step; sink?.discrete(.rotateCW, at: lastCentroid, clickCount: 1) }
        while diff <= -step { rotRef -= step; diff += step; sink?.discrete(.rotateCCW, at: lastCentroid, clickCount: 1) }
    }

    private func timerFired(now: TimeInterval) {
        switch state {
        case .single:
            if dragArmed {
                // multi-finger window elapsed with the finger already moving: start the drag
                beginDrag(now: now)
                if let f = fingers[order.first ?? -1] {
                    sink?.continuousChanged(.drag1, to: f.cur, delta: CGVector(dx: f.cur.x - origin.x, dy: f.cur.y - origin.y))
                    lastPoint = f.cur
                }
            } else {
                let dist = hypot(lastPoint.x - origin.x, lastPoint.y - origin.y)
                if dist <= tuning.tapMoveTolerance {
                    state = .longPressed
                    sink?.discrete(.longPress1, at: origin, clickCount: 1)
                }
            }
        case .multi:
            if sub == .undecided && fingers.count == 2 {
                let travel = hypot(centroidOffset.dx + lastCentroid.x - centroidRef.x, centroidOffset.dy + lastCentroid.y - centroidRef.y)
                if travel <= tuning.tapMoveTolerance * 2 {
                    sub = .longPressed
                    sink?.discrete(.longPress2, at: lastCentroid, clickCount: 1)
                }
            }
        default: break
        }
    }

    // MARK: helpers

    private func updateVelocity(_ p: CGPoint, now: TimeInterval) {
        let dt = now - lastTime
        if dt > 0.001 {
            let ref = state == .multi ? lastCentroid : lastPoint
            let v = CGVector(dx: (p.x - ref.x) / dt, dy: (p.y - ref.y) / dt)
            // light smoothing
            velocity = CGVector(dx: velocity.dx * 0.4 + v.dx * 0.6, dy: velocity.dy * 0.4 + v.dy * 0.6)
            lastTime = now
        }
    }

    private func centroid() -> CGPoint {
        guard !fingers.isEmpty else { return lastCentroid }
        var x = 0.0, y = 0.0
        for f in fingers.values { x += f.cur.x; y += f.cur.y }
        return CGPoint(x: x / Double(fingers.count), y: y / Double(fingers.count))
    }

    private func rebaseCentroid() {
        let c = centroid()
        centroidOffset = CGVector(dx: centroidOffset.dx + lastCentroid.x - centroidRef.x, dy: centroidOffset.dy + lastCentroid.y - centroidRef.y)
        centroidRef = c; lastCentroid = c
        if fingers.count == 2 { let (d, a) = pairMetrics(); startDist = d; pinchRef = d; startAngle = a; rotRef = a }
    }

    private func pairMetrics() -> (CGFloat, CGFloat) {
        guard order.count >= 2, let a = fingers[order[0]], let b = fingers[order[1]] else { return (0, 0) }
        let dx = b.cur.x - a.cur.x, dy = b.cur.y - a.cur.y
        return (hypot(dx, dy), atan2(dy, dx))
    }

    private func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    private func edge(of p: CGPoint) -> Edge? {
        let m = tuning.edgeMargin
        let b = displayBounds
        guard b.width > 0 else { return nil }
        if p.x - b.minX <= m { return .left }
        if b.maxX - p.x <= m { return .right }
        if p.y - b.minY <= m { return .top }
        if b.maxY - p.y <= m { return .bottom }
        return nil
    }

    private func movesInward(from e: Edge, to p: CGPoint) -> Bool {
        let dx = p.x - origin.x, dy = p.y - origin.y
        switch e {
        case .left: return dx > abs(dy)
        case .right: return -dx > abs(dy)
        case .top: return dy > abs(dx)
        case .bottom: return -dy > abs(dx)
        }
    }

    private func edgeGesture(_ e: Edge) -> Gesture? {
        switch e { case .left: return .edgeLeft; case .right: return .edgeRight; case .top: return .edgeTop; case .bottom: return .edgeBottom }
    }

    private func swipeGesture(_ v: CGVector) -> Gesture? {
        let horizontal = abs(v.dx) >= abs(v.dy)
        switch (maxFingers, horizontal, v.dx > 0, v.dy > 0) {
        case (3, true, true, _): return .swipe3Right
        case (3, true, false, _): return .swipe3Left
        case (3, false, _, true): return .swipe3Down
        case (3, false, _, false): return .swipe3Up
        case (let n, true, true, _) where n >= 4: return .swipe4Right
        case (let n, true, false, _) where n >= 4: return .swipe4Left
        case (let n, false, _, true) where n >= 4: return .swipe4Down
        case (let n, false, _, false) where n >= 4: return .swipe4Up
        default: return nil
        }
    }
}

extension GestureSink {
    /// True when double tap is mapped to something other than the plain double click / nothing.
    func isDoubleTapCustom() -> Bool { isMapped(.doubleTap1) }
}
