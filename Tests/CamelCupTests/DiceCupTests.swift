import Foundation
import Testing

@testable import CamelCup

@Suite("Camel Cup dice")
struct DiceCupTests {

    @Test("A fresh cup holds one die per colour")
    func fullCup() {
        let cup = DiceCup()
        #expect(cup.remainingCount == 5)
        #expect(Set(cup.remaining) == Set(CamelColor.allCases))
        #expect(!cup.isEmpty)
        #expect(cup.used.isEmpty)
    }

    @Test("Every roll shows 1, 2, or 3")
    func facesInRange() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            var cup = DiceCup()
            for roll in cup.rollAll(using: &generator) {
                #expect(DiceCup.faces.contains(roll.pips))
            }
        }
    }

    @Test("A rolled colour leaves the cup and does not come back")
    func coloursAreConsumed() {
        var generator = SeededGenerator(seed: 1)
        var cup = DiceCup()
        var seen: [CamelColor] = []

        while let roll = cup.roll(using: &generator) {
            #expect(!seen.contains(roll.color), "\(roll.color) came out twice")
            seen.append(roll.color)
            #expect(!cup.remaining.contains(roll.color))
            #expect(cup.used.contains(roll.color))
        }

        #expect(seen.count == 5)
        #expect(Set(seen) == Set(CamelColor.allCases))
    }

    @Test("The cup empties after exactly five rolls and then returns nil")
    func emptiesAfterFive() {
        var generator = SeededGenerator(seed: 99)
        var cup = DiceCup()

        for expected in stride(from: 4, through: 0, by: -1) {
            #expect(cup.roll(using: &generator) != nil)
            #expect(cup.remainingCount == expected)
        }

        #expect(cup.isEmpty)
        #expect(cup.roll(using: &generator) == nil)
        #expect(cup.roll(using: &generator) == nil)
    }

    @Test("Refilling starts the next leg with all five dice")
    func refill() {
        var generator = SeededGenerator(seed: 3)
        var cup = DiceCup()
        _ = cup.rollAll(using: &generator)
        #expect(cup.isEmpty)

        cup.refill()

        #expect(cup.remainingCount == 5)
        #expect(Set(cup.remaining) == Set(CamelColor.allCases))
        #expect(cup.used.isEmpty)
        #expect(cup.rollAll(using: &generator).count == 5)
    }

    @Test("Refilling mid-leg puts the used dice back too")
    func refillMidLeg() {
        var generator = SeededGenerator(seed: 11)
        var cup = DiceCup()
        _ = cup.roll(using: &generator)
        _ = cup.roll(using: &generator)
        #expect(cup.remainingCount == 3)

        cup.refill()
        #expect(cup.remainingCount == 5)
    }

    @Test("A leg is five rolls, one per colour, in some order")
    func rollAllIsOneLeg() {
        var generator = SeededGenerator(seed: 2024)
        var cup = DiceCup()
        let leg = cup.rollAll(using: &generator)

        #expect(leg.count == 5)
        #expect(Set(leg.map(\.color)) == Set(CamelColor.allCases))
        #expect(cup.isEmpty)
    }

    @Test("A resumed cup holds only what is left, duplicates dropped")
    func resumedCup() {
        let cup = DiceCup(remaining: [.blue, .green, .blue])
        #expect(cup.remaining == [.blue, .green])
        #expect(Set(cup.used) == Set([.yellow, .orange, .white]))
    }

    @Test("The same seed replays the same leg, a different one does not")
    func seedIsDeterministic() {
        func leg(seed: UInt64) -> [DiceRoll] {
            var generator = SeededGenerator(seed: seed)
            var cup = DiceCup()
            return cup.rollAll(using: &generator)
        }

        #expect(leg(seed: 42) == leg(seed: 42))
        #expect(leg(seed: 42) != leg(seed: 43))
    }

    @Test("Colours and faces are both spread over many legs")
    func distribution() {
        var generator = SeededGenerator(seed: 5)
        var firstOut: [CamelColor: Int] = [:]
        var pipCounts: [Int: Int] = [:]
        let legs = 3000

        for _ in 0..<legs {
            var cup = DiceCup()
            let leg = cup.rollAll(using: &generator)
            firstOut[leg[0].color, default: 0] += 1
            for roll in leg { pipCounts[roll.pips, default: 0] += 1 }
        }

        // Each colour is first out about a fifth of the time, each face about a
        // third of the 5 × legs rolls. Wide bounds: this catches a stuck index
        // or an off-by-one range, not a subtly biased generator.
        for color in CamelColor.allCases {
            let share = Double(firstOut[color] ?? 0) / Double(legs)
            #expect(share > 0.15 && share < 0.25, "\(color) came out first \(share) of the time")
        }
        for face in DiceCup.faces {
            let share = Double(pipCounts[face] ?? 0) / Double(legs * 5)
            #expect(share > 0.28 && share < 0.39, "face \(face) came up \(share) of the time")
        }
    }

    @Test("German colour names match the board")
    func germanNames() {
        #expect(CamelColor.yellow.german == "gelb")
        #expect(CamelColor.orange.german == "orange")
        #expect(CamelColor.white.german == "weiß")
        #expect(CamelColor.green.german == "grün")
        #expect(CamelColor.blue.german == "blau")
    }
}
