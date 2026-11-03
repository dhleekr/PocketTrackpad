import SwiftUI
import Speech
import AVFoundation

@MainActor final class SpeechInput:ObservableObject {
    @Published var text=""
    @Published var recording=false
    @Published var preparing=false
    @Published var finishing=false
    @Published var error:String?
    @Published var locale=UserDefaults.standard.string(forKey:"pad.dictation.locale") ?? (Locale.current.language.languageCode?.identifier=="ko" ? "ko-KR":"en-US") {
        didSet{UserDefaults.standard.set(locale,forKey:"pad.dictation.locale")}
    }
    private var engine:AVAudioEngine?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var task:SFSpeechRecognitionTask?
    private var generation=UUID()
    private var limit:Task<Void,Never>?
    private var finalize:Task<Void,Never>?
    func start() async {
        guard !preparing,!recording,!finishing else{return}
        cancel();let id=generation;preparing=true;error=nil
        let authorization=await withCheckedContinuation{continuation in
            SFSpeechRecognizer.requestAuthorization{continuation.resume(returning:$0)}
        }
        guard generation==id else{return}
        guard authorization == .authorized else{preparing=false;error=PTText("Allow Speech Recognition in iPhone Settings to dictate.");return}
        let allowed=await AVAudioApplication.requestRecordPermission()
        guard generation==id else{return}
        guard allowed else{preparing=false;error=PTText("Allow Microphone in iPhone Settings to dictate.");return}
        guard let recognizer=SFSpeechRecognizer(locale:Locale(identifier:locale)),recognizer.supportsOnDeviceRecognition,recognizer.isAvailable else{
            preparing=false;error=PTText("On-device speech recognition is unavailable for this language. Check Siri & Dictation language downloads in iPhone Settings.");return
        }
        do {
            let session=AVAudioSession.sharedInstance()
            try session.setCategory(.record,mode:.measurement,options:.duckOthers)
            try session.setActive(true,options:.notifyOthersOnDeactivation)
            let engine=AVAudioEngine(),request=SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition=true;request.shouldReportPartialResults=true;request.addsPunctuation=true
            let input=engine.inputNode,format=input.outputFormat(forBus:0)
            guard format.sampleRate>0,format.channelCount>0 else{throw NSError(domain:"SpeechInput",code:1)}
            input.installTap(onBus:0,bufferSize:1024,format:format){buffer,_ in request.append(buffer)}
            self.engine=engine;self.request=request;text=""
            task=recognizer.recognitionTask(with:request){[weak self] result,failure in
                let transcript=result?.bestTranscription.formattedString,isFinal=result?.isFinal ?? false
                Task{@MainActor in
                    guard let self,self.generation==id else{return}
                    if let transcript{self.text=transcript}
                    if isFinal || failure != nil {
                        self.cancel()
                        if failure != nil && self.text.isEmpty{self.error=PTText("Speech recognition stopped. Try again or edit the text.")}
                    }
                }
            }
            engine.prepare();try engine.start();recording=true;preparing=false
            limit=Task{[weak self] in try? await Task.sleep(for:.seconds(60));guard !Task.isCancelled else{return};self?.stop()}
        }catch{cancel();self.error=PTText("Could not start the microphone. Check permissions and try again.")}
    }
    func stop() {
        guard recording else{return}
        recording=false;finishing=true;limit?.cancel();limit=nil
        releaseAudio();request?.endAudio()
        let id=generation
        finalize=Task{[weak self] in
            try? await Task.sleep(for:.seconds(4));guard !Task.isCancelled,let self,self.generation==id else{return};self.cancel()
        }
    }
    private func releaseAudio(){
        if let engine{engine.stop();engine.inputNode.removeTap(onBus:0)};engine=nil
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    func cancel(){
        generation=UUID();preparing=false;recording=false;finishing=false
        limit?.cancel();limit=nil;finalize?.cancel();finalize=nil
        releaseAudio();request?.endAudio();task?.cancel();request=nil;task=nil
    }
}

struct DictationSheet:View {
    @ObservedObject var client:TrackpadClient
    @StateObject private var speech=SpeechInput()
    @State private var sending=false
    @State private var result:String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var editing=false
    @State private var detent:PresentationDetent = .medium
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {
                    Picker(PTText("Language"),selection:$speech.locale){Text("한국어").tag("ko-KR");Text("English").tag("en-US")}
                        .pickerStyle(.segmented).disabled(busy || sending)
                    Button {
                        result=nil
                        if speech.recording{speech.stop()}else{Task{await speech.start()}}
                    } label:{
                        Image(systemName:speech.recording ? "stop.fill":"mic.fill")
                            .font(.system(size:30,weight:.medium)).frame(width:80,height:80)
                            .background(speech.recording ? Color.red:Color(red:0.79,green:0.96,blue:0.36),in:Circle()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(PTText(speech.recording ? "Stop recording":"Start recording"))
                        .disabled(speech.preparing || speech.finishing || sending || !client.ready || !client.extendedInput)
                    if speech.preparing || speech.finishing {ProgressView(PTText(speech.preparing ? "Preparing microphone…":"Finishing recognition…"))}
                    else {Text(PTText(speech.recording ? "Listening…":"Tap to speak. Tap again to stop.")).font(.subheadline).foregroundStyle(.secondary)}
                    if let error=speech.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                        Link(PTText("Open iPhone Settings"),destination:URL(string:UIApplication.openSettingsURLString)!)
                    }
                    if !speech.text.isEmpty {
                        Text(speech.text).frame(maxWidth:.infinity,alignment:.leading).lineLimit(3).accessibilityLabel(PTText("Text to enter"))
                        DisclosureGroup(PTText("Edit text"),isExpanded:$editing){
                            TextEditor(text:$speech.text).frame(minHeight:120).accessibilityLabel(PTText("Text to enter"))
                                .disabled(busy || sending)
                        }.font(.subheadline)
                    }
                    Button {
                        sending=true;result=nil
                        client.sendText(speech.text){ok in
                            sending=false
                            if ok{speech.text="";editing=false;result=PTText("Mac received the text.")}
                            else{result=PTText("Delivery was not confirmed. Check the Mac before sending again.")}
                        }
                    } label:{Label(PTText("Insert text"),systemImage:"arrow.up.right").frame(maxWidth:.infinity,minHeight:44)}
                        .buttonStyle(.borderedProminent).disabled(!canSend)
                    if sending{ProgressView(PTText("Sending…"))}
                    if let result{Text(result).font(.footnote).accessibilityAddTraits(.updatesFrequently)}
                    if !speech.text.isEmpty && !PadTextInput.valid(speech.text){Text(PTText("Text is too long. Shorten it before sending.")).font(.footnote).foregroundStyle(.red)}
                    Text(PTText("Click the Mac input first. Insert text here, then use Enter on the trackpad to send.")).font(.footnote).foregroundStyle(.secondary)
                    if !client.ready{Text(PTText("Connect your Mac before using dictation.")).font(.footnote)}
                    else if !client.extendedInput{Text(PTText("Update the Mac app to use these features.")).font(.footnote)}
                    Text(PTText("Recognized on this iPhone. No audio is saved. Up to 60 seconds.")).font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle(PTText("Dictation")).navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.topBarTrailing){Button(PTText("Done")){speech.cancel();dismiss()}.disabled(sending)}}
        }
        .onDisappear{speech.cancel()}
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification)){_ in speech.cancel()}
        .onChange(of:phase){_,value in if value == .background || (value == .inactive && (speech.recording || speech.finishing)){speech.cancel()}}
        .onChange(of:client.ready){_,ready in if !ready{speech.cancel()}}
        .onChange(of:editing){_,value in if value{detent = .large}}
        .presentationDetents([.medium,.large],selection:$detent).preferredColorScheme(.dark)
    }
    private var busy:Bool {speech.recording || speech.preparing || speech.finishing}
    private var canSend:Bool {client.ready && client.extendedInput && !sending && !speech.recording && !speech.preparing && !speech.finishing && PadTextInput.valid(speech.text) && !speech.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
}
