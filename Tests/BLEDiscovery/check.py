"""Exercise the actual Mac discovery callback with a recording Bluetooth transport."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'BLEHost.swift').read_text()
start=s.index('    func centralManager(_ central:CBCentralManager,didDiscover')
end=s.index('\n    func centralManager(',start+10)
callback=s[start:end]
# Only the CoreBluetooth boundary is replaced; the production callback is compiled unchanged.
phone=(root/'native-ios/Sources/BLEClient.swift').read_text()
assert 'CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:serviceID)]' in phone
assert 'CBMutableService(type:CBUUID(string:serviceID)' in phone
assert 'CBUUID(string:BLEWire.reverseService)' not in phone
assert 'scanForPeripherals(withServices:[CBUUID(string:service)]' in s
stub='''import Foundation
struct CBUUID:Equatable {let uuidString:String;init(string:String){uuidString=string.uppercased()}}
let CBAdvertisementDataServiceUUIDsKey="services"
let CBAdvertisementDataOverflowServiceUUIDsKey="overflow"
final class CBPeripheral {let identifier=UUID();var delegate:AnyObject?}
final class CBCentralManager {var connected=[UUID]();func stopScan(){};func connect(_ p:CBPeripheral){connected.append(p.identifier)}}
final class Probe {
 var peer:CBPeripheral?,attempted=[UUID:Date](),lastSeen=Date()
 var token:String?=String(repeating:"a",count:32)
 var peerService:CBUUID?
 func report(_ s:String){}
'''+callback+'''\n}
let target=Probe(),central=CBCentralManager(),stranger=CBPeripheral()
target.centralManager(central,didDiscover:stranger,advertisementData:[CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:BLEWire.reverseService)]],rssi:-30)
guard central.connected.isEmpty else{print("FAIL: the Mac tried to connect to an unrelated nearby iPhone before QR authentication");exit(1)}
let wrongServices:[String]=[BLEDiscovery.service(token:String(repeating:"b",count:32))!,UUID().uuidString]
for wrong in wrongServices {
 target.centralManager(central,didDiscover:CBPeripheral(),advertisementData:[CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:wrong)]],rssi:-20)
}
target.centralManager(central,didDiscover:CBPeripheral(),advertisementData:[:],rssi:-20)
guard central.connected.isEmpty else{print("FAIL: a different user's QR advertisement connected");exit(1)}
let missing=Probe();missing.token=nil
missing.centralManager(central,didDiscover:CBPeripheral(),advertisementData:[:],rssi:-20)
guard central.connected.isEmpty else{print("FAIL: missing QR permitted a connection");exit(1)}
let ownedService=BLEDiscovery.service(token:target.token)!
let own=CBPeripheral()
target.centralManager(central,didDiscover:own,advertisementData:[CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:ownedService)]],rssi:-60)
guard central.connected == [own.identifier] else{print("FAIL: matching QR iPhone was not connected");exit(1)}
print("PASS: unrelated discovery never connects; matching QR discovery connects")
'''
with tempfile.TemporaryDirectory(prefix='pocket-discovery-') as d:
 p=Path(d)/'main.swift';p.write_text(stub)
 subprocess.run(['swiftc','-module-cache-path','/private/tmp/pocket-discovery-cache',str(root/'shared/BLEWire.swift'),str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True)
