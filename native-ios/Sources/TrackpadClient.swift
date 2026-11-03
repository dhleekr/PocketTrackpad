import Foundation
import Combine
import CoreBluetooth
import UIKit

@MainActor final class TrackpadClient:ObservableObject {
    enum Transport:String,CaseIterable {case wifi="Wi-Fi",bluetooth="Bluetooth"}
    @Published var transport:Transport = .wifi
    let diagnostics=PadDiagnostics()
    @Published var protected=false
    func toggleProtection(){releaseInput();protected.toggle()}
    @Published var landscape=false
    func toggleOrientation(){
        releaseInput()
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first(where:{$0.activationState == .foregroundActive}) else{return}
        // UIInterfaceOrientation landscapeRight places the front camera/notch on the left.
        let target:UIInterfaceOrientationMask=scene.interfaceOrientation.isLandscape ? .portrait:.landscapeRight
        PadOrientationDelegate.mask=target
        scene.windows.first(where:{$0.isKeyWindow})?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:target)){[weak self] error in
            Task{@MainActor in
                self?.landscape=scene.interfaceOrientation.isLandscape
                self?.message=PTFormat("Unable to change screen orientation: %@",error.localizedDescription)
            }
        }
        // Restore automatic rotation without forcing an immediate return to portrait.
        // The next physical orientation change uses the full supported mask.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.8){PadOrientationDelegate.mask = .allButUpsideDown}
    }
    @Published var ready=false
    @Published var message=PTText("Mac QR로 연결하세요.")
    @Published var latencyMS=0
    @Published var showDictation=false
    @Published var showConnection=true
    @Published var pressureAvailable=false
    @Published var sensitivity=1.6 {didSet{UserDefaults.standard.set(sensitivity,forKey:"pad.sensitivity")}}
    @Published var doubleTapInterval=0.5 {didSet{UserDefaults.standard.set(doubleTapInterval,forKey:"pad.doubleTapInterval")}}
    @Published var pressDelay=0.16 {didSet{UserDefaults.standard.set(pressDelay,forKey:"pad.pressDelay")}}
    @Published var hapticTap=UserDefaults.standard.object(forKey:"pad.haptic.tap") as? Bool ?? true {didSet{UserDefaults.standard.set(hapticTap,forKey:"pad.haptic.tap")}}
    @Published var hapticPress=UserDefaults.standard.object(forKey:"pad.haptic.press") as? Bool ?? true {didSet{UserDefaults.standard.set(hapticPress,forKey:"pad.haptic.press")}}
    @Published var hapticGesture=UserDefaults.standard.object(forKey:"pad.haptic.gesture") as? Bool ?? true {didSet{UserDefaults.standard.set(hapticGesture,forKey:"pad.haptic.gesture")}}
    @Published var hapticRelease=UserDefaults.standard.object(forKey:"pad.haptic.release") as? Bool ?? true {didSet{UserDefaults.standard.set(hapticRelease,forKey:"pad.haptic.release")}}
    func allowsHaptic(_ kind:PadHapticKind)->Bool {
        switch kind {case .tap:return hapticTap;case .press:return hapticPress;case .release:return hapticRelease;case .gesture:return hapticGesture}
    }
    @Published var hapticStrength=PadTuning.saved("pad.hapticStrength",default:0.75,range:0...1) {didSet{UserDefaults.standard.set(hapticStrength,forKey:"pad.hapticStrength")}}
    @Published var pressClick=UserDefaults.standard.object(forKey:"pad.pressClick") as? Bool ?? true {didSet{UserDefaults.standard.set(pressClick,forKey:"pad.pressClick")}}
    @Published var naturalScroll=UserDefaults.standard.object(forKey:"pad.naturalScroll") as? Bool ?? true {didSet{UserDefaults.standard.set(naturalScroll,forKey:"pad.naturalScroll")}}
    private var wifi=WiFiClient()
    private var reverse=BLEPeripheralClient()
    private var subscriptions=Set<AnyCancellable>()
    init(){
        wifi.onTextAck={[weak self] id,ok in self?.finishText(id:id,ok:ok)}
        reverse.onTextAck={[weak self] id,ok in self?.finishText(id:id,ok:ok)}
        wifi.diagnostics=diagnostics;reverse.diagnostics=diagnostics
        doubleTapInterval=PadTuning.saved("pad.doubleTapInterval",default:0.5,range:PadTuning.doubleTapRange)
        sensitivity=PadTuning.saved("pad.sensitivity",default:1.6,range:PadTuning.speedRange)
        pressDelay=PadTuning.saved("pad.pressDelay",default:0.16,range:PadTuning.pressRange)
        wifi.$ready.removeDuplicates().sink{[weak self] v in guard let self,self.transport == .wifi else{return};self.updateReady(v)}.store(in:&subscriptions)
        wifi.$message.throttle(for:.milliseconds(200),scheduler:RunLoop.main,latest:true).sink{[weak self] v in guard let self,self.transport == .wifi else{return};self.message=v}.store(in:&subscriptions)
        wifi.$latencyMS.throttle(for:.milliseconds(200),scheduler:RunLoop.main,latest:true).sink{[weak self] v in if self?.transport == .wifi {self?.latencyMS=v}}.store(in:&subscriptions)
        reverse.$ready.removeDuplicates().sink{[weak self] v in guard let self,self.transport == .bluetooth else{return};self.updateReady(v)}.store(in:&subscriptions)
        reverse.$message.throttle(for:.milliseconds(200),scheduler:RunLoop.main,latest:true).sink{[weak self] v in guard let self,self.transport == .bluetooth else{return};self.message=v}.store(in:&subscriptions)
        reverse.$latencyMS.throttle(for:.milliseconds(200),scheduler:RunLoop.main,latest:true).sink{[weak self] v in if self?.transport == .bluetooth {self?.latencyMS=v}}.store(in:&subscriptions)
    }
    private func updateReady(_ value:Bool){ready=value;if !value {if let id=textID{finishText(id:id,ok:false)};showConnection=true}}
    func start(){resumeConnection()}
    func resumeConnection(){
        if transport == .wifi {wifi.start();updateReady(wifi.ready)}
        else {reverse.start(token:pairingToken);updateReady(reverse.ready)}
    }
    func releaseInput(){send([PadEvent(type:"up")])}
    private var pairingToken:String? {guard let address=wifi.pairingAddress else{return nil};return (try? PairingEndpoint(address))?.token}
    func selectTransport(){
        if let id=textID{finishText(id:id,ok:false)}
        if transport == .wifi {reverse.pause();ready=false;message=PTText("Wi-Fi 연결 중…");wifi.reconnect()}
        else {wifi.pause();ready=false;reverse.start(token:pairingToken);message=reverse.message}
        showConnection=true
    }
    func pair(_ address:String){
        guard (try? PairingEndpoint(address)) != nil else {message=PTText("Mac 앱의 전체 QR 또는 연결 주소를 사용하세요.");return}
        wifi.pair(address,connectNow:transport == .wifi)
        if transport == .bluetooth {reverse.reconnect(token:pairingToken)}
    }
    func forgetMac(){reverse.pause();wifi.forgetPairing();ready=false;showConnection=true;message=PTText("Mac QR로 연결하세요.")}
    func reconnect(){if transport == .wifi {wifi.reconnect()}else {reverse.reconnect(token:pairingToken)}}
    var extendedInput:Bool {transport == .wifi ? wifi.extendedInput:reverse.extendedInput}
    private var textID:String?
    private var textCompletion:((Bool)->Void)?
    func sendText(_ text:String,completion:@escaping (Bool)->Void) {
        guard ready,extendedInput,textID==nil,PadTextInput.valid(text) else{completion(false);return}
        let id=UUID().uuidString;textID=id;textCompletion=completion
        send([PadEvent(type:"text",name:id,text:text)])
        DispatchQueue.main.asyncAfter(deadline:.now()+10){[weak self] in
            guard let self,self.textID==id else{return}
            // Do not retry text automatically: an acknowledgment can be lost after delivery.
            self.finishText(id:id,ok:false);self.pause()
        }
    }
    private func finishText(id:String,ok:Bool){
        guard textID==id else{return};let completion=textCompletion;textID=nil;textCompletion=nil;completion?(ok)
    }
    func send(_ events:[PadEvent]){
        if events.contains(where:{$0.type=="text" || ($0.type=="shortcut" && (["notifications","apps"].contains($0.name ?? "") || PadQuickKey(rawValue:$0.name ?? "") != nil))}) && !extendedInput {
            message=PTText("Update the Mac app to use these features.");showConnection=true;return
        }
        if transport == .wifi {wifi.send(events)}else {reverse.send(events)}}
    func pause(){if let id=textID{finishText(id:id,ok:false)};if transport == .wifi {wifi.pause()}else {reverse.pause()};ready=false}
}
