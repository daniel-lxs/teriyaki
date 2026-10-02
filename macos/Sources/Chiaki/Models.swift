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
    var registKey: String
    var address: String?
    var status: ConsoleStatus = .offline
    var runningApp: String?
    var lastSeen: Date?

    var modelName: String { isPS5 ? "PlayStation 5" : "PlayStation 4" }
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
