import CamelCup
import Foundation

// A dice simulator for Camel Cup: five dice, one per camel colour, faces 1...3.
// Roll them one at a time until the cup is empty, then refill for the next leg.
//
//   swift run camelcup              interactive — Enter rolls the next die
//   swift run camelcup --leg        roll one whole leg and exit
//   swift run camelcup --legs 3     roll three legs
//   swift run camelcup --seed 42    reproducible rolls
//
// All state lives inside `run()` — main.swift globals are @MainActor in Swift 6
// and the helpers below are not, which would make sharing them an isolation
// error rather than a convenience.

/// Either source of randomness behind one concrete type: `any
/// RandomNumberGenerator` does not conform to `RandomNumberGenerator`, so it
/// cannot be passed to the generic `roll(using:)`.
struct RunGenerator: RandomNumberGenerator {
    private var seeded: SeededGenerator?
    private var system = SystemRandomNumberGenerator()

    init(seed: UInt64?) {
        seeded = seed.map { SeededGenerator(seed: $0) }
    }

    mutating func next() -> UInt64 {
        guard seeded != nil else { return system.next() }
        return seeded!.next()
    }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func describe(_ roll: DiceRoll) -> String {
    let name = roll.color.german
    let padding = max(0, 8 - name.count)
    return name + String(repeating: " ", count: padding) + String(roll.pips)
}

func prompt(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func run() {
    let usage = """
        camelcup — Camel Cup dice simulator

          camelcup                 interactive: Enter rolls the next die,
                                   "r" refills the cup, "q" quits
          camelcup --leg           roll one full leg (all five dice) and exit
          camelcup --legs <n>      roll n full legs
          camelcup --seed <n>      seed the generator for reproducible rolls
          camelcup --help          this text
        """

    var legs: Int? = nil
    var seed: UInt64? = nil

    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--leg":
            legs = 1
        case "--legs":
            guard let value = arguments.next(), let count = Int(value), count > 0 else {
                die("--legs needs a positive number")
            }
            legs = count
        case "--seed":
            guard let value = arguments.next(), let parsed = UInt64(value) else {
                die("--seed needs a number")
            }
            seed = parsed
        default:
            die("unknown argument: \(argument)\n\n" + usage)
        }
    }

    var generator = RunGenerator(seed: seed)
    var cup = DiceCup()

    if let legs {
        for leg in 1...legs {
            if legs > 1 { print("Etappe \(leg)") }
            for roll in cup.rollAll(using: &generator) { print(describe(roll)) }
            cup.refill()
            if leg < legs { print("") }
        }
        return
    }

    print("Camel Cup — 5 Würfel (gelb, orange, weiß, grün, blau), Augen 1–3.")
    print("Enter würfelt, \"r\" füllt die Pyramide neu, \"q\" beendet.")

    while true {
        prompt("[\(cup.remainingCount) im Becher] > ")
        guard let line = readLine(strippingNewline: true) else {
            print("")
            return
        }
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "q", "quit", "exit":
            return
        case "r", "refill", "neu":
            cup.refill()
            print("Pyramide neu gefüllt: 5 Würfel.")
        default:
            guard let roll = cup.roll(using: &generator) else {
                print("Becher leer — Etappe vorbei. \"r\" füllt neu.")
                continue
            }
            print(describe(roll))
            if cup.isEmpty {
                print("Alle 5 Würfel verbraucht — Etappe vorbei. \"r\" füllt neu.")
            }
        }
    }
}

run()
