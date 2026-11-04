import Foundation
Task{@MainActor in
    var sent=false
    let blocked=Task{@MainActor in
        while !Task.isCancelled{do{try await Task.sleep(for:.milliseconds(10))}catch{return}}
    }
    let stop=Task{@MainActor in try await MicrophoneStopPriority.send(sender:blocked){sent=true}}
    try? await Task.sleep(for:.milliseconds(80))
    guard sent else{blocked.cancel();stop.cancel();print("FAIL stop command is blocked behind the audio sender");exit(1)}
    guard blocked.isCancelled else{print("FAIL audio sender was not cancelled on stop");exit(1)}
    print("PASS stop bypasses a stalled audio sender and cancels capture delivery")
    exit(0)
}
RunLoop.main.run()
