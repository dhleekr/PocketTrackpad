import Cocoa

/// A short, non-activating app notice. Never requests system notification access
/// or interrupts the receiving application's keyboard focus.
@MainActor final class MacNotice:NSObject {
    static let shared=MacNotice()
    private var panel:NSPanel?,dismissTimer:Timer?,lastKey="",lastShown=Date.distantPast
    private var openSettings:(()->Void)?
    func show(title:String="Dictation needs attention",message:String="Open Settings to check the app’s shortcut.",actionTitle:String="Open Settings",sticky:Bool=false,settings:@escaping ()->Void){
        let key=title+message
        guard key != lastKey || Date().timeIntervalSince(lastShown)>20 else{return}
        lastKey=key;lastShown=Date();dismiss();openSettings=settings
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:124),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        self.panel=panel;panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=true;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        let surface=NSVisualEffectView();surface.material = .popover;surface.blendingMode = .behindWindow;surface.state = .active
        surface.wantsLayer=true;surface.layer?.cornerRadius=16;surface.layer?.masksToBounds=true;panel.contentView=surface
        surface.layer?.borderWidth=0.5;surface.layer?.borderColor=NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        let icon=NSImageView(image:NSApp.applicationIconImage);icon.imageScaling = .scaleProportionallyUpOrDown
        let appName=NSTextField(labelWithString:"PocketTrackpad");appName.font = .systemFont(ofSize:11);appName.textColor = .secondaryLabelColor
        let heading=NSTextField(labelWithString:MacText(title));heading.font = .systemFont(ofSize:13,weight:.semibold)
        let body=NSTextField(wrappingLabelWithString:MacText(message));body.font = .systemFont(ofSize:12);body.textColor = .secondaryLabelColor
        let action=NSButton(title:MacText(actionTitle),target:self,action:#selector(open));action.bezelStyle = .rounded;action.controlSize = .small;action.font = .systemFont(ofSize:12)
        let close=NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:MacText("Dismiss")) ?? NSImage(),target:self,action:#selector(closeNotice));close.isBordered=false;close.setAccessibilityLabel(MacText("Dismiss"))
        for view in [icon,appName,heading,body,action,close]{view.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(view)}
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:14),icon.topAnchor.constraint(equalTo:surface.topAnchor,constant:15),icon.widthAnchor.constraint(equalToConstant:30),icon.heightAnchor.constraint(equalToConstant:30),
            appName.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),appName.topAnchor.constraint(equalTo:surface.topAnchor,constant:13),
            heading.leadingAnchor.constraint(equalTo:appName.leadingAnchor),heading.topAnchor.constraint(equalTo:appName.bottomAnchor,constant:4),heading.trailingAnchor.constraint(equalTo:close.leadingAnchor,constant:-8),
            close.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-9),close.topAnchor.constraint(equalTo:surface.topAnchor,constant:8),close.widthAnchor.constraint(equalToConstant:24),close.heightAnchor.constraint(equalToConstant:24),
            body.leadingAnchor.constraint(equalTo:heading.leadingAnchor),body.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-18),body.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:4),
            action.trailingAnchor.constraint(equalTo:body.trailingAnchor),action.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-12),action.heightAnchor.constraint(equalToConstant:24)

        ])
        let screen=NSScreen.screens.first(where:{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)}) ?? NSScreen.main
        if let frame=screen?.visibleFrame{panel.setFrameOrigin(NSPoint(x:frame.maxX-356,y:frame.minY+16))}
        let reducedMotion=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue=reducedMotion ? 1:0;panel.orderFrontRegardless()
        if !reducedMotion{NSAnimationContext.runAnimationGroup{context in context.duration=0.16;panel.animator().alphaValue=1}}
        if !sticky{dismissTimer=Timer.scheduledTimer(withTimeInterval:7,repeats:false){[weak self] _ in Task{@MainActor in self?.dismiss()}}}
    }
    @objc private func open(){let action=openSettings;dismiss();action?()}
    @objc private func closeNotice(){dismiss()}
    func dismiss(){dismissTimer?.invalidate();dismissTimer=nil;panel?.orderOut(nil);panel=nil;openSettings=nil}
}
