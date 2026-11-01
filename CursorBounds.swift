import Foundation
import CoreGraphics

/// Quartz desktop coordinates, including displays above or left of the main screen.
struct CursorBounds {
    private let readDisplays:()->[CGRect]
    private var screens:[CGRect]
    private var lastRefresh = -Double.infinity
    init(readDisplays:@escaping ()->[CGRect]) {
        self.readDisplays=readDisplays;screens=readDisplays()
    }
    mutating func clamp(_ target:CGPoint,at now:Double)->CGPoint {
        // Display geometry can change while the background receiver remains running.
        // Cache briefly so display-paced input does not query WindowServer every frame.
        if now.isFinite && (now<lastRefresh || now-lastRefresh>=0.25) {
            let current=readDisplays().filter{!$0.isNull && !$0.isInfinite && $0.width>0 && $0.height>0}
            if !current.isEmpty{screens=current}
            lastRefresh=now
        }
        if screens.contains(where:{$0.contains(target)}){return target}
        return screens.map{bounds in
            CGPoint(x:max(bounds.minX,min(bounds.maxX-0.01,target.x)),y:max(bounds.minY,min(bounds.maxY-0.01,target.y)))
        }.min{a,b in hypot(a.x-target.x,a.y-target.y)<hypot(b.x-target.x,b.y-target.y)} ?? target
    }
}
