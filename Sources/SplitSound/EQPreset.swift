import Foundation

/// A few widely used curves. Coefficients follow Robert Bristow-Johnson's Audio EQ Cookbook.
/// Harman is the published listener-preference bass shelf (Olive, Welti, and Khonsaripour), not a specific headphone.
enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case bass
    case vocal
    case harman
    case treble
    case night
    case podcast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .bass: String(localized: "Bass")
        case .vocal: String(localized: "Vocal")
        case .harman: String(localized: "Harman")
        case .treble: String(localized: "Treble")
        case .night: String(localized: "Night")
        case .podcast: String(localized: "Podcast")
        }
    }

    func filters(sampleRate: Double) -> [Biquad] {
        guard sampleRate > 1000 else { return [] }
        let specs: [EQSpec]
        switch self {
        case .off:
            specs = []
        case .bass:
            specs = [.lowShelf(hz: 90, db: 6, q: 0.71)]
        case .vocal:
            specs = [
                .peak(hz: 300, db: -3, q: 1),
                .peak(hz: 3000, db: 4, q: 1),
            ]
        case .harman:
            specs = [.lowShelf(hz: 105, db: 5.5, q: 0.71)]
        case .treble:
            specs = [.highShelf(hz: 8000, db: 4, q: 0.71)]
        case .night:
            specs = [
                .peak(hz: 3500, db: -3, q: 1),
                .highShelf(hz: 10_000, db: -2, q: 0.71),
            ]
        case .podcast:
            specs = [
                .highPass(hz: 80, q: 0.71),
                .peak(hz: 2500, db: 3, q: 1),
            ]
        }
        return specs.map { $0.biquad(sampleRate: sampleRate) }
    }
}

struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}

struct EQRuntime {
    var left = EQChannel()
    var right = EQChannel()

    mutating func load(_ filters: [Biquad]) {
        left.load(filters)
        right.load(filters)
    }

    mutating func process(left input: Float) -> Float {
        left.process(input)
    }

    mutating func process(right input: Float) -> Float {
        right.process(input)
    }
}

struct EQChannel {
    private var bands = (Biquad(), Biquad(), Biquad(), Biquad())
    private var count = 0

    mutating func load(_ filters: [Biquad]) {
        count = min(4, filters.count)
        if count > 0 { bands.0 = filters[0] }
        if count > 1 { bands.1 = filters[1] }
        if count > 2 { bands.2 = filters[2] }
        if count > 3 { bands.3 = filters[3] }
    }

    mutating func process(_ input: Float) -> Float {
        var sample = input
        if count > 0 { sample = step(&bands.0, sample) }
        if count > 1 { sample = step(&bands.1, sample) }
        if count > 2 { sample = step(&bands.2, sample) }
        if count > 3 { sample = step(&bands.3, sample) }
        return sample
    }

    private func step(_ band: inout Biquad, _ sample: Float) -> Float {
        band.process(sample)
    }
}

private enum EQSpec {
    case lowShelf(hz: Double, db: Double, q: Double)
    case highShelf(hz: Double, db: Double, q: Double)
    case peak(hz: Double, db: Double, q: Double)
    case highPass(hz: Double, q: Double)

    func biquad(sampleRate: Double) -> Biquad {
        switch self {
        case .lowShelf(let hz, let db, let q):
            return shelf(sampleRate: sampleRate, hz: hz, db: db, q: q, high: false)
        case .highShelf(let hz, let db, let q):
            return shelf(sampleRate: sampleRate, hz: hz, db: db, q: q, high: true)
        case .peak(let hz, let db, let q):
            return makePeak(sampleRate: sampleRate, hz: hz, db: db, q: q)
        case .highPass(let hz, let q):
            return makeHighPass(sampleRate: sampleRate, hz: hz, q: q)
        }
    }
}

private func shelf(sampleRate: Double, hz: Double, db: Double, q: Double, high: Bool) -> Biquad {
    let a = pow(10, db / 40)
    let w = 2 * Double.pi * hz / sampleRate
    let cosw = cos(w)
    let alpha = sin(w) / (2 * q)
    let twoSqrt = 2 * sqrt(a) * alpha
    let aPlus = a + 1
    let aMinus = a - 1
    let b0: Double
    let b1: Double
    let b2: Double
    let a0: Double
    let a1: Double
    let a2: Double
    if high {
        b0 = a * (aPlus + aMinus * cosw + twoSqrt)
        b1 = -2 * a * (aMinus + aPlus * cosw)
        b2 = a * (aPlus + aMinus * cosw - twoSqrt)
        a0 = aPlus - aMinus * cosw + twoSqrt
        a1 = 2 * (aMinus - aPlus * cosw)
        a2 = aPlus - aMinus * cosw - twoSqrt
    } else {
        b0 = a * (aPlus - aMinus * cosw + twoSqrt)
        b1 = 2 * a * (aMinus - aPlus * cosw)
        b2 = a * (aPlus - aMinus * cosw - twoSqrt)
        a0 = aPlus + aMinus * cosw + twoSqrt
        a1 = -2 * (aMinus + aPlus * cosw)
        a2 = aPlus + aMinus * cosw - twoSqrt
    }
    return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
}

private func makePeak(sampleRate: Double, hz: Double, db: Double, q: Double) -> Biquad {
    let a = pow(10, db / 40)
    let w = 2 * Double.pi * hz / sampleRate
    let cosw = cos(w)
    let alpha = sin(w) / (2 * q)
    return normalized(
        b0: 1 + alpha * a,
        b1: -2 * cosw,
        b2: 1 - alpha * a,
        a0: 1 + alpha / a,
        a1: -2 * cosw,
        a2: 1 - alpha / a
    )
}

private func makeHighPass(sampleRate: Double, hz: Double, q: Double) -> Biquad {
    let w = 2 * Double.pi * hz / sampleRate
    let cosw = cos(w)
    let alpha = sin(w) / (2 * q)
    let b0 = (1 + cosw) / 2
    return normalized(
        b0: b0,
        b1: -(1 + cosw),
        b2: b0,
        a0: 1 + alpha,
        a1: -2 * cosw,
        a2: 1 - alpha
    )
}

private func normalized(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
    Biquad(
        b0: Float(b0 / a0),
        b1: Float(b1 / a0),
        b2: Float(b2 / a0),
        a1: Float(a1 / a0),
        a2: Float(a2 / a0)
    )
}
