import Foundation

enum HostTransport:CaseIterable {case wifi, bluetooth}

/// Keeps an idle transport from replacing another transport's live session.
struct HostConnectionState {
    private var messages=[HostTransport:String]()
    private var latencies=[HostTransport:(value:Double,time:Double)]()
    private(set) var message="Waiting for iPhone"
    var connected:Bool {HostTransport.allCases.contains{isConnected(messages[$0])}}

    mutating func update(_ text:String,from transport:HostTransport) {
        messages[transport]=text
        if !isConnected(text){latencies[transport]=nil}
        if let active=HostTransport.allCases.compactMap({messages[$0]}).first(where:isConnected) {
            message=active
        } else {
            message=text
        }
    }

    mutating func updateLatency(_ value:Double,from transport:HostTransport,at now:Double) {
        guard value.isFinite,value>0,value<=60000,now.isFinite else{return}
        latencies[transport]=(value,now)
    }
    func roundTripMS(at now:Double)->Int? {
        guard let channel=HostTransport.allCases.first(where:{isConnected(messages[$0])}),
              let sample=latencies[channel],now.isFinite,now>=sample.time,now-sample.time<=3 else{return nil}
        return Int(sample.value.rounded())
    }
    private func isConnected(_ text:String?)->Bool {
        text == "Wi-Fi connected" || text == "Bluetooth connected"
    }
}
