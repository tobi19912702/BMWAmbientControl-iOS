import SwiftUI
import CoreBluetooth

struct Phase: Codable, Identifiable {
 var id = UUID()
 var red = 255.0
 var green = 0.0
 var blue = 0.0
 var duration = 1.0
}
final class Lighting: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
 @Published var devices: [CBPeripheral] = []
 @Published var ready = Set<UUID>()
 @Published var status = "Bluetooth startet"
 @Published var logs: [String] = []
 private var central: CBCentralManager!
 private var writers: [UUID:CBCharacteristic] = [:]
 private var wanted = Set<UUID>()
 override init() { super.init(); central = CBCentralManager(delegate:self, queue:nil) }
 func centralManagerDidUpdateState(_ central: CBCentralManager) {
  status = central.state == .poweredOn ? "Bluetooth bereit" : "Bluetooth nicht bereit"
  if central.state == .poweredOn { scan() } else { ready.removeAll(); writers.removeAll() }
 }
 func scan() { if central.state == .poweredOn { central.scanForPeripherals(withServices:nil) } }
 func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
  let n = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "").uppercased()
  if (n.hasPrefix("ELK") || n.hasPrefix("MELK")), !devices.contains(where: {$0.identifier == p.identifier}) { devices.append(p) }
 }
 func connect(_ p: CBPeripheral) { wanted.insert(p.identifier); p.delegate = self; central.connect(p) }
 func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([CBUUID(string:"FFF0")]) }
 func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
  ready.remove(p.identifier); writers.removeValue(forKey:p.identifier)
  if wanted.contains(p.identifier), central.state == .poweredOn { central.connect(p) }
 }
 func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
  for s in p.services ?? [] { p.discoverCharacteristics([CBUUID(string:"FFF3"),CBUUID(string:"FFF4")], for:s) }
 }
 func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
  for c in s.characteristics ?? [] {
   if c.uuid == CBUUID(string:"FFF3"), c.properties.contains(.writeWithoutResponse) { writers[p.identifier] = c; ready.insert(p.identifier) }
   if c.uuid == CBUUID(string:"FFF4"), c.properties.contains(.notify) { p.setNotifyValue(true, for:c) }
  }
 }
 func record(_ s:String) { logs.append(s); if logs.count > 100 { logs.removeFirst() } }
 func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
  if let d = c.value { record("RX " + d.map { String(format:"%02X",$0) }.joined()) }
 }
 func send(_ bytes: [UInt8], to ids: Set<UUID>, experimental: Bool) {
  for p in devices where ids.contains(p.identifier) {
   guard ready.contains(p.identifier), let c = writers[p.identifier], p.canSendWriteWithoutResponse else { record("Nicht sendebereit"); continue }
   let verified = (p.name ?? "").uppercased().hasPrefix("ELK-BLEDOM") && bytes == [0x7E,7,5,3,255,0,0,16,0xEF]
   guard verified || experimental else { record("Nicht verifizierter Befehl blockiert"); continue }
   p.writeValue(Data(bytes), for:c, type:.withoutResponse)
   record("TX " + bytes.map { String(format:"%02X",$0) }.joined())
  }
 }
}
@main struct AmbientApp: App { var body: some Scene { WindowGroup { MainView() } } }
struct MainView: View {
 @StateObject private var ble = Lighting()
 @State private var selected = Set<UUID>()
 @State private var experimental = false
 @State private var zone = 0
 @State private var first = [Phase()]
 @State private var second = [Phase()]
 @State private var task: Task<Void,Never>?
 @AppStorage("ambientScenes") private var saved = Data()
 var steps: Binding<[Phase]> { zone == 0 ? $first : $second }
 var body: some View {
  NavigationStack {
   List {
    Section("Controller") {
     Text(ble.status)
     Button("Geräte suchen") { ble.scan() }
     ForEach(ble.devices,id: \.identifier) { p in
      HStack {
       Button(p.name ?? "BLE Controller") { ble.connect(p) }.buttonStyle(.borderless)
       Spacer()
       Toggle("Zone",isOn: Binding(get:{selected.contains(p.identifier)},set:{ on in if on { selected.insert(p.identifier) } else { selected.remove(p.identifier) } })).labelsHidden().disabled(!ble.ready.contains(p.identifier))
      }
     }
     Toggle("Experimentelle Befehle freigeben",isOn:$experimental)
     Button("Rot testen") { ble.send([0x7E,7,5,3,255,0,0,16,0xEF],to:selected,experimental:experimental) }
    }
    Section("Startsequenz – App-Wiedergabe") {
     Picker("Szenenprofil",selection:$zone) { Text("TWETIZ").tag(0); Text("Dreamcolor").tag(1) }.pickerStyle(.segmented)
     Text("Keine Änderung der Controller-Firmware. MELK und weitere Farben sind unbestätigt.")
     ForEach(steps) { $s in
      VStack(alignment:.leading) {
       RoundedRectangle(cornerRadius:8).fill(Color(red:s.red/255,green:s.green/255,blue:s.blue/255)).frame(height:30)
       Text("Rot"); Slider(value:$s.red,in:0...255,step:1)
       Text("Grün"); Slider(value:$s.green,in:0...255,step:1)
       Text("Blau"); Slider(value:$s.blue,in:0...255,step:1)
       Text("Dauer: " + String(format:"%.1f s",s.duration)); Slider(value:$s.duration,in:0.1...10,step:0.1)
      }
     }.onDelete { steps.wrappedValue.remove(atOffsets:$0) }.onMove { steps.wrappedValue.move(fromOffsets:$0,toOffset:$1) }
     Button("Phase hinzufügen") { if steps.wrappedValue.count < 50 { steps.wrappedValue.append(Phase()) } }
     Button("Speichern") { if let d = try? JSONEncoder().encode([first,second]) { saved = d } }
     Button("Abspielen") {
      task?.cancel()
      let sequence = steps.wrappedValue, ids = selected, allow = experimental
      task = Task { @MainActor in
       for s in sequence {
        if Task.isCancelled { return }
        ble.send([0x7E,7,5,3,UInt8(s.red),UInt8(s.green),UInt8(s.blue),16,0xEF],to:ids,experimental:allow)
        do { try await Task.sleep(nanoseconds:UInt64(s.duration*1_000_000_000)) } catch { return }
       }
      }
     }
     Button("Stoppen") { task?.cancel() }
    }
    Section("Diagnose") { ForEach(Array(ble.logs.enumerated()),id: \.offset) { item in Text(item.element).font(.caption.monospaced()) } }
   }.navigationTitle("BMW Ambient Control").toolbar { EditButton() }
   .onAppear { if let s = try? JSONDecoder().decode([[Phase]].self,from:saved), s.count == 2 { first = s[0]; second = s[1] } }
  }
 }
}
