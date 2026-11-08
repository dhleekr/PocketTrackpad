import SwiftUI

@main
struct PocketTrackpadApp:App {
    @UIApplicationDelegateAdaptor(PadOrientationDelegate.self) private var appDelegate
    @StateObject var client=TrackpadClient()
    @Environment(\.scenePhase) private var phase
    var body:some Scene {
        WindowGroup {
            PadSurface(client:client).ignoresSafeArea()
            .background(Color(white:0.094)).statusBarHidden()
            .defersSystemGestures(on:client.protected ? .all:[])
            .persistentSystemOverlays(client.protected ? .hidden:.automatic)
            .onAppear {
                client.start()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-pad") {
                    DispatchQueue.main.asyncAfter(deadline:.now()+1){
                        client.showConnection=false

                        if ProcessInfo.processInfo.arguments.contains("--ui-test-landscape") {
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.5){client.toggleOrientation()}
                        }
                    }
                }
                #endif
            }
            .onChange(of:client.ready) { _,ready in UIApplication.shared.isIdleTimerDisabled=ready }
            .onChange(of:phase) { _,value in
                let activity:ConnectionActivity=value == .active ? .active:value == .inactive ? .inactive:.background
                switch ConnectionLifecycle.effect(for:activity) {
                case .resumeExisting: client.resumeConnection();UIApplication.shared.isIdleTimerDisabled=client.ready
                case .releaseOnly: if client.speech.recording || client.speech.finishing{client.speech.cancel()};UIApplication.shared.isIdleTimerDisabled=false;client.releaseInput()
                case .suspend: UIApplication.shared.isIdleTimerDisabled=false;client.pause()
                }
            }
            .sheet(isPresented:$client.showConnection) { SettingsSheet(client:client) }

        }
    }
}

private enum SettingsPage:Hashable {
    case connection,clicks,haptics,gestures,keys,microphone,appearance,about
    #if DEBUG
    case keyActions
    #endif
}
struct SettingsSheet:View {
    @ObservedObject var client:TrackpadClient
    @State private var scanning=false
    @State private var path=[SettingsPage]()
    var body:some View {
        NavigationStack(path:$path) {
            Form {
                Section {
                    HStack(spacing:14) {
                        Image(systemName:"laptopcomputer")
                            .font(.system(size:26,weight:.regular)).foregroundStyle(.tint)
                            .frame(width:44,height:44).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:4) {
                            Text(PTText(client.ready ? "Mac connected":"Connect your Mac")).font(.headline)
                            Text(client.ready ? PTText(client.transport.rawValue):PTText("Open the Mac app, then scan its QR code."))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                        if client.ready {Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)}
                    }.padding(.vertical,8)
                    if !client.ready {
                        VStack(alignment:.leading,spacing:10) {
                            Text(PTText("Install PocketTrackpad on your Mac too.")).font(.subheadline).fontWeight(.medium)
                            Text(PTText("Both apps are required. Install and open the Mac receiver, allow Accessibility access, then scan its QR code here."))
                                .font(.footnote).foregroundStyle(.secondary)
                            Link(destination:URL(string:"https://pocket-trackpad.doohyun726675.chatgpt.site/support.html")!) {
                                Label(PTText("Get the Mac app & setup"),systemImage:"arrow.down.app")
                                    .frame(minHeight:32)
                            }.font(.subheadline)
                        }.padding(.vertical,6)
                    }
                    Picker(PTText("Connection"),selection:$client.transport) {
                        ForEach(TrackpadClient.Transport.allCases,id:\.self) { mode in Text(PTText(mode.rawValue)).tag(mode) }
                    }.pickerStyle(.segmented).padding(.vertical,4)
                    .onChange(of:client.transport) { _,_ in client.selectTransport() }
                    if !client.ready && client.message != PTText("Mac QR로 연결하세요.") {
                        Text(client.message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Button {scanning=true} label:{Label(PTText("Scan Mac QR"),systemImage:"qrcode.viewfinder").frame(minHeight:28)}
                    NavigationLink(value:SettingsPage.connection){Text(PTText("Connection options"))}
                }
                Section {
                    NavigationLink(value:SettingsPage.gestures){Label(PTText("Trackpad gestures"),systemImage:"hand.draw")}
                    NavigationLink(value:SettingsPage.keys){Label(PTText("Quick keys"),systemImage:"keyboard")}
                    NavigationLink(value:SettingsPage.microphone){Label(PTText("Microphone"),systemImage:"mic")}
                    NavigationLink(value:SettingsPage.appearance){Label(PTText("On-screen controls"),systemImage:"slider.horizontal.3")}
                    NavigationLink(value:SettingsPage.haptics){Label(PTText("Haptics"),systemImage:"waveform")}
                }
                Section {
                    NavigationLink(value:SettingsPage.about){Label(PTText("About & support"),systemImage:"info.circle")}
                }
            }
            .navigationTitle(PTText("Trackpad"))
            .toolbar {ToolbarItem(placement:.topBarTrailing){Button(PTText("Done")){client.showConnection=false}.fontWeight(.semibold)}}
            .navigationDestination(for:SettingsPage.self){page in
                switch page {
                case .connection:ConnectionSettings(client:client)
                case .keys:QuickKeySettings(client:client)
                #if DEBUG
                case .keyActions:QuickKeyActionScreen(selected:client.quickKeys[0],title:PTFormat("Key %d",1)){client.quickKeys[0]=$0}
                #endif
                case .microphone:MicrophoneSettings(speech:client.speech)
                case .appearance:ControlVisibilitySettings(client:client)
                case .clicks:ClickSettings(client:client)
                case .haptics:HapticSettings(client:client)
                case .gestures:GestureSettings(client:client)
                case .about:AboutSettings()
                }
            }
            .sheet(isPresented:$scanning) {
                NavigationStack {
                    QRScanner {value in scanning=false;client.pair(value)} failed:{error in scanning=false;client.message=error}
                        .ignoresSafeArea(edges:.bottom).navigationTitle(PTText("Scan Mac QR"))
                        .toolbar {ToolbarItem(placement:.topBarTrailing){Button(PTText("Cancel")){scanning=false}}}
                }
            }
        }.presentationDetents([.large]).statusBarHidden(false)
        .onAppear {
            #if DEBUG
            let arguments=ProcessInfo.processInfo.arguments
            if path.isEmpty,let argument=arguments.first(where:{$0.hasPrefix("--ui-test-page=")}) {
                switch argument.split(separator:"=").last {
                case "keys":path=[.keys]
                case "key-actions":path=[.keys,.keyActions]
                case "microphone":path=[.microphone]
                case "appearance":path=[.appearance]
                case "clicks":path=[.clicks]
                case "haptics":path=[.haptics]
                case "gestures":path=[.gestures]
                case "connection":path=[.connection]
                case "about":path=[.about]
                default:break
                }
            }
            if arguments.contains("--ui-test-settings-landscape") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1.5){client.toggleOrientation()}
            }
            #endif
        }
    }
}

private struct ConnectionSettings:View {
    @ObservedObject var client:TrackpadClient
    @State private var address=""
    @State private var confirmingForget=false
    var body:some View {
        Form {
            Section {
                Button(PTText("Reconnect")){client.reconnect()}
            } footer:{Text(PTText("Wi-Fi uses the same network. Bluetooth works nearby. Scan the Mac QR once for either connection."))}
            Section(PTText("Connect manually")) {
                TextField(PTText("Mac connection address"),text:$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(PTText("Mac connection address"))
                Button(PTText("Connect with address")){client.pair(address)}.disabled(address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            Section {Button(PTText("Forget this Mac"),role:.destructive){confirmingForget=true}}
        }
        .navigationTitle(PTText("Connection options")).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(PTText("Forget this Mac?"),isPresented:$confirmingForget,titleVisibility:.visible){
            Button(PTText("Forget this Mac"),role:.destructive){client.forgetMac()}
        } message:{Text(PTText("This deletes the saved pairing key on this iPhone. Scan the Mac QR to connect again."))}
    }
}

private struct SettingValueHeader:View {
    let title:String
    let valueText:String
    @Environment(\.dynamicTypeSize) private var textSize
    var body:some View {
        if textSize.isAccessibilitySize {
            VStack(alignment:.leading,spacing:6){Text(PTText(title));Text(valueText).foregroundStyle(.secondary).monospacedDigit()}
        } else {
            HStack{Text(PTText(title));Spacer();Text(valueText).foregroundStyle(.secondary).monospacedDigit()}
        }
    }
}
private struct SettingSlider:View {
    let title:String
    let valueText:String
    @Binding var value:Double
    let range:ClosedRange<Double>
    let step:Double
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            SettingValueHeader(title:title,valueText:valueText)
            Slider(value:$value,in:range,step:step).accessibilityLabel(PTText(title)).accessibilityValue(valueText)
        }.padding(.vertical,6)
    }
}
struct ClickSettings:View {
    @ObservedObject var client:TrackpadClient
    var body:some View {
        Form {
            Section {
                SettingSlider(title:"Double-tap interval",valueText:PTFormat("%.2f s",client.doubleTapInterval),value:$client.doubleTapInterval,range:PadTuning.doubleTapRange,step:0.05)
            } footer:{Text(PTText("A longer interval allows more time between taps."))}
            Section {
                Toggle(PTText("Press to click"),isOn:$client.pressClick)
                if client.pressClick {
                    SettingSlider(title:"Press delay",valueText:PTFormat("%.2f s",client.pressDelay),value:$client.pressDelay,range:PadTuning.pressRange,step:0.01)
                }
            } footer:{Text(PTText("Hold one finger to click and drag. Lift to release."))}
            Section {Text(PTText("Tap once to click. Tap twice to double-click. To drag, keep your finger down on the second tap and move.")).foregroundStyle(.secondary)}
        }.navigationTitle(PTText("Click & drag")).navigationBarTitleDisplayMode(.inline)
    }
}
private struct HapticSettings:View {
    @ObservedObject var client:TrackpadClient
    var body:some View {
        Form {
            Section {
                SettingSlider(title:"Haptic strength",valueText:client.hapticStrength==0 ? PTText("Off"):PTFormat("%d%%",Int(client.hapticStrength*100)),value:$client.hapticStrength,range:0...1,step:0.05)
                    .onChange(of:client.hapticStrength){_,value in if value>0{UIImpactFeedbackGenerator(style:.heavy).impactOccurred(intensity:value)}}
            }
            Section(PTText("When to vibrate")) {
                Toggle(PTText("Tap clicks"),isOn:$client.hapticTap)
                Toggle(PTText("Press and drag"),isOn:$client.hapticPress)
                Toggle(PTText("System gestures"),isOn:$client.hapticGesture)
                Toggle(PTText("Release"),isOn:$client.hapticRelease)
            }.disabled(client.hapticStrength==0)
        }.navigationTitle(PTText("Haptics")).navigationBarTitleDisplayMode(.inline)
    }
}
private struct AboutSettings:View {
    var body:some View {
        Form {
            Section {
                LabeledContent("PocketTrackpad",value:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")
                Link(PTText("Get the Mac app"),destination:URL(string:"https://pocket-trackpad.doohyun726675.chatgpt.site/support.html")!)
                Link(PTText("Contact support"),destination:URL(string:"mailto:dhleekr7@gmail.com")!)
                Link(PTText("Privacy policy"),destination:URL(string:"https://pocket-trackpad.doohyun726675.chatgpt.site/privacy.html")!)
            } footer:{Text(PTText("Requires the PocketTrackpad Mac app and Accessibility permission. Your input is sent directly to your Mac."))}
        }.navigationTitle(PTText("About & support")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct QuickKeySettings:View {
    @ObservedObject var client:TrackpadClient
    var body:some View {
        Form {
            Section(PTText("Choose an action for each key")) {
                ForEach(0..<4,id:\.self){index in
                    NavigationLink {
                        QuickKeyActionScreen(selected:client.quickKeys[index],title:PTFormat("Key %d",index+1)){client.quickKeys[index]=$0}
                    } label:{
                        HStack {
                            Text(PTFormat("Key %d",index+1))
                            Spacer()
                            Text(PTText(client.quickKeys[index].accessibilityTitle)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                SettingSlider(title:"Repeat delay",valueText:PTFormat("%.2f s",client.keyRepeatDelay),value:$client.keyRepeatDelay,range:PadKeyRepeatTuning.delayRange,step:0.05)
                    .disabled(client.ready && !client.supportsKeyRepeatTuning)
            } header:{Text(PTText("Key repeat"))} footer:{Text(PTText("A tap sends one key immediately. Repeating starts only after this hold time."))}
            Section {
                SettingSlider(title:"Backspace speed",valueText:PTFormat("%.0f / s",client.backspaceRepeatRate),value:$client.backspaceRepeatRate,range:PadKeyRepeatTuning.rateRange,step:1)
                    .disabled(client.ready && !client.supportsKeyRepeatTuning)
                if client.ready && !client.supportsKeyRepeatTuning{Text(PTText("Update the Mac app to use these features.")).foregroundStyle(.secondary)}
            }
            Section {Button(PTText("Restore default keys")){client.quickKeys=PadQuickKey.defaults}}
        }.navigationTitle(PTText("Quick keys"))
    }
}

/// The action list owns its native scrolling. Live connection/latency updates
/// can update the enclosing settings without rebuilding this table or its menu.
private struct QuickKeyActionScreen:View {
    let selected:PadQuickKey
    let title:String
    let choose:(PadQuickKey)->Void
    var body:some View {
        VStack(spacing:0){QuickKeyActionPicker(selected:selected,title:title,choose:choose)}
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
private struct QuickKeyActionPicker:UIViewControllerRepresentable {
    let selected:PadQuickKey
    let title:String
    let choose:(PadQuickKey)->Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context:Context)->QuickKeyActionController {
        QuickKeyActionController(selected:selected,title:title){key in choose(key);dismiss()}
    }
    func updateUIViewController(_ controller:QuickKeyActionController,context:Context){
        controller.choose={key in choose(key);dismiss()}
        controller.setSelection(selected)
    }
}
private final class QuickKeyActionController:UITableViewController {
    private var selected:PadQuickKey
    var choose:(PadQuickKey)->Void
    init(selected:PadQuickKey,title:String,choose:@escaping(PadQuickKey)->Void){
        self.selected=selected;self.choose=choose;super.init(style:.insetGrouped);self.title=title
    }
    required init?(coder:NSCoder){fatalError("Programmatic controller")}
    override func viewDidLoad(){
        super.viewDidLoad()
        tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=48
        tableView.register(UITableViewCell.self,forCellReuseIdentifier:"action")
        tableView.accessibilityIdentifier="quickKeys.actions"
    }
    func setSelection(_ value:PadQuickKey){
        guard selected != value else{return};selected=value
        for path in tableView.indexPathsForVisibleRows ?? [] {
            tableView.cellForRow(at:path)?.accessoryType=PadQuickKey.groups[path.section].keys[path.row]==selected ? .checkmark:.none
        }
    }
    override func numberOfSections(in tableView:UITableView)->Int {PadQuickKey.groups.count}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {PadQuickKey.groups[section].keys.count}
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {PTText(PadQuickKey.groups[section].title)}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
        let key=PadQuickKey.groups[indexPath.section].keys[indexPath.row]
        let cell=tableView.dequeueReusableCell(withIdentifier:"action",for:indexPath)
        var content=cell.defaultContentConfiguration();content.text=PTText(key.accessibilityTitle)
        cell.contentConfiguration=content;cell.accessoryType=key==selected ? .checkmark:.none
        cell.accessibilityIdentifier="quickKeys.action."+key.rawValue
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath){
        let key=PadQuickKey.groups[indexPath.section].keys[indexPath.row]
        setSelection(key);choose(key)
    }
}

private struct MicrophoneSettings:View {
    @ObservedObject var speech:RemoteMicrophone
    var body:some View {
        Form {
            if let error=speech.error {Section(PTText("Last microphone error")){Text(error).foregroundStyle(.secondary)}}
            Section(PTText("Microphone for your Mac")) {
                Text(PTText("Focus the connected app’s input on your Mac. Tap the iPhone microphone to start, and again to stop. The trackpad stays available."))
            }
            Section(PTText("One-time Mac setup")) {
                Text(PTText("In Mac Settings, install the iPhone microphone once. The standard macOS Installer asks for administrator approval."))
            }
            Section {
                Text(PTText("Audio follows your selected connection: Wi-Fi or Bluetooth. Update both apps to 1.4.6 or later for Bluetooth audio."))
            } header:{Text(PTText("Connection"))} footer:{Text(PTText("PocketTrackpad sends audio directly to your Mac without saving recordings. GPT handles recognition under its own settings. Keep the iPhone app open."))}
        }.navigationTitle(PTText("Microphone"))
    }
}

private struct ControlVisibilitySettings:View {
    @ObservedObject var client:TrackpadClient
    var body:some View {
        Form {
            Section {
                Toggle(PTText("Quick key row"),isOn:$client.showQuickKeys)
                Toggle(PTText("Microphone button"),isOn:$client.showMicrophone)
                Toggle(PTText("Lock, rotation & settings"),isOn:$client.showTopControls)
            } footer:{Text(PTText("Use the arrow to show or hide controls. Your choice is saved."))}
            Section {Text(PTText("The stop button stays available until stopping is confirmed. Microphone errors appear only in Settings.")).foregroundStyle(.secondary)}
        }.navigationTitle(PTText("On-screen controls"))
    }
}
