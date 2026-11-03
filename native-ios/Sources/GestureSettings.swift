import SwiftUI

private enum GestureDemo:String {
    case tap,press,secondary,lookup,scroll,pinch,smart,rotate,page,spaces,mission,expose,edge,apps,desktop
    var fingers:Int {switch self{case .tap,.press:return 1;case .lookup,.spaces,.mission,.expose:return 3;case .apps,.desktop:return 4;default:return 2}}
}
struct GestureSettings:View {
    @ObservedObject var client:TrackpadClient
    @State private var group=0
    @State private var demo=GestureDemo.tap
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        VStack(spacing:12){
            GesturePreview(demo:demo,fingerCount:previewFingers,secondary:client.gestures.secondaryClick).frame(height:typeSize.isAccessibilitySize ? 260:210).padding(.horizontal,16)
            if typeSize.isAccessibilitySize{category.pickerStyle(.menu)}else{category.pickerStyle(.segmented)}
            List {
                if group==0 {
                    Section {
                        VStack(alignment:.leading,spacing:8){Text(PTText("Cursor speed"));Slider(value:Binding(get:{PadTuning.speedPosition(client.sensitivity)},set:{client.sensitivity=PadTuning.speed(at:$0)}),in:0...1).accessibilityLabel(PTText("Cursor speed"))}
                        setting("Tap to click","Tap with one finger",.tapToClick,.tap)
                        Toggle(PTText("Press to click"),isOn:$client.pressClick).onChange(of:client.pressClick){_,_ in demo = .press}
                        Picker(PTText("Secondary click"),selection:$client.gestures.secondaryClick){
                            Text(PTText("Off")).tag(PadSecondaryClick.off)
                            Text(PTText("Tap with two fingers")).tag(PadSecondaryClick.twoFingers)
                            Text(PTText("Bottom-right corner")).tag(PadSecondaryClick.bottomRight)
                            Text(PTText("Bottom-left corner")).tag(PadSecondaryClick.bottomLeft)
                        }.onChange(of:client.gestures.secondaryClick){_,_ in demo = .secondary}
                        NavigationLink(PTText("Click timing")){ClickSettings(client:client)}
                        setting("Look up","Tap with three fingers",.lookup,.lookup)
                    }
                    Section {
                        HStack{Text("Force Click");Spacer();Text(PTText("Not supported")).foregroundStyle(.secondary)}
                    } footer:{Text(PTText("Two-stage Force Click is not available. Use Press to click and the separate Haptics settings instead."))}
                }else if group==1 {
                    Section {
                        Toggle(PTText("Natural scrolling"),isOn:$client.naturalScroll).onChange(of:client.naturalScroll){_,_ in demo = .scroll}
                        setting("Zoom in or out","Pinch with two fingers",.pinchZoom,.pinch)
                        setting("Smart zoom","Double-tap with two fingers",.smartZoom,.smart)
                        setting("Rotate","Rotate with two fingers",.rotate,.rotate)
                    }
                }else {
                    Section {
                        setting("Swipe between pages","Scroll left or right with two fingers",.pageSwipe,.page)
                        fingers("Swipe between spaces",value:$client.gestures.spacesFingers,preview:.spaces)
                        fingers("Mission Control",value:$client.gestures.missionFingers,preview:.mission)
                        fingers("App Exposé",value:$client.gestures.exposeFingers,preview:.expose)
                        setting("Notification Center","Swipe left from the right edge with two fingers",.notifications,.edge)
                        setting("Apps","Pinch inward with four fingers",.apps,.apps)
                        setting("Show Desktop","Spread with four fingers",.showDesktop,.desktop)
                    } footer:{Text(PTText("Available gestures depend on the Mac app and macOS settings."))}
                }
            }.listStyle(.insetGrouped)
        }.navigationTitle(PTText("Trackpad gestures")).navigationBarTitleDisplayMode(.inline)
         .onChange(of:group){_,value in demo=value==0 ? .tap:value==1 ? .scroll:.spaces}
         .onAppear {
             #if DEBUG
             if let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--ui-test-gesture=")}),let selected=GestureDemo(rawValue:String(arg.split(separator:"=").last ?? "")){
                 group=[GestureDemo.scroll,.pinch,.smart,.rotate].contains(selected) ? 1:[GestureDemo.page,.spaces,.mission,.expose,.edge,.apps,.desktop].contains(selected) ? 2:0
                 DispatchQueue.main.async{demo=selected}
             }
             #endif
         }
    }
    private var previewFingers:Int {
        switch demo{case .spaces:return max(3,client.gestures.spacesFingers);case .mission:return max(3,client.gestures.missionFingers);case .expose:return max(3,client.gestures.exposeFingers);case .secondary:return [.bottomLeft,.bottomRight].contains(client.gestures.secondaryClick) ? 1:2;default:return demo.fingers}
    }
    private var category:some View {
        Picker(PTText("Category"),selection:$group){Text(PTText("Point & Click")).tag(0);Text(PTText("Scroll & Zoom")).tag(1);Text(PTText("More Gestures")).tag(2)}.padding(.horizontal,16)
    }
    private func setting(_ title:String,_ detail:String,_ setting:PadGestureSetting,_ preview:GestureDemo)->some View {
        HStack(spacing:12){
            Button{demo=preview} label:{VStack(alignment:.leading,spacing:4){Text(PTText(title)).foregroundStyle(.primary);Text(PTText(detail)).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,minHeight:44,alignment:.leading)}.buttonStyle(.plain).accessibilityHint(PTText("Show gesture preview"))
            Toggle(PTText(title),isOn:Binding(get:{client.gestures.enabled(setting)},set:{client.gestures.set(setting,$0);demo=preview})).labelsHidden()
        }
    }
    private func fingers(_ title:String,value:Binding<Int>,preview:GestureDemo)->some View {
        HStack(spacing:12){
            Button{demo=preview} label:{Text(PTText(title)).foregroundStyle(.primary).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)}.buttonStyle(.plain).accessibilityHint(PTText("Show gesture preview"))
            Picker(PTText(title),selection:value){Text(PTText("Off")).tag(0);Text(PTText("Three fingers")).tag(3);Text(PTText("Four fingers")).tag(4)}.labelsHidden().pickerStyle(.menu).onChange(of:value.wrappedValue){_,_ in demo=preview}
        }
    }
}

private extension GestureDemo {
    var title:String {
        switch self {case .tap:return "Tap to click";case .press:return "Press to click";case .secondary:return "Secondary click";case .lookup:return "Look up";case .scroll:return "Natural scrolling";case .pinch:return "Zoom in or out";case .smart:return "Smart zoom";case .rotate:return "Rotate";case .page:return "Swipe between pages";case .spaces:return "Swipe between spaces";case .mission:return "Mission Control";case .expose:return "App Exposé";case .edge:return "Notification Center";case .apps:return "Apps";case .desktop:return "Show Desktop"}
    }
}

private struct GesturePreview:View {
    let demo:GestureDemo
    var fingerCount:Int
    var secondary:PadSecondaryClick
    @State private var paused=false
    @State private var epoch=Date()
    @State private var frozen=0.0
    @Environment(\.accessibilityReduceMotion) private var reduced
    private let accent=Color(red:0.79,green:0.96,blue:0.36)
    var body:some View {
        VStack(spacing:10){
            HStack {
                Text(PTText(demo.title)).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength:8)
                Button {
                    if paused{epoch=Date().addingTimeInterval(-frozen)}else{frozen=Date().timeIntervalSince(epoch)}
                    paused.toggle()
                } label:{Image(systemName:paused ? "play.fill":"pause.fill").font(.system(size:12,weight:.semibold)).frame(width:44,height:44)}
                .buttonStyle(.plain).accessibilityLabel(PTText(paused ? "Play animation":"Pause animation")).disabled(reduced)
            }.foregroundStyle(.white)
            TimelineView(.animation(minimumInterval:1.0/60,paused:paused || reduced)){timeline in
                Canvas{context,size in
                    let elapsed=paused ? frozen:timeline.date.timeIntervalSince(epoch)
                    let phase=reduced ? 0.6:elapsed.truncatingRemainder(dividingBy:3.6)/3.6
                    let raw=min(1,max(0,(phase-0.16)/0.46)),p=raw*raw*(3-2*raw)
                    let fade=reduced ? 1:min(1,max(0,phase/0.12))*min(1,max(0,(0.94-phase)/0.12))
                    let pad=CGRect(x:1,y:9,width:size.width*0.42,height:size.height-18)
                    let screen=CGRect(x:size.width*0.53,y:2,width:size.width*0.47-1,height:size.height-4)
                    let padShape=Path(roundedRect:pad,cornerRadius:12)
                    context.fill(padShape,with:.color(Color(white:0.13)))
                    context.stroke(padShape,with:.color(.white.opacity(0.28)),lineWidth:1)
                    let desktop=Path(roundedRect:screen,cornerRadius:7)
                    context.fill(desktop,with:.linearGradient(Gradient(colors:[Color(red:0.19,green:0.24,blue:0.31),Color(white:0.13)]),startPoint:screen.origin,endPoint:CGPoint(x:screen.maxX,y:screen.maxY)))
                    var display=context;display.clip(to:desktop)
                    // A quiet desktop, menu bar and dock anchor the visual result.
                    display.fill(Path(CGRect(x:screen.minX,y:screen.minY,width:screen.width,height:6)),with:.color(.white.opacity(0.1)))
                    display.fill(Path(roundedRect:CGRect(x:screen.midX-24,y:screen.maxY-8,width:48,height:5),cornerRadius:2),with:.color(.white.opacity(0.2)))
                    func window(_ rect:CGRect,_ opacity:Double=1,_ lines:Bool=true){
                        var draw=display;draw.opacity=opacity
                        draw.fill(Path(roundedRect:rect.offsetBy(dx:0,dy:2),cornerRadius:4),with:.color(.black.opacity(0.25)))
                        draw.fill(Path(roundedRect:rect,cornerRadius:4),with:.color(Color(white:0.88)))
                        draw.fill(Path(CGRect(x:rect.minX+5,y:rect.minY+5,width:max(3,rect.width-10),height:3)),with:.color(.black.opacity(0.16)))
                        if lines{for row in 0..<3{draw.fill(Path(roundedRect:CGRect(x:rect.minX+6,y:rect.minY+14+CGFloat(row)*7,width:max(4,rect.width-12-(row==2 ? 12:0)),height:2),cornerRadius:1),with:.color(.black.opacity(0.2)))}}
                    }
                    let main=screen.insetBy(dx:12,dy:15)
                    if demo == .mission || demo == .expose {
                        let left=CGRect(x:screen.minX+8,y:screen.minY+16,width:screen.width*0.45,height:screen.height*0.48)
                        let right=CGRect(x:screen.midX+3,y:screen.minY+24,width:screen.width*0.43,height:screen.height*0.46)
                        func blend(_ a:CGRect,_ b:CGRect)->CGRect{CGRect(x:a.minX+(b.minX-a.minX)*p,y:a.minY+(b.minY-a.minY)*p,width:a.width+(b.width-a.width)*p,height:a.height+(b.height-a.height)*p)}
                        window(blend(main.offsetBy(dx:6,dy:4),right),demo == .expose ? 1-p*0.5:1)
                        window(blend(main,left))
                    }else if demo == .desktop {
                        window(main.offsetBy(dx:p*screen.width*0.9,dy: -p*screen.height*0.75),1-p*0.3)
                        window(main.offsetBy(dx: -p*screen.width*0.9,dy:p*screen.height*0.75),1-p*0.3)
                    }else if demo == .apps {
                        window(main,1-p)
                        for i in 0..<9 {
                            let side=min(18,screen.width/7),gap=side+8
                            let rect=CGRect(x:screen.midX-gap*1.5+CGFloat(i%3)*gap+4,y:screen.midY-gap*1.5+CGFloat(i/3)*gap+4,width:side,height:side)
                            display.fill(Path(roundedRect:rect,cornerRadius:4),with:.color((i==4 ? accent:Color.white).opacity(p*(i==4 ? 0.9:0.45))))
                        }
                    }else if demo == .page || demo == .spaces {
                        window(main.offsetBy(dx: -p*screen.width*0.75,dy:0))
                        window(main.offsetBy(dx:screen.width-p*screen.width*0.75,dy:0))
                    }else {
                        window(main,1,demo != .rotate && demo != .pinch && demo != .smart && demo != .scroll)
                        var contents=display;contents.clip(to:Path(main.insetBy(dx:3,dy:10)))
                        if demo == .pinch || demo == .smart || demo == .rotate {
                            let scale=demo == .rotate ? 1:1+p*0.65
                            contents.translateBy(x:main.midX,y:main.midY+3);contents.scaleBy(x:scale,y:scale)
                            if demo == .rotate{contents.rotate(by:.degrees(p*65))}
                            contents.fill(Path(roundedRect:CGRect(x: -16,y: -14,width:32,height:28),cornerRadius:5),with:.color(accent.opacity(0.85)))
                            contents.stroke(Path(CGRect(x: -9,y: -7,width:18,height:14)),with:.color(.black.opacity(0.2)),lineWidth:1)
                        }else if demo == .scroll {
                            for i in 0..<8{contents.fill(Path(roundedRect:CGRect(x:main.minX+6,y:main.minY+14+CGFloat(i)*9-p*25,width:main.width-12,height:3),cornerRadius:1),with:.color(.black.opacity(0.2)))}
                        }else if demo == .lookup {
                            let popover=CGRect(x:main.midX-22,y:main.midY-8,width:44,height:29)
                            display.fill(Path(roundedRect:popover,cornerRadius:4),with:.color(accent.opacity(p)))
                        }else if [.tap,.press,.secondary].contains(demo) {
                            let x=main.midX,y=main.midY
                            display.stroke(Path(ellipseIn:CGRect(x:x-6-p*7,y:y-6-p*7,width:12+p*14,height:12+p*14)),with:.color(accent.opacity(1-p)),lineWidth:1.5)
                            if demo == .secondary{display.fill(Path(roundedRect:CGRect(x:x-3,y:y,width:35,height:26),cornerRadius:3),with:.color(Color(white:0.3).opacity(p)))}
                        }
                    }
                    if demo == .edge {
                        let panel=CGRect(x:screen.maxX-p*screen.width*0.6,y:screen.minY+7,width:screen.width*0.6,height:screen.height-9)
                        display.fill(Path(roundedRect:panel,cornerRadius:5),with:.color(Color(white:0.25)))
                        for row in 0..<3{display.fill(Path(roundedRect:CGRect(x:panel.minX+5,y:panel.minY+7+CGFloat(row)*19,width:panel.width-10,height:14),cornerRadius:3),with:.color(.white.opacity(0.13)))}
                    }
                    // Contacts fade out before reset, so the replay never implies a reverse action.
                    var hand=context;hand.clip(to:padShape);hand.opacity=fade
                    let center=CGPoint(x:pad.midX,y:pad.midY)
                    for index in 0..<fingerCount {
                        var x=center.x+(CGFloat(index)-CGFloat(fingerCount-1)/2)*18,y=center.y
                        if demo == .secondary,secondary == .bottomRight{x=pad.maxX-15;y=pad.maxY-15}
                        if demo == .secondary,secondary == .bottomLeft{x=pad.minX+15;y=pad.maxY-15}
                        if demo == .pinch{x=center.x+(index==0 ? -1:1)*(14+p*14)}
                        if demo == .rotate{let a=Double(index)*Double.pi+p*0.8;x=center.x+cos(a)*22;y=center.y+sin(a)*22}
                        if demo == .apps || demo == .desktop {
                            let spread=demo == .apps ? 1-p*0.5:0.55+p*0.6
                            x=center.x+(index==0 ? -25:CGFloat(index-2)*18)*spread;y=center.y+(index==0 ? 20: -12)*spread
                        }
                        if demo == .edge{x=pad.maxX-12-CGFloat(index)*17-p*pad.width*0.45;y=center.y+CGFloat(index)*6}
                        if [.page,.spaces].contains(demo){x+=18-p*36}
                        if [.mission,.expose,.scroll].contains(demo){y+=(demo == .expose ? -12+p*28:12-p*28)}
                        let pulse=demo == .smart ? max(0,sin(raw*Double.pi*4)):([GestureDemo.tap,.press,.secondary,.lookup].contains(demo) ? sin(min(1,raw*3)*Double.pi):0)
                        let finger=CGRect(x:x-5.5-pulse,y:y-8-pulse,width:11+pulse*2,height:16+pulse*2)
                        hand.fill(Path(roundedRect:finger,cornerRadius:7),with:.color(accent.opacity(0.15)))
                        hand.stroke(Path(roundedRect:finger,cornerRadius:7),with:.color(accent),lineWidth:1.4)
                        hand.fill(Path(ellipseIn:CGRect(x:x-2,y:y-2,width:4,height:4)),with:.color(accent.opacity(0.7)))
                    }
                }
            }.accessibilityLabel(PTText(demo.title)).accessibilityHint(PTText("Illustration only. No action is sent to the Mac."))
            HStack{Text("iPhone").frame(maxWidth:.infinity);Text("Mac").frame(maxWidth:.infinity)}.font(.system(size:11,weight:.medium)).accessibilityHidden(true).foregroundStyle(.white.opacity(0.55)).padding(.horizontal,5)
        }.padding(.horizontal,16).padding(.vertical,8).background(Color(white:0.075),in:RoundedRectangle(cornerRadius:18)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of:demo){_,_ in epoch=Date();frozen=0}
    }
}
