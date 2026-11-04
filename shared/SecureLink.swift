import Foundation
import Network
import Security

@MainActor enum MicrophoneStopPriority {
    static func send(sender:Task<Void,Never>?,command:()async throws->Void)async throws {
        sender?.cancel()
        try await command()
    }
}

// Native TLS transport. The QR secret authenticates both ends before any input is accepted.
enum PadSecureLink {
    static let maxFrame=16384
    static func parameters(token:String)->NWParameters {
        let tls=NWProtocolTLS.Options(),tcp=NWProtocolTCP.Options();tcp.noDelay=true
        let options=tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options,.TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options,.TLSv12)
        // The legacy PSK suite is not exposed by the newer typed cipher enum.
        sec_protocol_options_add_tls_ciphersuite(options,SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
        let key=Data(token.utf8),identity=Data("PocketTrackpad-v1".utf8)
        key.withUnsafeBytes { keyBytes in identity.withUnsafeBytes { identityBytes in
            sec_protocol_options_add_pre_shared_key(options,DispatchData(bytes:keyBytes) as __DispatchData,DispatchData(bytes:identityBytes) as __DispatchData)
        }}
        sec_protocol_options_set_tls_resumption_enabled(options,false)
        let parameters=NWParameters(tls:tls,tcp:tcp);parameters.serviceClass = .responsiveData
        return parameters
    }
    static func frame(_ data:Data) throws->Data {
        guard !data.isEmpty,data.count<=maxFrame else{throw Failure.invalidFrame}
        let count=UInt32(data.count)
        return Data([UInt8(count>>24),UInt8((count>>16)&255),UInt8((count>>8)&255),UInt8(count&255)])+data
    }
    enum Failure:Error {case invalidFrame,closed,timeout}
}
struct PadFrameDecoder {
    private var bytes=Data()
    mutating func append(_ incoming:Data)throws->[Data]{
        guard bytes.count+incoming.count<=PadSecureLink.maxFrame*2+8 else{throw PadSecureLink.Failure.invalidFrame}
        bytes.append(incoming);var frames=[Data]()
        while bytes.count>=4 {
            let length=bytes.prefix(4).reduce(0){($0<<8)|Int($1)}
            guard (1...PadSecureLink.maxFrame).contains(length) else{throw PadSecureLink.Failure.invalidFrame}
            guard bytes.count>=length+4 else{break}
            frames.append(Data(bytes.dropFirst(4).prefix(length)));bytes.removeFirst(length+4)
        }
        return frames
    }
}

@MainActor final class PadSecureConnection {
    private let connection:NWConnection
    private var decoder=PadFrameDecoder(),pending=[Data]()
    private var connecting:CheckedContinuation<Void,Error>?
    private var timeout:Task<Void,Never>?
    init(host:String,port:Int,token:String){connection=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:UInt16(port))!,using:PadSecureLink.parameters(token:token))}
    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            connecting=continuation
            connection.stateUpdateHandler={[weak self] state in Task{@MainActor in
                guard let self else{return}
                switch state {
                case .ready:self.finish(nil)
                case .failed(let error):self.finish(error)
                case .cancelled:self.finish(PadSecureLink.Failure.closed)
                default:break
                }
            }}
            timeout=Task{[weak self] in
                do{try await Task.sleep(nanoseconds:15_000_000_000)}catch{return}
                self?.finish(PadSecureLink.Failure.timeout);self?.connection.cancel()
            }
            connection.start(queue:DispatchQueue(label:"local.pockettrackpad.secure.client",qos:.userInteractive))
        }
    }
    private func finish(_ error:Error?){guard let continuation=connecting else{return};connecting=nil;timeout?.cancel();timeout=nil;if let error{continuation.resume(throwing:error)}else{continuation.resume()}}
    func send(_ data:Data) async throws {
        let framed=try PadSecureLink.frame(data)
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            connection.send(content:framed,completion:.contentProcessed{error in if let error{continuation.resume(throwing:error)}else{continuation.resume()}})
        }
    }
    func receive() async throws->Data {
        while pending.isEmpty {
            let data:Data=try await withCheckedThrowingContinuation{continuation in
                connection.receive(minimumIncompleteLength:1,maximumLength:PadSecureLink.maxFrame+4){data,_,complete,error in
                    if let error{continuation.resume(throwing:error)}
                    else if let data,!data.isEmpty{continuation.resume(returning:data)}
                    else{continuation.resume(throwing:PadSecureLink.Failure.closed)}
                }
            }
            pending += try decoder.append(data)
        }
        return pending.removeFirst()
    }
    func cancel(){finish(PadSecureLink.Failure.closed);connection.cancel()}
}
