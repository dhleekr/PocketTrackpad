import Foundation

enum HostTransport:CaseIterable {case wifi, bluetooth}

/// Keeps an idle transport from replacing another transport's live session.
struct HostConnectionState {
    private var messages=[HostTransport:String]()
    private(set) var message="Waiting for iPhone"
    var connected:Bool {HostTransport.allCases.contains{isConnected(messages[$0])}}

    mutating func update(_ text:String,from transport:HostTransport) {
        messages[transport]=text
        if let active=HostTransport.allCases.compactMap({messages[$0]}).first(where:isConnected) {
            message=active
        } else {
            message=text
        }
    }

    private func isConnected(_ text:String?)->Bool {
        text == "Wi-Fi connected" || text == "Bluetooth connected"
    }
}
