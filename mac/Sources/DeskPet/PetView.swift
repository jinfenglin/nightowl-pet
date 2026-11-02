import SwiftUI

struct PetView: View {
    @ObservedObject var store: PetStore
    @StateObject private var particles = ParticleSystem()

    @State private var knock = CGSize.zero
    @State private var knockAngle = 0.0
    @State private var squash = CGSize(width: 1, height: 1)
    @State private var whiteFlash = false
    @State private var tint: Color = .white
    @State private var zapped = false
    @State private var cloudFlash = false
    @State private var hurting = false
    @State private var lastCanThrow: Date?
    @State private var effects: [Effect] = []
    @State private var flashes: [FlashItem] = []
    @State private var numbers: [NumberItem] = []

    private static let purple = Color(red: 0.62, green: 0.35, blue: 1)
    private static let lavender = Color(red: 0.85, green: 0.75, blue: 1)

    private var lightningShown: Bool { store.activeAttack == .lightning || store.menace == .lightning }

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if let text = store.speech {
                SpeechBubble(text: text)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
            if lightningShown {
                StormCloud(flash: cloudFlash)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HPBar(hp: store.hp, maxHP: store.maxHP)
                .frame(width: 160)
            ZStack {
                if store.activeAttack == .can || store.menace == .can {
                    CanThrower(attacking: store.activeAttack == .can, lastThrow: lastCanThrow)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                // Breathing runs as a Core Animation loop (see LayerLoop.swift); hit reactions are
                // SwiftUI modifiers outside it, so the two never fight.
                LayerLoop(active: !store.isDead, motion: .breathe(from: CGSize(width: 1, height: 1), to: CGSize(width: 0.92, height: 1), lift: 0)) {
                    groundShadow
                }
                .frame(width: 180, height: 180)
                .scaleEffect(x: squash.width, y: 1)
                .offset(x: knock.width * 0.5)
                LayerLoop(active: !store.isDead, motion: .breathe(from: CGSize(width: 1.01, height: 0.99), to: CGSize(width: 0.985, height: 1.025), lift: 4)) {
                    sprite
                }
                .frame(width: 180, height: 180)
                .scaleEffect(x: squash.width, y: squash.height, anchor: .bottom)
                .rotationEffect(.degrees(knockAngle), anchor: .bottom)
                .offset(knock)
                if store.menace == .slap && store.activeAttack != .slap {
                    HoveringHand().transition(.opacity)
                }
                ForEach(effects) { effectView($0) }
                ForEach(numbers) { n in
                    DamageNumber(text: n.text, heal: n.heal, big: n.big, dx: n.dx)
                }
            }
            .frame(width: 180, height: 180)
            .padding(.bottom, 10)
        }
        .frame(width: Stage.size.width, height: Stage.size.height, alignment: .bottom)
        .environment(\.effectAssets, store.effects)
        .overlay {
            // window-space layers: drizzle, impact light, particles
            ZStack {
                if lightningShown { RainLayer().transition(.opacity) }
                ForEach(flashes) { f in
                    ImpactFlash(color: f.color, center: f.center, radius: f.radius, strength: f.strength)
                }
                ParticleLayer(system: particles)
            }
            .frame(width: Stage.size.width, height: Stage.size.height)
        }
        .animation(.spring(duration: 0.3), value: store.speech)
        .animation(.easeOut(duration: 0.35), value: store.activeAttack)
        .animation(.easeOut(duration: 0.4), value: store.menace)
        .animation(.spring(duration: 0.6, bounce: 0.4), value: store.isDead)
        .onChange(of: store.lastHit) { _, hit in
            guard let hit else { return }
            switch hit.style {
            case .lightning: strike(hit)
            case .slap: slap(hit)
            case .can, .random: throwCan(hit)
            }
        }
        .onChange(of: store.lastHeal) { _, heal in
            guard let heal else { return }
            addNumber("+\(heal.amount)", heal: true, big: false)
            particles.emit(ParticleSystem.stars(at: Stage.petCenter, count: 10, color: Cindy.blueHot))
            particles.emit(ParticleSystem.ring(at: Stage.petCenter, radius: 80, color: Cindy.blue, life: 0.5))
        }
        .onChange(of: store.activeAttack) { _, attack in
            if attack == nil { hurting = false }
        }
    }

    private var pose: PetPose {
        if store.isDead { return .dead }
        if hurting { return .hurt }
        return store.isLow ? .low : .normal
    }

    /// Whether the current pose has its own art (otherwise fake it with effects).
    private func drawn(_ p: PetPose) -> Bool {
        pose == p && store.images[p] != nil
    }

    private var groundShadow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(0.32), .black.opacity(0.12), .clear],
                                 center: .center, startRadius: 0, endRadius: 65))
            .frame(width: 140, height: 24)
            .offset(y: 86)
            .allowsHitTesting(false)
    }

    private var sprite: some View {
        petImage
            // electrocuted look: an inverted copy flickers on top, visible on any colors
            .overlay { if zapped { petImage.colorInvert() } }
            .colorMultiply(tint)
            .brightness(whiteFlash ? 1 : 0)  // the classic one-frame white hit flash
            .shadow(color: Self.purple.opacity(zapped ? 1 : 0), radius: zapped ? 14 : 0)
            .saturation(fakeDead ? 0 : (fakeLow ? 0.6 : 1))
            .rotationEffect(.degrees(fakeDead ? 90 : 0))
            .overlay(alignment: .topTrailing) {
                if fakeDead {
                    OutlinedText(text: "Z z z", size: 18, fill: AnyShapeStyle(Color.white),
                                 outline: Color(red: 0.1, green: 0.15, blue: 0.35), width: 1.6)
                } else if fakeLow {
                    SweatDrop().frame(width: 16, height: 22).padding(8)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            // Cindy-style blue / red rim light
            .shadow(color: Cindy.blue.opacity(0.55), radius: 3, x: -2.5)
            .shadow(color: Cindy.red.opacity(0.55), radius: 3, x: 2.5)
            // flatten into one cached layer so breathing / recoil only transform it;
            // padding keeps the glow from being clipped
            .padding(32)
            .drawingGroup()
            .padding(-32)
            .overlay {
                if store.isBusy {  // a live AppKit control, so it stays outside the drawing group
                    ProgressView().controlSize(.large)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    private var fakeDead: Bool { store.isDead && !drawn(.dead) }
    private var fakeLow: Bool { pose == .low && !drawn(.low) }

    @ViewBuilder
    private var petImage: some View {
        if let image = store.images[pose] ?? store.petImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
                Text("🐣").font(.system(size: 90))
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func effectView(_ effect: Effect) -> some View {
        switch effect.kind {
        case .bolt:
            // from inside the storm cloud (above the HP bar) down to the head
            BoltView().frame(width: 90, height: 104).offset(y: -100)
        case .hand(let side):
            SlapHand(side: side)
        case .pow(let text, let x, let y, let color, let tilt):
            ComicPow(text: text, color: color, tilt: tilt).offset(x: x, y: y)
        case .can(let side):
            ThrownCan(side: side)
        case .dizzy:
            DizzyStars()
        }
    }

    // MARK: - Hits

    private func strike(_ hit: HitEvent) {
        add(.bolt, life: 0.5)
        cloudFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(hit.style.impactDelay))
            let head = Stage.head
            particles.emit(ParticleSystem.sparks(at: head, count: 24, color: Self.purple, angle: -.pi * 1.15 ... .pi * 0.15, speed: 180...480))
            particles.emit(ParticleSystem.ring(at: head, radius: 80, color: Self.purple))
            particles.emit(ParticleSystem.arcs(in: CGRect(x: 80, y: 258, width: 120, height: 120), count: 7, color: Self.purple))
            flash(Self.lavender, at: head, radius: 240, strength: 0.55)
            impact(hit, push: CGVector(dx: 0, dy: 7), squashTo: CGSize(width: 1.08, height: 0.9),
                   tint: Color(red: 0.75, green: 0.55, blue: 1))
            try? await Task.sleep(for: .milliseconds(60))  // after the white frame
            for _ in 0..<2 {
                zapped = true
                try? await Task.sleep(for: .milliseconds(60))
                zapped = false
                try? await Task.sleep(for: .milliseconds(45))
            }
            cloudFlash = false
        }
    }

    private func slap(_ hit: HitEvent) {
        let side: CGFloat = hit.index.isMultiple(of: 2) ? -1 : 1
        add(.hand(side), life: SlapHand.end + 0.05)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(hit.style.impactDelay))
            let cheek = Stage.window(CGPoint(x: side * 46, y: -22))
            let away = side < 0 ? 0.0 : Double.pi  // the way the hand was moving
            particles.emit(ParticleSystem.sparks(at: cheek, count: 10, color: .white, angle: away - 0.9 ... away + 0.9,
                                                 speed: 200...420, gravity: 260, life: 0.2...0.35))
            particles.emit(ParticleSystem.stars(at: cheek, count: 3))
            particles.emit(ParticleSystem.ring(at: cheek, radius: 46, color: .white, life: 0.25))
            flash(.white, at: cheek, radius: 150, strength: 0.3)
            add(.pow((AppLanguage.isEnglish ? ["SLAP!", "WHAP!", "PIA!"] : ["啪!", "啪!!", "PIA!"]).randomElement()!, side * 60, -34, Cindy.red, Double(side) * -12),
                life: 0.65)
            impact(hit, push: CGVector(dx: -side * 13, dy: 0), tilt: -Double(side) * 16,
                   squashTo: CGSize(width: 0.92, height: 1.04), tint: Color(red: 1, green: 0.5, blue: 0.5))
        }
    }

    private func throwCan(_ hit: HitEvent) {
        let side: CGFloat = 1  // the thrower stands on the right
        lastCanThrow = Date()
        add(.can(side), life: CanPath.total + 0.1)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CanPath.flight))
            let bonk = Stage.window(CGPoint(x: side * CanPath.impact.x, y: CanPath.impact.y))
            particles.emit(ParticleSystem.sparks(at: bonk, count: 14, color: Color(red: 1, green: 0.8, blue: 0.35), speed: 200...440))
            particles.emit(ParticleSystem.chips(at: bonk, count: 5, colors: [.red, .white, Color(white: 0.8)]))
            particles.emit(ParticleSystem.ring(at: bonk, radius: 52, color: .white, life: 0.3))
            flash(Color(red: 1, green: 0.9, blue: 0.7), at: bonk, radius: 160, strength: 0.35)
            add(.pow(L("咚!", "BONK!"), 56, -56, Cindy.gold, 10), life: 0.65)
            add(.dizzy, life: DizzyStars.life, replacing: true)
            impact(hit, push: CGVector(dx: 0, dy: 9), squashTo: CGSize(width: 1.16, height: 0.82),
                   tint: Color(red: 1, green: 0.6, blue: 0.55))

            try? await Task.sleep(for: .seconds(CanPath.fall))
            let land = Stage.window(CGPoint(x: side * CanPath.firstBounceX, y: CanPath.ground + 20))
            particles.emit(ParticleSystem.dust(at: land, count: 7))
            try? await Task.sleep(for: .seconds(CanPath.hop))
            particles.emit(ParticleSystem.dust(at: Stage.window(CGPoint(x: side * CanPath.restX, y: CanPath.ground + 20)), count: 4))
        }
    }

    /// Shared hit reaction: white frame + hit-stop, then the tint and a springy recoil with follow-through.
    private func impact(_ hit: HitEvent, push: CGVector, tilt: Double = 0, squashTo: CGSize, tint color: Color) {
        hurting = true  // stays on for the rest of the combo
        addNumber("-\(hit.amount)", heal: false, big: hit.amount >= 5)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            whiteFlash = true
            knock = CGSize(width: push.dx, height: push.dy)
            knockAngle = tilt
            squash = squashTo
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(55))  // hit-stop
            whiteFlash = false
            tint = color
            withAnimation(.interpolatingSpring(stiffness: 280, damping: 9)) {
                knock = .zero
                knockAngle = 0
                squash = CGSize(width: 1, height: 1)
            }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeOut(duration: 0.35)) { tint = .white }
        }
    }

    private func flash(_ color: Color, at point: CGPoint, radius: CGFloat, strength: Double) {
        // fade out before the window edge, or the transparent window's rectangle shows
        let edge = min(point.x, Stage.size.width - point.x, point.y, Stage.size.height - point.y)
        let radius = min(radius, edge)
        let item = FlashItem(color: color, center: UnitPoint(x: point.x / Stage.size.width, y: point.y / Stage.size.height),
                             radius: radius, strength: strength)
        flashes.append(item)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            flashes.removeAll { $0.id == item.id }
        }
    }

    private func add(_ kind: Effect.Kind, life: Double, replacing: Bool = false) {
        let effect = Effect(kind: kind)
        if replacing { effects.removeAll { $0.kind.tag == kind.tag } }
        effects.append(effect)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(life))
            effects.removeAll { $0.id == effect.id }
        }
    }

    private func addNumber(_ text: String, heal: Bool, big: Bool) {
        let item = NumberItem(text: text, heal: heal, big: big, dx: .random(in: -28...28))
        numbers.append(item)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            numbers.removeAll { $0.id == item.id }
        }
    }
}

private struct Effect: Identifiable {
    enum Kind {
        case bolt
        case hand(CGFloat)
        case pow(String, CGFloat, CGFloat, Color, Double)
        case can(CGFloat)
        case dizzy

        var tag: String {
            switch self {
            case .bolt: return "bolt"
            case .hand: return "hand"
            case .pow: return "pow"
            case .can: return "can"
            case .dizzy: return "dizzy"
            }
        }
    }

    let id = UUID()
    let kind: Kind
}

private struct FlashItem: Identifiable {
    let id = UUID()
    let color: Color
    let center: UnitPoint
    let radius: CGFloat
    let strength: Double
}

private struct NumberItem: Identifiable {
    let id = UUID()
    let text: String
    let heal: Bool
    let big: Bool
    let dx: CGFloat
}

private struct SweatDrop: View {
    var body: some View {
        Teardrop()
            .fill(LinearGradient(colors: [Color(red: 0.75, green: 0.9, blue: 1), Color(red: 0.25, green: 0.6, blue: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Teardrop().stroke(Color(red: 0.1, green: 0.3, blue: 0.6), lineWidth: 1.2))
            .overlay(alignment: .bottomLeading) {
                Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 6).offset(x: 4, y: -4)
            }
    }

    private struct Teardrop: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                           control1: CGPoint(x: rect.maxX + rect.width * 0.1, y: rect.maxY * 0.7),
                           control2: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                           control1: CGPoint(x: rect.minX, y: rect.maxY),
                           control2: CGPoint(x: rect.minX - rect.width * 0.1, y: rect.maxY * 0.7))
            }
        }
    }
}

/// Cindy-style HP bar: dark glass with a blue→red rim light, a red "HP" tag, pencil-hatched fill,
/// a delayed "ghost" drain, a jolt and white flash on damage, a heartbeat glow when low, a shine on heal.
struct HPBar: View {
    let hp: Int
    let maxHP: Int

    @State private var jolt: CGFloat = 0
    @State private var hitFlash = false
    @State private var shine: CGFloat = -0.3

    private var ratio: CGFloat { CGFloat(max(0, hp)) / CGFloat(maxHP) }
    private var low: Bool { ratio < 0.3 }

    /// Highlight, body and shade for the current HP band: electric blue, gold, Cindy red.
    private var stops: [Color] {
        if ratio > 0.6 { return [Cindy.blueHot, Cindy.blue, Color(red: 0.08, green: 0.2, blue: 0.6)] }
        if ratio > 0.3 { return [Color(red: 1, green: 0.9, blue: 0.55), Cindy.gold, Color(red: 0.6, green: 0.4, blue: 0.05)] }
        return [Cindy.redHot, Cindy.red, Color(red: 0.45, green: 0.02, blue: 0.05)]
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("HP")
                .font(.system(size: 9.5, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Cindy.red))
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [Color.black, Cindy.ink.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    // ghost bar drains later than the real one, like fighting games
                    Capsule().fill(Cindy.paper.opacity(0.85))
                        .frame(width: w * ratio)
                        .animation(.easeOut(duration: 0.8).delay(0.45), value: hp)
                    Capsule()
                        .fill(LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom))
                        .overlay(Hatching().opacity(0.18))
                        .clipShape(Capsule())
                        .frame(width: w * ratio)
                        .animation(.easeOut(duration: 0.25), value: hp)
                    ForEach(1..<10, id: \.self) { i in
                        Rectangle().fill(.black.opacity(0.35)).frame(width: 1, height: h).offset(x: w * CGFloat(i) / 10)
                    }
                    // glass highlight
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .frame(height: h * 0.4)
                        .padding(.horizontal, 3)
                        .offset(y: -h * 0.2)
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 26)
                        .offset(x: shine * w)
                    Capsule().fill(.white).opacity(hitFlash ? 0.75 : 0)
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Cindy.rim, lineWidth: 1.2))
                .background {
                    // low-HP heartbeat glow, looped by Core Animation so it costs no CPU
                    if low {
                        LayerLoop(active: true, motion: .pulse(from: 0.15, to: 1), period: 0.55) {
                            Capsule()
                                .stroke(Cindy.red, lineWidth: 4)
                                .blur(radius: 3)
                                .padding(6)
                        }
                        .padding(-6)
                    }
                }
            }
            .frame(height: 11)
            Text("\(hp)")
                .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Cindy.paper)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: hp)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule().fill(Cindy.ink.opacity(0.85)))
        .overlay(Capsule().stroke(Cindy.rim.opacity(0.7), lineWidth: 1))
        .shadow(color: Cindy.blue.opacity(0.4), radius: 4, x: -2)
        .shadow(color: Cindy.red.opacity(0.4), radius: 4, x: 2)
        .offset(x: jolt)
        .onChange(of: hp) { old, new in
            if new < old {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { jolt = 4; hitFlash = true }
                withAnimation(.interpolatingSpring(stiffness: 500, damping: 10)) { jolt = 0 }
                withAnimation(.easeOut(duration: 0.25)) { hitFlash = false }
            } else if new > old {
                shine = -0.3
                withAnimation(.easeInOut(duration: 0.7)) { shine = 1.1 }
            }
        }
    }
}

/// Diagonal pencil hatching, a nod to the cross-hatched shading in the Cindy art.
private struct Hatching: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3.5
            }
            context.stroke(path, with: .color(.white), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// Dark speech bubble with a blue→red rim light; the tail is part of the outline.
struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Cindy.paper)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.top, 8)
            .padding(.bottom, 8 + BubbleShape.tail)
            .background(BubbleShape().fill(Cindy.ink.opacity(0.92)))
            .overlay(BubbleShape().stroke(Cindy.rim, lineWidth: 1.3))
            .shadow(color: Cindy.blue.opacity(0.45), radius: 5, x: -2)
            .shadow(color: Cindy.red.opacity(0.45), radius: 5, x: 2)
            .frame(maxWidth: 230)
            .padding(.bottom, 2)
    }
}

private struct BubbleShape: Shape {
    static let tail: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 11, t = Self.tail, w: CGFloat = 7
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - t)
        return Path { p in
            p.move(to: CGPoint(x: body.minX + r, y: body.minY))
            p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: body.midX + w, y: body.maxY))
            p.addLine(to: CGPoint(x: body.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: body.midX - w, y: body.maxY))
            p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        }
    }
}

