import Foundation
var failures=0
func check(_ pass:Bool,_ name:String){print("\(pass ? "PASS":"FAIL") \(name)");if !pass{failures+=1}}
let off=PadDiagnostics();off.record(.touchMove,at:1,source:1);check(off.finish().samples.isEmpty,"recording is opt-in")
let trace=PadDiagnostics();trace.start(bluetooth:false,at:100)
trace.record(.touchSample,at:100.010,source:100.004,event:"move",count:1)
trace.record(.sendStart,at:100.013,source:100.004,count:1,pending:2,sequence:7)
trace.record(.ack,at:100.035,sequence:7)
let result=trace.finish()
check(result.samples.count==3 && abs(result.samples[0].ms-10)<0.001 && abs((result.samples[0].sourceMS ?? 0)-4)<0.001,"touch source, callback, send, and ACK times are distinguishable")
trace.record(.ack,at:100.04);check(trace.finish().samples.isEmpty,"finish immediately disables recording")
let bounded=PadDiagnostics(limit:2);bounded.start(bluetooth:true,at:0);for i in 0..<5{bounded.record(.display,at:Double(i)/100)}
let b=bounded.finish();check(b.samples.count==2 && b.droppedSamples==3,"memory is bounded and truncation is explicit")
let duration=PadDiagnostics();duration.start(bluetooth:false,at:0);duration.record(.gesture,at:15.001);duration.record(.gesture,at:-1);check(duration.finish().samples.isEmpty,"recording never extends past fifteen seconds")
let redacted=PadDiagnostics();redacted.start(bluetooth:false,at:1);redacted.record(.gesture,at:1.1,source:.infinity,event:"private typed text",phase:"https://private.local/#secret",value:.nan)
let safe=redacted.finish(),data=try JSONEncoder().encode(safe),text=String(decoding:data,as:UTF8.self)
check(!text.contains("private") && !text.contains("secret") && safe.samples.first?.value==nil,"arbitrary text, addresses, and non-finite values cannot enter the trace schema")
check(try JSONDecoder().decode(PadDiagnostics.Report.self,from:data).format==1,"export is a versioned decodable report")
let remote=PadDiagnostics();remote.start(bluetooth:false,at:100,remoteClock:true);remote.record(.receive,at:100.1,source:999999);remote.record(.output,at:100.2,source:999999.025)
let remoteReport=remote.finish();check(abs((remoteReport.samples.last?.sourceMS ?? 0)-25)<0.001,"Mac trace normalizes the independent iPhone clock")
exit(failures==0 ? 0:1)
