import SwiftUI

/// Attack presets. One attack is a combo of several hits; the store owns the timeline
/// (`windup`, `interval`, `impactDelay`) and the view animates each hit to match it.
enum AttackStyle: String, CaseIterable, Identifiable {
    case lightning, slap, can, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lightning: return L("⚡️ 雷击", "⚡️ Lightning")
        case .slap: return L("🖐️ 连环耳光", "🖐️ Slaps")
        case .can: return L("🥫 丢易拉罐", "🥫 Can toss")
        case .random: return L("🎲 随机", "🎲 Random")
        }
    }

    static var current: AttackStyle {
        AttackStyle(rawValue: UserDefaults.standard.string(forKey: Pref.attackStyle) ?? "") ?? .lightning
    }

    /// Illustrated art this style can use (`.random` may play any style, so it uses all of them).
    var assets: [EffectAsset] {
        switch self {
        case .lightning: return [.cloud]
        case .slap: return [.hand]
        case .can: return [.can, .throwerIdle, .throwerToss, .throwerThrow]
        case .random: return EffectAsset.allCases
        }
    }

    /// The concrete style for one attack (`.random` picks one).
    func resolved() -> AttackStyle {
        self == .random ? [.lightning, .slap, .can].randomElement()! : self
    }

    /// Max hits per combo; small damage gets fewer hits (never a 0-damage hit).
    var hits: Int {
        switch self {
        case .lightning: return 3
        case .slap: return 6
        case .can, .random: return 3
        }
    }

    /// Delay before the first hit (cloud gathering, thrower walking in, etc.).
    var windup: Double {
        switch self {
        case .lightning: return 0.6
        case .slap: return 0.15
        case .can, .random: return 0.5
        }
    }

    /// Time between the start of two hits.
    var interval: Double {
        switch self {
        case .lightning: return 0.8
        case .slap: return 0.38
        case .can, .random: return 0.9
        }
    }

    /// Time from the start of a hit until it lands (HP drops then).
    var impactDelay: Double {
        switch self {
        case .lightning: return 0.08
        case .slap: return 0.12
        case .can, .random: return CanPath.flight
        }
    }
}

// MARK: - Lightning

/// A fractal bolt in unit coordinates: a jagged main channel plus a couple of forks.
struct BoltGeometry {
    var main: [CGPoint]
    var branches: [[CGPoint]]

    static func random() -> BoltGeometry {
        let main = fractal(from: CGPoint(x: 0.5 + .random(in: -0.15...0.15), y: 0),
                           to: CGPoint(x: 0.5 + .random(in: -0.05...0.05), y: 1), amplitude: 0.45, depth: 5)
        return BoltGeometry(main: main, branches: forks(of: main))
    }

    /// Same channel, new forks: a re-strike flickers without jumping.
    func restrike() -> BoltGeometry {
        BoltGeometry(main: main, branches: Self.forks(of: main))
    }

    private static func forks(of main: [CGPoint]) -> [[CGPoint]] {
        (0..<Int.random(in: 1...3)).map { _ in
            let from = main[Int.random(in: main.count / 5...main.count * 3 / 5)]
            let dir: CGFloat = Bool.random() ? 1 : -1
            let to = CGPoint(x: from.x + dir * .random(in: 0.25...0.45), y: min(1, from.y + .random(in: 0.18...0.32)))
            return fractal(from: from, to: to, amplitude: 0.18, depth: 3)
        }
    }

    private static func fractal(from a: CGPoint, to b: CGPoint, amplitude: CGFloat, depth: Int) -> [CGPoint] {
        var points = [a, b]
        var amp = amplitude
        for _ in 0..<depth {
            var next: [CGPoint] = []
            for (p, q) in zip(points, points.dropFirst()) {
                next.append(p)
                next.append(CGPoint(x: min(0.97, max(0.03, (p.x + q.x) / 2 + .random(in: -amp...amp) / 2)),
                                    y: (p.y + q.y) / 2))
            }
            next.append(points.last!)
            points = next
            amp *= 0.55
        }
        return points
    }
}

private struct PolylineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { p in
            for (i, pt) in points.enumerated() {
                let q = CGPoint(x: rect.minX + pt.x * rect.width, y: rect.minY + pt.y * rect.height)
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
        }
    }
}

/// Three-layer glowing bolt (purple bloom, violet body, white-hot core) that strikes, flickers, re-strikes, fades.
struct BoltView: View {
    @State private var geometry = BoltGeometry.random()
    @State private var opacity = 1.0

    var body: some View {
        ZStack {
            layer(width: 18, color: Color(red: 0.55, green: 0.2, blue: 1).opacity(0.9), blur: 10)
            layer(width: 6, color: Color(red: 0.78, green: 0.6, blue: 1), blur: 1)
            layer(width: 2.2, color: .white, blur: 0)
        }
        .blendMode(.plusLighter)
        .opacity(opacity)
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            opacity = 0.15
            try? await Task.sleep(for: .milliseconds(45))
            geometry = geometry.restrike()
            opacity = 1
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.easeOut(duration: 0.22)) { opacity = 0 }
        }
    }

    private func layer(width: CGFloat, color: Color, blur: CGFloat) -> some View {
        ZStack {
            PolylineShape(points: geometry.main)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            ForEach(geometry.branches.indices, id: \.self) { i in
                PolylineShape(points: geometry.branches[i])
                    .stroke(color, style: StrokeStyle(lineWidth: width * 0.5, lineCap: .round, lineJoin: .round))
            }
        }
        .blur(radius: blur)
    }
}

/// A volumetric, slowly churning storm cloud. Lightning lights it from the inside now and then.
struct StormCloud: View {
    /// Set by the view when a bolt strikes the pet.
    var flash: Bool

    @Environment(\.effectAssets) private var assets
    @State private var ambient = 0.0
    @State private var glowPoint = CGPoint(x: 75, y: 40)
    @State private var innerBolt = BoltGeometry.random()

    static let size = CGSize(width: 150, height: 70)
    /// Extra canvas around the cloud so its bloom fades out instead of being clipped to a box.
    private static let bleed: CGFloat = 40

    private static let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, phase: Double)] = [
        (30, 44, 19, 0.0), (52, 32, 25, 1.3), (80, 25, 29, 2.1), (107, 33, 24, 3.4), (125, 45, 17, 4.2),
        (46, 51, 18, 5.0), (76, 51, 22, 0.7), (104, 51, 18, 2.8),
    ]

    var body: some View {
        let lit = max(flash ? 1 : 0, ambient)
        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                context.translateBy(x: Self.bleed, y: Self.bleed)
                let art = assets[.cloud].map { context.resolve(Image(nsImage: $0)) }
                draw(in: &context, size: Self.size, t: t, lit: lit, art: art)
            }
        }
        .frame(width: Self.size.width + 2 * Self.bleed, height: Self.size.height + 2 * Self.bleed)
        .padding(-Self.bleed)
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: 1.5...4)))
                glowPoint = CGPoint(x: .random(in: 40...110), y: .random(in: 30...50))
                innerBolt = .random()
                for level in [1.0, 0, 0.7, 0].prefix(Bool.random() ? 4 : 2) {
                    ambient = level
                    try? await Task.sleep(for: .milliseconds(level > 0 ? 70 : 90))
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double, lit: Double, art: GraphicsContext.ResolvedImage?) {
        let full = CGRect(origin: .zero, size: size)
        // faint purple aura, much brighter around the flash while lit
        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(full.insetBy(dx: -Self.bleed, dy: -Self.bleed)),
                  with: .radialGradient(Gradient(colors: [Color(red: 0.6, green: 0.35, blue: 1).opacity(0.18 + 0.6 * lit), .clear]),
                                        center: lit > 0 ? glowPoint : CGPoint(x: size.width / 2, y: size.height / 2),
                                        startRadius: 0, endRadius: 70))
        context.drawLayer { layer in
            if let art {
                // illustrated cloud: a slow breathe and drift, brightened while lit
                let w = size.width * 1.3 * (1 + 0.02 * sin(t * 0.8))
                let h = w * art.size.height / max(1, art.size.width)
                let rect = CGRect(x: (size.width - w) / 2 + sin(t * 0.5) * 2, y: size.height / 2 - h / 2, width: w, height: h)
                layer.draw(art, in: rect)
                if lit > 0 {
                    var bright = layer
                    bright.blendMode = .plusLighter
                    bright.opacity = 0.4 * lit
                    bright.draw(art, in: rect)
                }
                layer.blendMode = .sourceAtop
                if lit > 0 {
                    layer.fill(Path(full.insetBy(dx: -Self.bleed, dy: -Self.bleed)),
                               with: .radialGradient(Gradient(colors: [Color(red: 0.95, green: 0.88, blue: 1).opacity(lit), .clear]),
                                                     center: glowPoint, startRadius: 0, endRadius: 55))
                }
                return
            }
            for blob in Self.blobs {
                let c = CGPoint(x: blob.x + sin(t * 0.6 + blob.phase) * 2.2, y: blob.y + cos(t * 0.5 + blob.phase) * 1.6)
                let light = 0.5 + 0.35 * lit
                layer.fill(Path(ellipseIn: CGRect(x: c.x - blob.r, y: c.y - blob.r, width: blob.r * 2, height: blob.r * 2)),
                           with: .radialGradient(Gradient(colors: [Color(white: light), Color(white: 0.28 + 0.2 * lit), Color(white: 0.17)]),
                                                 center: CGPoint(x: c.x - blob.r * 0.3, y: c.y - blob.r * 0.45),
                                                 startRadius: 0, endRadius: blob.r * 1.25))
            }
            // heavier underside, then light from within (both confined to the cloud)
            layer.blendMode = .sourceAtop
            layer.fill(Path(full), with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.4)]),
                                                         startPoint: CGPoint(x: 0, y: size.height * 0.35),
                                                         endPoint: CGPoint(x: 0, y: size.height)))
            if lit > 0 {
                layer.fill(Path(full), with: .radialGradient(Gradient(colors: [Color(red: 0.95, green: 0.88, blue: 1).opacity(lit), .clear]),
                                                             center: glowPoint, startRadius: 0, endRadius: 55))
            }
        }
        if ambient > 0.5 {
            var bolt = context
            bolt.blendMode = .plusLighter
            let rect = CGRect(x: glowPoint.x - 16, y: glowPoint.y, width: 32, height: size.height - glowPoint.y + 4)
            let path = PolylineShape(points: innerBolt.main).path(in: rect)
            bolt.stroke(path, with: .color(Color(red: 0.7, green: 0.45, blue: 1).opacity(0.8)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            bolt.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Slap

/// Wind-up, a fast swing with motion ghosts and speed lines, a beat on the cheek, then out.
struct SlapHand: View {
    /// -1 = from the left, 1 = from the right
    let side: CGFloat
    let start = Date()
    @Environment(\.effectAssets) private var assets

    static let windup = 0.05, swingEnd = 0.12, holdEnd = 0.17, end = 0.34

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let swinging = t >= Self.windup && t < Self.swingEnd
            ZStack {
                if swinging {
                    let now = pose(t)
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.75))
                            .frame(width: 30, height: 2.5)
                            .offset(x: now.x + side * 48, y: -26 + CGFloat(i) * 16)
                    }
                    ForEach(1...3, id: \.self) { i in
                        hand(pose(t - Double(i) * 0.012)).opacity(0.38 - Double(i) * 0.1)
                    }
                }
                hand(pose(t))
            }
        }
        .allowsHitTesting(false)
    }

    private struct Pose {
        var x: CGFloat, angle: Double, opacity: Double, scale: CGFloat
    }

    private func pose(_ t: Double) -> Pose {
        switch t {
        case ..<Self.windup:
            let u = max(0, t / Self.windup)
            return Pose(x: side * (150 + 14 * u), angle: Double(side) * (-55 - 20 * u), opacity: u, scale: 0.9 + 0.1 * u)
        case ..<Self.swingEnd:
            let u = (t - Self.windup) / (Self.swingEnd - Self.windup)
            let e = u * u * u
            return Pose(x: side * (164 - 106 * e), angle: Double(side) * (-75 + 85 * e), opacity: 1, scale: 1)
        case ..<Self.holdEnd:
            return Pose(x: side * 56, angle: Double(side) * 12, opacity: 1, scale: 1.04)
        default:
            let u = min(1, (t - Self.holdEnd) / (Self.end - Self.holdEnd))
            let e = 1 - (1 - u) * (1 - u)
            return Pose(x: side * (56 + 54 * e), angle: Double(side) * (12 - 34 * e), opacity: 1 - u, scale: 1)
        }
    }

    private func hand(_ p: Pose) -> some View {
        HandArt(art: assets[.hand], size: 96)
            .scaleEffect(x: side < 0 ? 1 : -1, y: 1)
            .rotationEffect(.degrees(p.angle))
            .scaleEffect(p.scale)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .offset(x: p.x, y: -10)
            .opacity(p.opacity)
    }
}

// MARK: - Soda can

struct SodaCan: View {
    @Environment(\.effectAssets) private var assets

    var body: some View {
        if let art = assets[.can] {
            Image(nsImage: art).resizable().interpolation(.high).scaledToFit().frame(width: 32, height: 48)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0, blue: 0.04), Color(red: 0.85, green: 0.05, blue: 0.1),
                                              Color(red: 1, green: 0.45, blue: 0.45), Color(red: 0.85, green: 0.05, blue: 0.1),
                                              Color(red: 0.4, green: 0, blue: 0.03)],
                                     startPoint: .leading, endPoint: .trailing))
            Capsule().fill(.white).frame(width: 32, height: 5).rotationEffect(.degrees(-15))
            // specular streak
            Capsule().fill(.white.opacity(0.55)).frame(width: 3, height: 30).offset(x: -5)
            VStack {
                Capsule().fill(Self.silver).frame(height: 6)
                Spacer()
                Capsule().fill(Self.silver).frame(height: 5)
            }
            .padding(.vertical, -2)
        }
        .frame(width: 26, height: 44)
        .clipped()
    }

    private static let silver = LinearGradient(colors: [Color(white: 0.55), Color(white: 0.97), Color(white: 0.55)],
                                               startPoint: .leading, endPoint: .trailing)
}

/// The can's whole trip, closed-form: arc from the thrower's hand to the head, bounce off with
/// gravity, hit the ground, hop once, lie there and fade. Local pet coordinates, `side` = 1 for the right.
enum CanPath {
    static let flight = 0.38
    static let impact = CGPoint(x: 15, y: -55)
    static let kick = CGVector(dx: 95, dy: -300)
    static let gravity: CGFloat = 1500
    static let ground: CGFloat = 84
    static let restitution: CGFloat = 0.42

    /// Time from the head bonk to the first ground hit.
    static var fall: Double {
        let c = ground - impact.y
        return Double((-kick.dy + sqrt(kick.dy * kick.dy + 2 * gravity * c)) / gravity)
    }

    static var hopVelocity: CGFloat { -(kick.dy + gravity * CGFloat(fall)) * restitution }
    static var hop: Double { Double(2 * -hopVelocity / gravity) }
    static var firstBounceX: CGFloat { impact.x + kick.dx * CGFloat(fall) }
    static var restX: CGFloat { firstBounceX + kick.dx * 0.55 * CGFloat(hop) }
    static var total: Double { flight + fall + hop + 0.4 }

    struct State { var point: CGPoint; var angle: Double; var scale: CGFloat; var opacity: Double }

    static func state(at t: Double, side: CGFloat, from hand: CGPoint) -> State {
        if t < flight {
            let u = max(0, t / flight)
            let x = hand.x - (hand.x - impact.x) * CGFloat(u)
            let y = hand.y - (hand.y - impact.y) * CGFloat(u) - 70 * CGFloat(sin(u * .pi))
            return State(point: CGPoint(x: side * x, y: y), angle: -Double(side) * u * 5 * .pi, scale: 0.45 + 0.7 * CGFloat(u), opacity: 1)
        }
        let base = -Double(side) * 5 * .pi
        let tau = t - flight
        if tau < fall {
            let x = impact.x + kick.dx * CGFloat(tau)
            let y = impact.y + kick.dy * CGFloat(tau) + 0.5 * gravity * CGFloat(tau * tau)
            return State(point: CGPoint(x: side * x, y: y), angle: base + Double(side) * tau * 16, scale: 1.15, opacity: 1)
        }
        let tau2 = tau - fall
        if tau2 < hop {
            let x = firstBounceX + kick.dx * 0.55 * CGFloat(tau2)
            let y = ground + hopVelocity * CGFloat(tau2) + 0.5 * gravity * CGFloat(tau2 * tau2)
            return State(point: CGPoint(x: side * x, y: y), angle: base + Double(side) * (fall * 16 + tau2 * 8), scale: 1.15, opacity: 1)
        }
        let rest = tau2 - hop
        return State(point: CGPoint(x: side * restX, y: ground + 6), angle: .pi / 2 * Double(side), scale: 1.15,
                     opacity: max(0, 1 - rest / 0.4))
    }
}

struct ThrownCan: View {
    let side: CGFloat
    let start = Date()
    @Environment(\.effectAssets) private var assets

    private var hand: CGPoint { CanThrower.hand(illustrated: assets[.throwerIdle] != nil) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            ZStack {
                // motion ghosts while it's flying fast
                if t < CanPath.flight + CanPath.fall {
                    ForEach(1...3, id: \.self) { i in
                        can(CanPath.state(at: t - Double(i) * 0.022, side: side, from: hand)).opacity(0.32 - Double(i) * 0.08)
                    }
                }
                can(CanPath.state(at: t, side: side, from: hand))
            }
        }
        .allowsHitTesting(false)
    }

    private func can(_ s: CanPath.State) -> some View {
        SodaCan()
            .rotationEffect(.radians(s.angle))
            .scaleEffect(s.scale)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: s.point.x, y: s.point.y)
            .opacity(s.opacity)
    }
}

// MARK: - Lingering threats

/// A small figure "in the distance" juggling a soda can. While a can attack runs it
/// throws overhand instead (synced to `lastThrow`) and the juggled can is hidden.
struct CanThrower: View {
    var attacking: Bool
    var lastThrow: Date?
    @Environment(\.effectAssets) private var assets

    static let offset = CGSize(width: 112, height: 45)

    /// Where thrown cans start, relative to the pet's center: the throwing hand of the drawn
    /// figure, or of the illustrated throw pose (its hand is at the far left of the art).
    static func hand(illustrated: Bool) -> CGPoint {
        illustrated ? CGPoint(x: 84, y: 38) : CGPoint(x: 108, y: 36)
    }

    private static let size = CGSize(width: 50, height: 90)
    private static let shoulder = CGPoint(x: 31, y: 50)
    private static let armLength: CGFloat = 16
    private static let period = 1.6

    var body: some View {
        if assets[.throwerIdle] != nil {
            illustrated
        } else {
            drawn
        }
    }

    /// Illustrated thrower: swaps between idle / toss / throw art; the can is still animated in code.
    private var illustrated: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let frame = illustratedFrame(at: context.date)
            ZStack(alignment: .topLeading) {
                if let art = frame.art {
                    Image(nsImage: art).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 60, height: 96, alignment: .bottom)
                }
                if let can = frame.can {
                    SodaCan().scaleEffect(0.42).rotationEffect(.radians(frame.spin)).position(can)
                }
            }
            .frame(width: 60, height: 96)
        }
        .offset(x: Self.offset.width - 2, y: Self.offset.height - 3)
    }

    private func illustratedFrame(at date: Date) -> (art: NSImage?, can: CGPoint?, spin: Double) {
        let t = date.timeIntervalSinceReferenceDate
        if attacking {
            let dt = lastThrow.map { date.timeIntervalSince($0) } ?? 1
            let art = dt < 0.45 ? (assets[.throwerThrow] ?? assets[.throwerToss]) : (assets[.throwerToss] ?? assets[.throwerIdle])
            return (art ?? assets[.throwerIdle], nil, 0)
        }
        let u = t.truncatingRemainder(dividingBy: Self.period) / Self.period
        let airborne = u >= 0.25 && u < 0.85
        let v = airborne ? (u - 0.25) / 0.6 : 0
        let art = airborne ? (assets[.throwerToss] ?? assets[.throwerIdle]) : assets[.throwerIdle]
        // Rests on the idle pose's open hand, peaks just above the raised toss hand.
        return (art, CGPoint(x: 10, y: 47 - 40 * 4 * v * (1 - v)), v * .pi * 4)
    }

    private var drawn: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pose = attacking ? throwPose(context.date) : jugglePose(t)
            ZStack(alignment: .topLeading) {
                figure(armAngle: pose.arm)
                if let can = pose.can {
                    SodaCan()
                        .scaleEffect(0.42)
                        .rotationEffect(.radians(can.spin))
                        .position(can.point)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .offset(Self.offset)
    }

    /// Arm angle in degrees: 0 = hanging down, 90 = out to the side, 180 = straight up.
    private func hand(_ angle: Double) -> CGPoint {
        let r = angle * .pi / 180
        return CGPoint(x: Self.shoulder.x + Self.armLength * sin(r), y: Self.shoulder.y + Self.armLength * cos(r))
    }

    private func jugglePose(_ t: TimeInterval) -> (arm: Double, can: (point: CGPoint, spin: Double)?) {
        let u = t.truncatingRemainder(dividingBy: Self.period) / Self.period
        let arm: Double
        switch u {
        case ..<0.2: arm = 80 - 25 * sin(.pi * u / 0.2)        // dip before the toss
        case ..<0.3: arm = 80 + 70 * (u - 0.2) / 0.1           // toss
        case ..<0.85: arm = 150 - 50 * (u - 0.3) / 0.55        // wait for it
        default: arm = 100 - 20 * (u - 0.85) / 0.15            // catch and settle
        }
        let held = hand(arm)
        guard u >= 0.3, u < 0.85 else {
            return (arm, (CGPoint(x: held.x, y: held.y - 6), 0))
        }
        let v = (u - 0.3) / 0.55
        let from = hand(150), to = hand(100)
        let x = from.x + (to.x - from.x) * v
        let y = from.y + (to.y - from.y) * v - 6 - 45 * 4 * v * (1 - v)
        return (arm, (CGPoint(x: x, y: y), v * .pi * 4))
    }

    private func throwPose(_ now: Date) -> (arm: Double, can: (point: CGPoint, spin: Double)?) {
        guard let lastThrow else { return (200, nil) }
        let dt = now.timeIntervalSince(lastThrow)
        switch dt {
        case ..<0.12: return (120 + 110 * dt / 0.12, nil)      // overhand release toward the pet
        case ..<0.5: return (230 - 60 * (dt - 0.12) / 0.38, nil)
        default: return (170, nil)                              // cocked for the next throw
        }
    }

    private func figure(armAngle: Double) -> some View {
        let skin = Color(red: 1, green: 0.85, blue: 0.7)
        let h = hand(armAngle)
        return ZStack(alignment: .topLeading) {
            // legs
            Capsule().fill(Color(white: 0.25)).frame(width: 5, height: 20).rotationEffect(.degrees(8)).position(x: 21, y: 79)
            Capsule().fill(Color(white: 0.25)).frame(width: 5, height: 20).rotationEffect(.degrees(-8)).position(x: 29, y: 79)
            // idle arm
            Capsule().fill(skin).frame(width: 4, height: Self.armLength).rotationEffect(.degrees(20)).position(x: 17, y: 57)
            // body
            RoundedRectangle(cornerRadius: 4).fill(Color.blue).frame(width: 16, height: 24).position(x: 25, y: 60)
            // throwing arm
            Capsule().fill(skin)
                .frame(width: 4, height: Self.armLength)
                .rotationEffect(.degrees(-armAngle))
                .position(x: (Self.shoulder.x + h.x) / 2, y: (Self.shoulder.y + h.y) / 2)
            // head with a cap and a grumpy face
            Circle().fill(skin).frame(width: 16, height: 16).position(x: 25, y: 40)
            Capsule().fill(Color.red).frame(width: 18, height: 6).position(x: 24, y: 33)
            Capsule().fill(Color.red).frame(width: 8, height: 3).position(x: 18, y: 35)
            Path { p in
                p.move(to: CGPoint(x: 19, y: 38)); p.addLine(to: CGPoint(x: 23, y: 39.5))
                p.move(to: CGPoint(x: 31, y: 38)); p.addLine(to: CGPoint(x: 27, y: 39.5))
                p.move(to: CGPoint(x: 22, y: 45)); p.addQuadCurve(to: CGPoint(x: 28, y: 45), control: CGPoint(x: 25, y: 43))
            }
            .stroke(Color.black, lineWidth: 1.2)
            Circle().fill(Color.black).frame(width: 2.5, height: 2.5).position(x: 21.5, y: 41)
            Circle().fill(Color.black).frame(width: 2.5, height: 2.5).position(x: 28.5, y: 41)
        }
    }
}

/// A hand hovering beside the pet, limbering up and taking the odd practice swing.
struct HoveringHand: View {
    @Environment(\.effectAssets) private var assets

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let swing = t.truncatingRemainder(dividingBy: 3.2)  // practice swing every 3.2s
            let lunge = swing < 0.35 ? sin(swing / 0.35 * .pi) : 0
            HandArt(art: assets[.hand], size: 54)
                .rotationEffect(.degrees(sin(t * 7) * 12 * (1 - lunge) + lunge * 25))
                .offset(x: -112 + lunge * 18, y: -10 + sin(t * 2.2) * 5)
        }
    }
}

/// The slapping hand: illustrated art if available, otherwise the emoji.
struct HandArt: View {
    let art: NSImage?
    let size: CGFloat

    var body: some View {
        if let art {
            Image(nsImage: art).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        } else {
            Text("🖐️").font(.system(size: size * 0.88))
        }
    }
}
