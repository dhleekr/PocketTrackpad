import Foundation

enum PadGestureSetting:String,CaseIterable {
    case tapToClick,lookup,pinchZoom,smartZoom,rotate,pageSwipe,notifications,apps,showDesktop
    var defaultValue:Bool {self != .smartZoom}
}
enum PadSecondaryClick:String,CaseIterable,Codable {case off,twoFingers,bottomRight,bottomLeft}

/// Sparse overrides preserve existing choices when future releases add settings.
struct PadGesturePreferences:Codable,Equatable {
    var toggles:[String:Bool]=[:]
    var secondaryClick:PadSecondaryClick = .twoFingers
    var spacesFingers=3
    var missionFingers=3
    var exposeFingers=3
    func enabled(_ setting:PadGestureSetting)->Bool{toggles[setting.rawValue] ?? setting.defaultValue}
    mutating func set(_ setting:PadGestureSetting,_ value:Bool){toggles[setting.rawValue]=value}
    static func load(from store:UserDefaults = .standard)->Self {
        guard let data=store.data(forKey:"pad.gestures"),let value=try? JSONDecoder().decode(Self.self,from:data) else{return Self()}
        var safe=value
        if ![0,3,4].contains(safe.spacesFingers){safe.spacesFingers=3}
        if ![0,3,4].contains(safe.missionFingers){safe.missionFingers=3}
        if ![0,3,4].contains(safe.exposeFingers){safe.exposeFingers=3}
        return safe
    }
    func save(in store:UserDefaults = .standard){if let data=try? JSONEncoder().encode(self){store.set(data,forKey:"pad.gestures")}}
}
