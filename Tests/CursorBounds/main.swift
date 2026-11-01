import Foundation
import CoreGraphics

var failures=0
func check(_ condition:Bool,_ name:String){print("\(condition ? "PASS":"FAIL") \(name)");if !condition{failures+=1}}
let main=CGRect(x:0,y:0,width:1440,height:900)
var displays=[main]
var bounds=CursorBounds(readDisplays:{displays})
check(bounds.clamp(CGPoint(x:1400,y:400),at:0)==CGPoint(x:1400,y:400),"move within startup display")
displays.append(CGRect(x:1440,y:0,width:2560,height:1440))
check(bounds.clamp(CGPoint(x:1600,y:400),at:1)==CGPoint(x:1600,y:400),"cross onto display connected after receiver launch")
displays=[main,CGRect(x:-1920,y:-400,width:1920,height:1080)]
check(bounds.clamp(CGPoint(x:-500,y:-200),at:2)==CGPoint(x:-500,y:-200),"follow display moved left and above main screen")
displays=[main]
check(main.contains(bounds.clamp(CGPoint(x:-500,y:400),at:3)),"stop targeting disconnected display")
var reads=0
var layout=[main]
var cached=CursorBounds(readDisplays:{reads+=1;return layout})
_ = cached.clamp(CGPoint(x:10,y:10),at:0)
let initialReads=reads
for tick in 1...29{_ = cached.clamp(CGPoint(x:10,y:10),at:Double(tick)/120)}
check(reads==initialReads,"cache geometry during display-paced frames")
layout=[main,CGRect(x:0,y:-1080,width:1920,height:1080)]
check(cached.clamp(CGPoint(x:500,y:-500),at:0.25)==CGPoint(x:500,y:-500),"refresh layout within 250 ms")
layout=[]
check(cached.clamp(CGPoint(x:500,y:-500),at:0.5)==CGPoint(x:500,y:-500),"retain valid geometry during transient display query failure")
layout=[CGRect(x:0,y:0,width:800,height:600)]
check(cached.clamp(CGPoint(x:1400,y:800),at:1).x<800,"refresh after resolution change")
exit(failures==0 ? 0:1)
