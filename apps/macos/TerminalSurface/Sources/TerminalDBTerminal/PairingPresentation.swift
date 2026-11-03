import Foundation

// Presentation generations fence old replies; they never grant device trust.
struct PairingPresentation {
    enum Stage { case opening, browsing, connecting, verifying, waiting, expired, connected }
    private(set) var generation = 0
    private(set) var remoteGeneration: Int?
    var stage: Stage = .opening

    mutating func begin() -> Int {
        generation += 1; remoteGeneration = nil; stage = .opening
        return generation
    }
    mutating func opened(generation: Int, remote: Int?) -> Bool {
        guard generation == self.generation, stage == .opening else { return false }
        remoteGeneration = remote; stage = .browsing; return true
    }
    func accepts(remote: Int?) -> Bool {
        guard stage != .opening else { return false }
        guard let expected = remoteGeneration else { return true }
        guard let remote else { return false }
        return remote == expected
    }
    mutating func cancel() { generation += 1; remoteGeneration = nil; stage = .expired }
    func visibleChoices(_ inventory: [String: Any], allowTestInstances: Bool) -> [[String: Any]] {
        stage == .browsing ? Self.choices(inventory, allowTestInstances: allowTestInstances) : []
    }
    static func selection(in choices: [[String: Any]], previous: String?) -> String? {
        if let previous { return choices.contains(where: { $0["service"] as? String == previous }) ? previous : nil }
        return choices.count == 1 ? choices[0]["service"] as? String : nil
    }

    static func choices(_ inventory: [String: Any], allowTestInstances: Bool) -> [[String: Any]] {
        let own = inventory["fingerprint"] as? String ?? ""
        let known = (inventory["peers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let hidden = ([own] + known).filter { !$0.isEmpty }.map { "tdb-" + $0.prefix(12) }
        var seen = Set<String>()
        return (inventory["nearby"] as? [[String: Any]] ?? []).filter { item in
            guard let service = item["service"] as? String, !service.isEmpty,
                  item["pairingReady"] as? Bool == true,
                  item["local"] as? Bool != true || allowTestInstances,
                  item["testInstance"] as? Bool != true || allowTestInstances,
                  !hidden.contains(where: { service == $0 || service.hasPrefix($0 + " (") }),
                  seen.insert(service).inserted else { return false }
            return true
        }.sorted {
            let left = $0["name"] as? String ?? "Mac", right = $1["name"] as? String ?? "Mac"
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? ($0["service"] as? String ?? "") < ($1["service"] as? String ?? "") : order == .orderedAscending
        }
    }
}

enum PairingPresentationTests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool) throws {
            guard value() else { throw PeerFailure("A pairing presentation regression check failed.") }; count += 1
        }
        var flow = PairingPresentation()
        let old = flow.begin()
        try check(!flow.accepts(remote: 1))
        let current = flow.begin()
        try check(!flow.opened(generation: old, remote: 1))
        try check(flow.stage == .opening)
        try check(flow.opened(generation: current, remote: 2))
        try check(flow.stage == .browsing)
        try check(!flow.accepts(remote: 1))
        try check(!flow.accepts(remote: nil))
        try check(flow.accepts(remote: 2))
        try check(!flow.accepts(remote: 3))
        flow.stage = .expired
        let retry = flow.begin()
        try check(!flow.accepts(remote: 2))
        try check(flow.opened(generation: retry, remote: 3))
        try check(!flow.accepts(remote: 2))
        flow.cancel()
        try check(!flow.opened(generation: retry, remote: 3))
        let legacy = flow.begin()
        try check(flow.opened(generation: legacy, remote: nil))
        try check(flow.accepts(remote: nil))
        let own = String(repeating: "a", count: 64), paired = String(repeating: "b", count: 64)
        let candidates: [[String: Any]] = [
            ["service": "tdb-" + own.prefix(12), "name": "This test Mac", "pairingReady": true],
            ["service": "tdb-" + paired.prefix(12), "name": "Paired test Mac", "pairingReady": true],
            ["service": "closed", "name": "Nearby Mac", "pairingReady": false],
            ["service": "missing", "name": "Not ready"],
            ["service": "first", "name": "Office Mac", "pairingReady": true],
            ["service": "first", "name": "Office Mac", "pairingReady": true],
            ["service": "second", "name": "Office Mac", "pairingReady": true],
            ["service": "qa", "name": "QA Mac", "pairingReady": true, "testInstance": true],
            ["service": "local", "name": "Local Mac", "pairingReady": true, "local": true]
        ]
        let inventory: [String: Any] = ["fingerprint": own, "peers": [["id": paired]], "nearby": candidates]
        let normal = PairingPresentation.choices(inventory, allowTestInstances: false)
        try check(normal.count == 2)
        try check(normal.map { $0["service"] as? String } == ["first", "second"])
        try check(normal.allSatisfy { $0["name"] as? String == "Office Mac" })
        try check(PairingPresentation.choices(inventory, allowTestInstances: true).count == 4)
        try check(PairingPresentation.choices([:], allowTestInstances: false).isEmpty)
        flow.stage = .expired
        try check(flow.visibleChoices(inventory, allowTestInstances: false).isEmpty)
        flow.stage = .opening
        try check(flow.visibleChoices(inventory, allowTestInstances: false).isEmpty)
        flow.stage = .browsing
        try check(flow.visibleChoices(inventory, allowTestInstances: false).count == 2)
        try check(PairingPresentation.selection(in: normal, previous: "second") == "second")
        try check(PairingPresentation.selection(in: [normal[0]], previous: "second") == nil)
        try check(PairingPresentation.selection(in: normal, previous: nil) == nil)
        try check(PairingPresentation.selection(in: [normal[0]], previous: nil) == "first")
        let macs = [(id: "", name: "This Mac"), (id: "first-mac", name: "Office Mac"), (id: "second-mac", name: "Office Mac")]
        let sessions: [String: [[String: Any]]] = ["first-mac": [["sessionId": "persistent-one", "title": "Example", "directory": "/example", "busy": true]]]
        let rows = WorkstationSessionPresentation.rows(macs: macs, sessions: sessions, statuses: [:], filter: "")
        try check(rows.filter { $0.kind == .heading }.count == 3)
        try check(rows.filter { $0.kind == .newTerminal }.count == 3)
        try check(rows.filter { $0.kind == .session }.count == 1)
        try check(rows.filter { $0.kind == .newTerminal }.allSatisfy { $0.session.isEmpty })
        let row = rows.first { $0.kind == .session }!
        try check(row.workstation == "first-mac" && row.session == "persistent-one")
        try check(WorkstationSessionPresentation.selection(in: rows, previous: row.identity, preferredWorkstation: "") == rows.firstIndex(of: row))
        try check(WorkstationSessionPresentation.selection(in: rows.filter { $0.kind != .session }, previous: row.identity, preferredWorkstation: "") == nil)
        let initial = WorkstationSessionPresentation.selection(in: rows, previous: nil, preferredWorkstation: "")!
        try check(rows[initial].kind == .newTerminal && rows[initial].workstation.isEmpty)
        let matching = WorkstationSessionPresentation.rows(macs: macs, sessions: sessions, statuses: [:], filter: "example")
        try check(matching.count == 3 && matching.allSatisfy { $0.workstation == "first-mac" })
        try check(WorkstationSessionPresentation.rows(macs: macs, sessions: sessions, statuses: [:], filter: "not-found").isEmpty)
        let offline = WorkstationSessionPresentation.rows(macs: macs, sessions: [:], statuses: ["second-mac": "Unavailable"], filter: "")
        try check(offline.contains { $0.kind == .newTerminal && $0.workstation == "second-mac" && $0.selectable })
        try check(offline.filter { $0.kind == .status }.allSatisfy { !$0.selectable })
        return count
    }
}
