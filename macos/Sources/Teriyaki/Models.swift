import Foundation

enum ConsoleStatus: Equatable {
    case offline
    case standby
    case ready
}

struct Console: Identifiable, Equatable {
    let id: String
    var name: String
    var isPS5: Bool
    var registKey: Data
    var morning: Data
    var address: String?
    var status: ConsoleStatus = .offline
    var runningApp: String?
    var lastSeen: Date?

    var wakeCredential: UInt64? {
        UInt64(String(decoding: registKey.prefix { $0 != 0 }, as: UTF8.self), radix: 16)
    }
}

/// A console seen on the network that is not paired with this Mac yet.
struct DiscoveredConsole: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var address: String
    var isPS5: Bool
    var systemVersion: String
}

struct PairedHost {
    var target: Int
    var name: String
    var mac: Data
    var registKey: Data
    var keyType: Int
    var key: Data
    var accessPointSSID: String
    var accessPointBSSID: String
    var accessPointKey: String
    var accessPointName: String
    var consolePIN: String
}

enum ConsoleActivity: Equatable {
    case idle
    case waking(Console.ID)
    case starting(Console.ID)
    case streaming(Console.ID)

    var consoleID: Console.ID? {
        switch self {
        case .idle: return nil
        case .waking(let id), .starting(let id), .streaming(let id): return id
        }
    }
}
