import Foundation

/// The five racing camels. One die per colour, so the colour is also the die's
/// identity — a cup never holds two of the same.
public enum CamelColor: String, CaseIterable, Hashable, Sendable, Codable {
    case yellow
    case orange
    case white
    case green
    case blue

    /// German names, the way the board prints them.
    public var german: String {
        switch self {
        case .yellow: return "gelb"
        case .orange: return "orange"
        case .white: return "weiß"
        case .green: return "grün"
        case .blue: return "blau"
        }
    }
}

/// One die coming out of the pyramid: which camel moves, and how far.
public struct DiceRoll: Hashable, Sendable, Codable {
    public let color: CamelColor
    /// 1, 2, or 3 — a Camel Cup die has two of each face.
    public let pips: Int

    public init(color: CamelColor, pips: Int) {
        precondition(DiceCup.faces.contains(pips), "a Camel Cup die shows 1...3, got \(pips)")
        self.color = color
        self.pips = pips
    }
}

/// The dice pyramid for one leg.
///
/// Five dice go in, one comes out at a time, and a die that has been rolled does
/// not come back until the cup is refilled — that is the whole reason the game
/// is playable: once four camels have moved you know the fifth is next. So the
/// cup owns *which colours are still inside*, not just a count, and `roll`
/// removes the colour it drew.
///
/// Randomness is injected rather than taken from the global source, so a
/// simulation can be replayed from a seed and the tests can assert on exact
/// sequences.
public struct DiceCup: Sendable {
    /// The faces on a Camel Cup die.
    public static let faces = 1...3

    private var inside: [CamelColor]

    /// A full cup: all five colours, none rolled yet.
    public init() {
        inside = CamelColor.allCases
    }

    /// A partially used cup — for resuming a leg that is already in progress.
    public init(remaining: [CamelColor]) {
        var seen = Set<CamelColor>()
        inside = remaining.filter { seen.insert($0).inserted }
    }

    /// The colours still in the cup, in insertion order. Order carries no game
    /// meaning; `roll` draws uniformly regardless of it.
    public var remaining: [CamelColor] { inside }
    public var remainingCount: Int { inside.count }

    /// True once every die has been rolled — the leg is over and the cup can be
    /// refilled.
    public var isEmpty: Bool { inside.isEmpty }

    /// The colours already rolled this leg.
    public var used: [CamelColor] {
        let left = Set(inside)
        return CamelColor.allCases.filter { !left.contains($0) }
    }

    /// Draws one die, rolls it, and takes it out of the cup.
    ///
    /// Returns `nil` when the cup is empty — that is the signal to refill, not
    /// an error.
    public mutating func roll<G: RandomNumberGenerator>(using generator: inout G) -> DiceRoll? {
        guard !inside.isEmpty else { return nil }
        let index = Int.random(in: 0..<inside.count, using: &generator)
        let color = inside.remove(at: index)
        return DiceRoll(color: color, pips: Int.random(in: Self.faces, using: &generator))
    }

    /// Draws one die using the system random source.
    public mutating func roll() -> DiceRoll? {
        var generator = SystemRandomNumberGenerator()
        return roll(using: &generator)
    }

    /// Rolls out whatever is left, emptying the cup. The order is the order the
    /// camels move in.
    public mutating func rollAll<G: RandomNumberGenerator>(using generator: inout G) -> [DiceRoll] {
        var rolls: [DiceRoll] = []
        rolls.reserveCapacity(inside.count)
        while let roll = roll(using: &generator) { rolls.append(roll) }
        return rolls
    }

    public mutating func rollAll() -> [DiceRoll] {
        var generator = SystemRandomNumberGenerator()
        return rollAll(using: &generator)
    }

    /// Puts all five dice back — the start of the next leg.
    public mutating func refill() {
        inside = CamelColor.allCases
    }
}
