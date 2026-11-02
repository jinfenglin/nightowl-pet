import SwiftUI

/// Fixed geometry of the pet window (bottom-aligned layout), in window coordinates.
/// The pet stage's local origin (0, 0) is `petCenter`.
enum Stage {
    static let size = CGSize(width: 280, height: 420)
    static let petCenter = CGPoint(x: 140, y: 320)
    static let head = CGPoint(x: 140, y: 268)
    /// Where the cloud's underside sits (the cloud is directly above the HP bar).
    static let cloudBottom: CGFloat = 188

    static func window(_ local: CGPoint) -> CGPoint {
        CGPoint(x: petCenter.x + local.x, y: petCenter.y + local.y)
    }
}

// MARK: - Particles

struct Particle {
    enum Kind { case spark, chip, dust, ring, star, arc }

    let kind: Kind
    let birth: Date
    let life: Double
    let origin: CGPoint
    var velocity = CGVector.zero  // pt/s
    var gravity: CGFloat = 0       // pt/s², downward
    var drag: CGFloat = 0          // exponential velocity decay, 1/s
    var size: CGFloat = 3
    var color: Color = .white
    var spin: Double = 0           // rad/s
    let seed = Double.random(in: 0...1000)

    func age(at now: Date) -> Double { now.timeIntervalSince(birth) }

    func position(at t: Double) -> CGPoint {
        let k = Double(drag)
        let travel = k > 0 ? (1 - exp(-k * t)) / k : t
        return CGPoint(x: origin.x + velocity.dx * travel,
                       y: origin.y + velocity.dy * travel + 0.5 * gravity * t * t)
    }

    func currentVelocity(at t: Double) -> CGVector {
        let decay = exp(-Double(drag) * t)
        return CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay + gravity * t)
    }
}

@MainActor
final class ParticleSystem: ObservableObject {
    @Published private(set) var particles: [Particle] = []

    func emit(_ new: [Particle]) {
        particles += new
        let longest = new.map(\.life).max() ?? 0
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(longest + 0.05))
            let now = Date()
            self?.particles.removeAll { $0.age(at: now) > $0.life }
        }
    }

    // MARK: Emitters (window coordinates)

    /// Glowing streaks flying out of `point` within an angle range (radians, 0 = right, -π/2 = up).
    static func sparks(at point: CGPoint, count: Int, color: Color, angle: ClosedRange<Double> = -.pi...0,
                       speed: ClosedRange<Double> = 160...420, gravity: CGFloat = 520, life: ClosedRange<Double> = 0.3...0.6) -> [Particle] {
        let now = Date()
        return (0..<count).map { _ in
            let a = Double.random(in: angle), s = Double.random(in: speed)
            return Particle(kind: .spark, birth: now, life: .random(in: life), origin: point,
                            velocity: CGVector(dx: cos(a) * s, dy: sin(a) * s), gravity: gravity, drag: 3,
                            size: .random(in: 1.6...2.8), color: color)
        }
    }

    static func chips(at point: CGPoint, count: Int, colors: [Color], angle: ClosedRange<Double> = -.pi...0) -> [Particle] {
        let now = Date()
        return (0..<count).map { _ in
            let a = Double.random(in: angle), s = Double.random(in: 120...300)
            return Particle(kind: .chip, birth: now, life: .random(in: 0.5...0.8), origin: point,
                            velocity: CGVector(dx: cos(a) * s, dy: sin(a) * s), gravity: 900, drag: 1.5,
                            size: .random(in: 3...5), color: colors.randomElement()!, spin: .random(in: -14...14))
        }
    }

    static func dust(at point: CGPoint, count: Int, color: Color = Color(white: 0.85)) -> [Particle] {
        let now = Date()
        return (0..<count).map { i in
            let dir: Double = i.isMultiple(of: 2) ? 1 : -1
            return Particle(kind: .dust, birth: now, life: .random(in: 0.45...0.7), origin: point,
                            velocity: CGVector(dx: dir * .random(in: 30...90), dy: -.random(in: 10...45)), drag: 4,
                            size: .random(in: 6...10), color: color)
        }
    }

    static func ring(at point: CGPoint, radius: CGFloat, color: Color, life: Double = 0.35) -> [Particle] {
        [Particle(kind: .ring, birth: Date(), life: life, origin: point, size: radius, color: color)]
    }

    static func stars(at point: CGPoint, count: Int, color: Color = .yellow) -> [Particle] {
        let now = Date()
        return (0..<count).map { _ in
            let a = Double.random(in: -.pi...0), s = Double.random(in: 60...160)
            return Particle(kind: .star, birth: now, life: .random(in: 0.45...0.7), origin: point,
                            velocity: CGVector(dx: cos(a) * s, dy: sin(a) * s), gravity: 120, drag: 2.5,
                            size: .random(in: 5...8), color: color, spin: .random(in: -6...6))
        }
    }

    /// Flickering electric arcs crawling over a rectangle.
    static func arcs(in rect: CGRect, count: Int, color: Color, life: Double = 0.4) -> [Particle] {
        let now = Date()
        return (0..<count).map { _ in
            Particle(kind: .arc, birth: now.addingTimeInterval(.random(in: 0...0.12)), life: life,
                     origin: CGPoint(x: .random(in: rect.minX...rect.maxX), y: .random(in: rect.minY...rect.maxY)),
                     size: .random(in: 16...28), color: color)
        }
    }
}

struct ParticleLayer: View {
    @ObservedObject var system: ParticleSystem

    var body: some View {
        TimelineView(.animation(paused: system.particles.isEmpty)) { timeline in
            Canvas { context, _ in
                let now = timeline.date
                for p in system.particles {
                    let t = p.age(at: now)
                    guard t >= 0, t <= p.life else { continue }
                    draw(p, t: t, u: t / p.life, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ p: Particle, t: Double, u: Double, in context: inout GraphicsContext) {
        let pos = p.position(at: t)
        switch p.kind {
        case .spark:
            let v = p.currentVelocity(at: t)
            let speed = max(1, hypot(v.dx, v.dy))
            let length = min(speed * 0.04, 22) * (1 - u) + 2
            var path = Path()
            path.move(to: pos)
            path.addLine(to: CGPoint(x: pos.x - v.dx / speed * length, y: pos.y - v.dy / speed * length))
            context.blendMode = .plusLighter
            context.stroke(path, with: .color(p.color.opacity(0.55 * (1 - u))),
                           style: StrokeStyle(lineWidth: p.size * 2.6, lineCap: .round))
            context.stroke(path, with: .color(.white.opacity(1 - u * u)),
                           style: StrokeStyle(lineWidth: p.size * 0.9, lineCap: .round))
            context.blendMode = .normal

        case .chip:
            var chip = context
            chip.translateBy(x: pos.x, y: pos.y)
            chip.rotate(by: .radians(p.spin * t))
            let rect = CGRect(x: -p.size / 2, y: -p.size * 0.3, width: p.size, height: p.size * 0.6)
            chip.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(p.color.opacity(1 - pow(u, 3))))

        case .dust:
            let r = p.size * (0.6 + 1.3 * u)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.fill(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(p.color.opacity(0.45 * (1 - u))))
            }

        case .ring:
            let eased = 1 - pow(1 - u, 3)
            let r = p.size * eased
            context.blendMode = .plusLighter
            context.stroke(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(p.color.opacity(1 - u)), lineWidth: 4 * (1 - u) + 0.6)
            context.blendMode = .normal

        case .star:
            var star = context
            star.translateBy(x: pos.x, y: pos.y)
            star.rotate(by: .radians(p.spin * t))
            star.blendMode = .plusLighter
            star.fill(Sparkle().path(in: CGRect(x: -p.size, y: -p.size, width: 2 * p.size, height: 2 * p.size)),
                      with: .color(p.color.opacity(1 - u)))

        case .arc:
            // re-shape every 40ms and blink, like a crackling discharge
            let frame = floor(t / 0.04)
            guard Int(t / 0.03) % 3 != 2 else { return }
            var rng = SeededRandom(seed: UInt64(p.seed * 1000 + frame))
            var path = Path()
            let heading = rng.next() * 2 * .pi
            var point = pos
            path.move(to: point)
            for _ in 0..<5 {
                let a = heading + (rng.next() - 0.5) * 1.6
                point = CGPoint(x: point.x + cos(a) * p.size / 5, y: point.y + sin(a) * p.size / 5)
                path.addLine(to: point)
            }
            context.blendMode = .plusLighter
            context.stroke(path, with: .color(p.color.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            context.blendMode = .normal
        }
    }
}

/// Small deterministic PRNG so an arc keeps its shape for a frame.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

// MARK: - Shapes & text

/// Four-point twinkle.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.28
        return Path { p in
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        }
    }
}

/// Five-point star.
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), outer = min(rect.width, rect.height) / 2, inner = outer * 0.45
        return Path { p in
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? outer : inner
                let a = Double(i) * .pi / 5 - .pi / 2
                let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
        }
    }
}

/// Comic-book impact burst.
struct Burst: Shape {
    var points = 12
    var seed: UInt64 = 7

    func path(in rect: CGRect) -> Path {
        var rng = SeededRandom(seed: seed)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return Path { p in
            for i in 0..<(points * 2) {
                let outer = i.isMultiple(of: 2)
                let jitter = 0.85 + rng.next() * 0.25
                let rx = rect.width / 2 * (outer ? jitter : 0.62), ry = rect.height / 2 * (outer ? jitter : 0.62)
                let a = Double(i) * .pi / Double(points) - .pi / 2
                let pt = CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
        }
    }
}

/// Heavy rounded text with a solid outline (drawn as offset copies, so it works on any background).
struct OutlinedText: View {
    let text: String
    var size: CGFloat
    var fill: AnyShapeStyle
    var outline: Color = Color(red: 0.25, green: 0.02, blue: 0.05)
    var width: CGFloat = 2.2

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: .black, design: .rounded))
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                let a = Double(i) * .pi / 6
                label.foregroundStyle(outline).offset(x: cos(a) * width, y: sin(a) * width)
            }
            label.foregroundStyle(fill)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
    }
}

/// "啪!" / "咚!" on a comic burst that pops in and fades.
struct ComicPow: View {
    let text: String
    let color: Color
    let tilt: Double
    @State private var phase = 0

    var body: some View {
        ZStack {
            Burst(seed: UInt64(abs(tilt * 100)))
                .fill(RadialGradient(colors: [.white, color], center: .center, startRadius: 2, endRadius: 46))
                .overlay(Burst(seed: UInt64(abs(tilt * 100))).stroke(Cindy.ink, lineWidth: 2.5))
                .frame(width: 92, height: 74)
            OutlinedText(text: text, size: text.count > 4 ? 23 : 30, fill: AnyShapeStyle(Color.white), outline: Cindy.ink)  // English words are longer
        }
        .rotationEffect(.degrees(tilt))
        .scaleEffect(phase == 0 ? 0.2 : (phase == 1 ? 1.18 : 1))
        .opacity(phase == 3 ? 0 : 1)
        .task {
            withAnimation(.spring(response: 0.14, dampingFraction: 0.45)) { phase = 1 }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { phase = 2 }
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.easeIn(duration: 0.18)) { phase = 3 }
        }
    }
}

/// Damage / heal number: pops, rises with a slight drift, fades.
struct DamageNumber: View {
    let text: String
    let heal: Bool
    let big: Bool
    let dx: CGFloat
    @State private var phase = 0

    var body: some View {
        let fill = heal
            ? LinearGradient(colors: [.white, Cindy.blueHot, Cindy.blue], startPoint: .top, endPoint: .bottom)
            : big
                ? LinearGradient(colors: [Color(red: 1, green: 0.95, blue: 0.7), Cindy.gold], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [.white, Cindy.redHot, Cindy.red], startPoint: .top, endPoint: .bottom)
        OutlinedText(text: text, size: big ? 34 : 27, fill: AnyShapeStyle(fill),
                     outline: Cindy.ink)
            .scaleEffect(phase == 0 ? 0.3 : (phase == 1 ? 1.3 : 1))
            // stays inside the pet area so it never covers the HP bar
            .offset(x: dx + (phase >= 2 ? dx * 0.5 : 0), y: phase == 0 ? -10 : (phase == 1 ? -34 : -72))
            .opacity(phase == 3 ? 0 : 1)
            .task {
                withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { phase = 1 }
                try? await Task.sleep(for: .milliseconds(170))
                withAnimation(.easeOut(duration: 0.8)) { phase = 2 }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeIn(duration: 0.3)) { phase = 3 }
            }
    }
}

/// Stars circling the head after a bonk.
struct DizzyStars: View {
    let start = Date()
    static let life = 1.4

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let fade = max(0, min(1, (Self.life - t) / 0.3))
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let a = t * 7 + Double(i) * 2 * .pi / 3
                    let depth = (sin(a) + 1) / 2  // 1 = front
                    StarShape()
                        .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
                        .overlay(StarShape().stroke(Color(red: 0.55, green: 0.25, blue: 0), lineWidth: 1.2))
                        .frame(width: 14, height: 14)
                        .scaleEffect(0.7 + 0.45 * depth)
                        .opacity((0.55 + 0.45 * depth) * fade)
                        .offset(x: cos(a) * 36, y: -86 + sin(a) * 9)
                        .zIndex(depth)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A soft radial flash that lights up the area around an impact (no hard edges on the transparent window).
struct ImpactFlash: View {
    let color: Color
    let center: UnitPoint
    var radius: CGFloat = 200
    var strength: Double = 0.6
    @State private var on = true

    var body: some View {
        RadialGradient(colors: [color.opacity(strength), color.opacity(strength * 0.3), .clear],
                       center: center, startRadius: 0, endRadius: radius)
            .blendMode(.plusLighter)
            .opacity(on ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.28)) { on = false } }
    }
}

/// Light drizzle under the storm cloud while it lingers.
struct RainLayer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let top = Stage.cloudBottom, bottom = Stage.petCenter.y + 70
                for i in 0..<12 {
                    var rng = SeededRandom(seed: UInt64(i * 7919))
                    let x = 82 + rng.next() * 116
                    let speed = 300 + rng.next() * 120
                    let phase = rng.next()
                    let y = top + (t * speed / (bottom - top) + phase).truncatingRemainder(dividingBy: 1) * (bottom - top)
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: y))
                    drop.addLine(to: CGPoint(x: x - 1.5, y: y + 9))
                    context.stroke(drop, with: .color(Color(red: 0.75, green: 0.8, blue: 1).opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
