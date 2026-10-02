import Foundation

/// PlayStation device discovery and wake-up over UDP on the local network.
final class Discovery {
    struct Reply {
        var address: String
        var status: ConsoleStatus
        var hostID: String
        var name: String
        var isPS5: Bool
        var systemVersion: String
        var runningApp: String?
    }

    var onReply: ((Reply) -> Void)?

    private let fd: Int32
    private let queue = DispatchQueue(label: "discovery")
    private var source: DispatchSourceRead?

    private static let ps5 = (port: UInt16(9302), version: "00030010")
    private static let ps4 = (port: UInt16(987), version: "00020020")

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
        close(fd)
    }

    func search(knownAddresses: [String]) {
        let targets = Set(Self.broadcastAddresses() + knownAddresses)
        queue.async { [self] in
            for address in targets {
                for kind in [Self.ps5, Self.ps4] {
                    send("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(kind.version)\n", to: address, port: kind.port)
                }
            }
        }
    }

    func wake(address: String, credential: UInt64, isPS5: Bool) {
        let kind = isPS5 ? Self.ps5 : Self.ps4
        let message = "WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\n"
            + "user-credential:\(credential)\ndevice-discovery-protocol-version:\(kind.version)\n"
        queue.async { [self] in send(message, to: address, port: kind.port) }
    }

    private func send(_ message: String, to address: String, port: UInt16) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return }
        let bytes = Array(message.utf8)
        withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            if let reply = Self.parse(String(decoding: buffer[0..<count], as: UTF8.self), from: String(cString: text)) {
                onReply?(reply)
            }
        }
    }

    static func parse(_ response: String, from address: String) -> Reply? {
        let lines = response.split(whereSeparator: \.isNewline)
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 ") else { return nil }
        let code = first.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        guard let hostID = headers["host-id"], code == 200 || code == 620 else { return nil }
        return Reply(
            address: address,
            status: code == 200 ? .ready : .standby,
            hostID: hostID.uppercased(),
            name: headers["host-name"] ?? "PlayStation",
            isPS5: headers["host-type"] == "PS5",
            systemVersion: headers["system-version"] ?? "",
            runningApp: headers["running-app-name"]
        )
    }

    private static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = entry.pointee.ifa_dstaddr else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var ip = $0.pointee.sin_addr
                inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN))
            }
            result.append(String(cString: text))
        }
        return result
    }
}
