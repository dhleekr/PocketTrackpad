import Foundation
let rows=try! JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[Double]]
let playback=MotionPlayback();var next=0,outputs=[Double](),total=0.0
for frame in 0..<120 {
 let now=Double(frame)/120
 while next<rows.count,rows[next][1]<=now {
  let row=rows[next]
  _ = playback.accept(["type":"scroll","x":0.0,"y":row[2],"phase":next==0 ? "began":"changed","momentum":"none","t":row[0]],at:row[1]){_ in}
  next+=1
 }
 playback.frame(at:now){outputs.append($0["y"] as? Double ?? 0)}
}
playback.flush{outputs.append($0["y"] as? Double ?? 0)}
total=outputs.reduce(0,+)
let expected=rows.reduce(0){$0+$1[2]},peak=outputs.map{abs($0)}.max() ?? 0
print(String(format:"Buffered startup burst peak: %.1f points; expected distance %.1f; output %.1f",peak,expected,total))
// Synthetic timing reproduces the observed 18-packet startup batch without
// retaining a real diagnostic capture. A 120 Hz output frame can contain two
// 240 Hz input samples, with up to twice source speed for bounded catch-up.
let largestInput=rows.map{$0[2]}.max() ?? 0
let good=peak<=largestInput*4+0.001 && abs(expected-total)<0.0001
print(good ? "PASS delayed startup samples are paced without a first-frame jump":"FAIL startup burst collapses into a scroll jump")
exit(good ? 0:1)
