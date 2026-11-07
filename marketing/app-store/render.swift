// Deterministic artwork using unaltered screenshots of the shipping app.
// Run from the repository root: swift marketing/app-store/render.swift
import AppKit
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let folder=root.appendingPathComponent("marketing/app-store")
func color(_ hex:UInt32)->NSColor {NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)}
let ink=color(0x1d1d1f),muted=color(0x66666e),paper=color(0xfafafa),lime=color(0xc5fa37)
func rect(_ r:NSRect,_ c:NSColor,_ radius:CGFloat=0){c.setFill();NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill()}
func text(_ s:String,_ r:NSRect,_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ c:NSColor=ink,_ spacing:CGFloat = -1){let p=NSMutableParagraphStyle();p.lineSpacing=4;p.lineBreakMode = .byWordWrapping;(s as NSString).draw(in:r,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:c,.paragraphStyle:p,.kern:spacing])}
func image(_ path:URL,_ r:NSRect){guard let im=NSImage(contentsOf:path) else{fatalError(path.path)};im.draw(in:r,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])}
func canvas(_ w:Int,_ h:Int,_ output:URL,_ draw:()->Void){let im=NSImage(size:NSSize(width:w,height:h));im.lockFocusFlipped(true);NSGraphicsContext.current?.imageInterpolation = .high;draw();im.unlockFocus();let b=NSBitmapImageRep(data:im.tiffRepresentation!)!;try! b.representation(using:.jpeg,properties:[.compressionFactor:0.94])!.write(to:output)}
func phone(_ path:URL,x:CGFloat,y:CGFloat,w:CGFloat){let h=w*2868/1320;NSGraphicsContext.saveGraphicsState();let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.18);shadow.shadowOffset=NSSize(width:0,height:-22);shadow.shadowBlurRadius=45;shadow.set();rect(NSRect(x:x,y:y,width:w,height:h),color(0x242426),w*0.145);NSGraphicsContext.restoreGraphicsState();rect(NSRect(x:x+3,y:y+3,width:w-6,height:h-6),color(0x747479),w*0.14);rect(NSRect(x:x+6,y:y+6,width:w-12,height:h-12),color(0x151517),w*0.138);let inset:CGFloat=14;NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:NSRect(x:x+inset,y:y+inset,width:w-inset*2,height:h-inset*2),xRadius:w*0.12,yRadius:w*0.12).addClip();image(path,NSRect(x:x+inset,y:y+inset,width:w-inset*2,height:h-inset*2));NSGraphicsContext.restoreGraphicsState();rect(NSRect(x:x+w*0.355,y:y+w*0.045,width:w*0.29,height:w*0.075),.black,w*0.04)}
struct Slide {let name:String;let title:[String];let detail:[String];let source:String}
let slides=[
 Slide(name:"01-trackpad",title:["Your iPhone.\nYour Mac’s trackpad.","아이폰이\nMac의 트랙패드로."],detail:["A spacious surface. Familiar gestures.\nFor your Mac, over Wi-Fi or Bluetooth.","넓은 터치 면. 익숙한 제스처.\nWi-Fi 또는 Bluetooth로 Mac과 연결하세요."],source:"controller"),
 Slide(name:"02-gestures",title:["Familiar gestures.\nMade yours.","익숙한 제스처를\n원하는 대로."],detail:["Point, scroll, pinch, and switch spaces.\nChoose which gestures work for you.","이동, 스크롤, 확대·축소, 화면 전환.\n설정에서 동작별로 켜고 끄세요."],source:"gestures"),
 Slide(name:"03-keys",title:["Four keys.\nYour kind of control.","네 개의 키.\n나만의 컨트롤."],detail:["Choose each key. Tap or hold to repeat.\nSet the delay and Backspace speed.","원하는 키를 고르고, 탭하거나 길게 누르세요.\n반복 시작 시간과 삭제 속도까지 조절하세요."],source:"keys"),
 Slide(name:"04-connect",title:["Scan. Connect.\nMake your move.","스캔하고 연결하면\n바로 내 손안에."],detail:["Get the free Mac companion.\nScan its QR code. You’re ready.","무료 Mac 수신 앱을 설치하세요.\nQR을 스캔하면 준비 끝."],source:"connection")]
for (langIndex,lang) in ["en","ko"].enumerated(){
 for (i,s) in slides.enumerated(){let output=folder.appendingPathComponent("\(lang)/\(s.name).jpg");canvas(1320,2868,output){
 rect(NSRect(x:0,y:0,width:1320,height:2868),paper)
 image(root.appendingPathComponent("website/icon.png"),NSRect(x:100,y:104,width:52,height:52));text("PocketTrackpad",NSRect(x:172,y:110,width:650,height:52),35,.semibold,ink,-1)
 text(s.title[langIndex],NSRect(x:96,y:248,width:1140,height:325),langIndex==0 ? 109:112,.semibold,ink,-4)
 text(s.detail[langIndex],NSRect(x:100,y:585,width:1120,height:145),42,.regular,muted,-0.9)
 // A restrained tone-on-tone stage keeps the actual screen central.
 let stage=i==0 ? color(0xeff2e7):color(0xefeff2)
 rect(NSRect(x:65,y:815,width:1190,height:1900),stage,110)
 phone(folder.appendingPathComponent("source/\(lang)/\(s.source).png"),x:230,y:820,w:860)
 text(langIndex==0 ? "iPhone + Mac · Both apps required":"iPhone + Mac · 두 앱이 모두 필요합니다",NSRect(x:100,y:2760,width:1120,height:48),26,.regular,muted,0)
 }}
}
// A shareable proof sheet shows both languages without opening eight files.
canvas(1800,2040,folder.appendingPathComponent("overview.jpg")){
 rect(NSRect(x:0,y:0,width:1800,height:2040),color(0xe8e8eb))
 for (row,lang) in ["en","ko"].enumerated(){for (col,s) in slides.enumerated(){image(folder.appendingPathComponent("\(lang)/\(s.name).jpg"),NSRect(x:CGFloat(24+col*444),y:CGFloat(24+row*1008),width:420,height:912))}}
}
canvas(1200,630,root.appendingPathComponent("website/social.jpg")){
 rect(NSRect(x:0,y:0,width:1200,height:630),paper)
 image(root.appendingPathComponent("website/icon.png"),NSRect(x:65,y:60,width:45,height:45));text("PocketTrackpad",NSRect(x:122,y:68,width:600,height:45),27,.semibold,ink,-0.7)
 text("A little closer\nto your Mac.",NSRect(x:65,y:205,width:700,height:230),76,.semibold,ink,-3)
 text("Your iPhone. A trackpad. And a little more.",NSRect(x:68,y:490,width:720,height:70),25,.regular,muted,-0.5)
 phone(folder.appendingPathComponent("source/en/controller.png"),x:845,y:65,w:235)
}
print("Rendered eight App Store screenshots, an overview, and a social image.")
