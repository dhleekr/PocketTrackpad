import UIKit
import SwiftUI
import Combine

final class NativePadView:UIView {
    let engine=GestureEngine()
    private var touchesByID=[ObjectIdentifier:(touch:UITouch,id:Int)]()
    private var nextID=0
    private var touchFrames=PadTouchFrameAssembler()
    private var emissionTime=0.0
    private var link:CADisplayLink?
    private var requestedFrameRate:Float=0
    private let clickFeedback=UIImpactFeedbackGenerator(style:.heavy)
    private let releaseFeedback=UIImpactFeedbackGenerator(style:.light)
    var client:TrackpadClient!
    private var wasReady=false
    private var previousTransport:TrackpadClient.Transport = .wifi
    override var canBecomeFirstResponder:Bool { true }
    override var editingInteractionConfiguration:UIEditingInteractionConfiguration { .none }
    override func canPerformAction(_ action:Selector,withSender sender:Any?)->Bool { false }
    init(client:TrackpadClient) {
        self.client=client;super.init(frame:.zero)
        backgroundColor=UIColor(white:0.094,alpha:1);isMultipleTouchEnabled=true
        isAccessibilityElement=true
        accessibilityLabel=PTText("Trackpad surface")
        accessibilityHint=PTText("Move one finger, scroll with two fingers, swipe up with three fingers for Mission Control, or swipe left and right to switch desktops. Tap or press briefly to click.")
        engine.emit={ [weak self] events in
            guard let self else{return}
            for event in events {self.client.diagnostics.record(.gesture,source:self.emissionTime,event:event.type,phase:event.phase,momentum:event.momentum,value:hypot(event.x ?? 0,event.y ?? 0))}
            let stamped=events.map {event -> PadEvent in var value=event;value.t=self.emissionTime;return value}
            self.client.send(stamped)
        }
        engine.haptic={ [weak self] kind in
            guard let self,self.client.ready,self.client.hapticStrength>0,self.client.allowsHaptic(kind) else { return }
            if kind != .release { self.clickFeedback.impactOccurred(intensity:self.client.hapticStrength);self.clickFeedback.prepare() }
            else { self.releaseFeedback.impactOccurred(intensity:self.client.hapticStrength*0.6);self.releaseFeedback.prepare() }
        }
        NotificationCenter.default.addObserver(self,selector:#selector(cancelForBackground),name:UIApplication.willResignActiveNotification,object:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { link?.invalidate();NotificationCenter.default.removeObserver(self) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder();clickFeedback.prepare();releaseFeedback.prepare()
            if link==nil {
                let timer=CADisplayLink(target:self,selector:#selector(advanceFrame))
                let maximum=Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
                timer.preferredFrameRateRange=CAFrameRateRange(minimum:min(60,maximum),maximum:maximum,preferred:maximum)
                timer.add(to:.main,forMode:.common);link=timer
            }
        } else { engine.cancel();touchesByID=[:];link?.invalidate();link=nil }
    }
    private func configure() {
        engine.surfaceWidth=Double(bounds.width);engine.surfaceHeight=Double(bounds.height);engine.rightEdgeInset=Double(window?.safeAreaInsets.right ?? safeAreaInsets.right);engine.gestures=client.gestures;engine.continuousScaleEnabled=client.continuousSystemGestures
        engine.sensitivity=client.sensitivity;engine.pressDelay=client.pressDelay;engine.doubleTapInterval=client.doubleTapInterval
        engine.pressClickEnabled=client.pressClick;engine.naturalScroll=client.naturalScroll
        let available=traitCollection.forceTouchCapability == .available
        engine.hardwarePressureAvailable=available
        if client.pressureAvailable != available { client.pressureAvailable=available }
    }
    private func positions()->[Int:PadPoint] {
        var result=[Int:PadPoint]()
        for value in touchesByID.values {
            let p=value.touch.location(in:self)
            let force=engine.hardwarePressureAvailable && value.touch.maximumPossibleForce>0 ? Double(value.touch.force/value.touch.maximumPossibleForce):0
            result[value.id]=PadPoint(x:p.x,y:p.y,force:force)
        }
        return result
    }
    @objc private func advanceFrame(_ sender:CADisplayLink) {
        client.diagnostics.record(.display,source:sender.timestamp)
        configure()
        let maximum=Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        let desired=client.ready ? maximum:min(30,maximum)
        if requestedFrameRate != desired {
            sender.preferredFrameRateRange=CAFrameRateRange(minimum:desired,maximum:desired,preferred:desired)
            requestedFrameRate=desired
        }
        if previousTransport != client.transport {engine.cancel();touchesByID=[:];previousTransport=client.transport}
        guard client.ready else {
            if wasReady { engine.cancel();touchesByID=[:] };wasReady=false;return
        }
        wasReady=true
        let now=CACurrentMediaTime()
        emissionTime=now;engine.tick(at:now)
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) {
        client.diagnostics.record(.touchBegin,source:event?.timestamp,count:touches.count)
        guard client.ready else { return };configure()
        let now=event?.timestamp ?? CACurrentMediaTime();emissionTime=now
        engine.update(positions(),at:now)
        for touch in touches { nextID+=1;touchesByID[ObjectIdentifier(touch)]=(touch,nextID) }
        let current=positions();touchFrames.reset(current,at:now);engine.update(current,at:now)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) {
        client.diagnostics.record(.touchMove,source:event?.timestamp,count:touches.count)
        guard client.ready else{return};configure()
        var samples=[PadTouchSample]()
        for touch in touches {
            guard let tracked=touchesByID[ObjectIdentifier(touch)] else{continue}
            for sample in event?.coalescedTouches(for:touch) ?? [touch] {
                let p=sample.location(in:self)
                let force=engine.hardwarePressureAvailable && sample.maximumPossibleForce>0 ? Double(sample.force/sample.maximumPossibleForce):0
                samples.append(PadTouchSample(id:tracked.id,time:sample.timestamp,point:PadPoint(x:p.x,y:p.y,force:force)))
            }
        }
        for frame in touchFrames.consume(samples){client.diagnostics.record(.touchSample,source:frame.time,count:frame.points.count);emissionTime=frame.time;engine.update(frame.points,at:frame.time)}
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) {
        client.diagnostics.record(.touchEnd,source:event?.timestamp,count:touches.count)
        let now=event?.timestamp ?? CACurrentMediaTime();emissionTime=now;engine.update(positions(),at:now)
        for touch in touches { touchesByID.removeValue(forKey:ObjectIdentifier(touch)) }
        let current=positions();touchFrames.reset(current,at:now);engine.update(current,at:now)
        if current.isEmpty {client.send([PadEvent(type:"status",name:"motionEnd",t:now)])}
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) { cancelForBackground() }
    func cancelForRotation(){cancelForBackground()}
    @objc private func cancelForBackground() { client.diagnostics.record(.touchCancel);emissionTime=CACurrentMediaTime();engine.cancel();touchesByID=[:];touchFrames.reset([:],at:emissionTime) }
}

@MainActor final class PadOrientationDelegate:NSObject,UIApplicationDelegate {
    static var mask:UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application:UIApplication,supportedInterfaceOrientationsFor window:UIWindow?)->UIInterfaceOrientationMask {Self.mask}
}

final class PadController:UIViewController {
    let client:TrackpadClient
    private var pad:NativePadView!
    private let controls=UIStackView()
    private let lockButton=UIButton(type:.system)
    private let rotateButton=UIButton(type:.system)
    private let microphoneButton=UIButton(type:.system)
    private let settingsButton=UIButton(type:.system)
    private var controlTop:NSLayoutConstraint!
    private let quickKeys=UIStackView()
    private let revealButton=UIButton(type:.system)
    private var revealingControls=false
    private var controlsCollapsed=UserDefaults.standard.bool(forKey:"pad.controlsCollapsed") {didSet{UserDefaults.standard.set(controlsCollapsed,forKey:"pad.controlsCollapsed")}}
    private var chromeDismiss:DispatchWorkItem?
    private var keyRowWidth:NSLayoutConstraint!
    private var rowWidth:NSLayoutConstraint!

    private var keyButtons=[UIButton]()
    private var controlTrailing:NSLayoutConstraint!
    private var subscriptions=Set<AnyCancellable>()
    #if DEBUG
    private var controlsTestStarted=false
    #endif
    init(client:TrackpadClient) { self.client=client;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override var editingInteractionConfiguration:UIEditingInteractionConfiguration { .none }
    override var canBecomeFirstResponder:Bool { true }
    override var prefersStatusBarHidden:Bool { true }
    override var shouldAutorotate:Bool { true }
    override var supportedInterfaceOrientations:UIInterfaceOrientationMask { PadOrientationDelegate.mask }
    override func viewWillTransition(to size:CGSize,with coordinator:UIViewControllerTransitionCoordinator){
        pad?.cancelForRotation()
        super.viewWillTransition(to:size,with:coordinator)
        coordinator.animate(alongsideTransition:nil){[weak self] _ in
            guard let self,let scene=self.view.window?.windowScene else{return}
            self.client.landscape=scene.interfaceOrientation.isLandscape
        }
    }
    override func loadView() {
        view=UIView();view.backgroundColor=UIColor(white:0.094,alpha:1)
        pad=NativePadView(client:client);pad.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(pad)
        // The entire screen remains the trackpad; controls float above it.
        NSLayoutConstraint.activate([pad.leadingAnchor.constraint(equalTo:view.leadingAnchor),pad.trailingAnchor.constraint(equalTo:view.trailingAnchor),pad.topAnchor.constraint(equalTo:view.topAnchor),pad.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        controls.axis = .horizontal;controls.spacing=8
        controls.backgroundColor = .clear
        controls.layer.cornerRadius=0;controls.isLayoutMarginsRelativeArrangement=true
        controls.directionalLayoutMargins=NSDirectionalEdgeInsets(top:2,leading:4,bottom:2,trailing:4)
        controls.translatesAutoresizingMaskIntoConstraints=false
        for button in [lockButton,rotateButton,settingsButton] {
            button.tintColor=UIColor(white:0.78,alpha:1)
            button.translatesAutoresizingMaskIntoConstraints=false
            button.widthAnchor.constraint(equalToConstant:44).isActive=true
            button.heightAnchor.constraint(equalToConstant:44).isActive=true
            controls.addArrangedSubview(button)
        }
        lockButton.accessibilityIdentifier="pad.lock"
        rotateButton.accessibilityIdentifier="pad.rotate"
        settingsButton.accessibilityIdentifier="pad.settings"
        microphoneButton.accessibilityIdentifier="pad.dictation"
        microphoneButton.accessibilityLabel=PTText("Dictation")
        microphoneButton.setImage(UIImage(systemName:"mic"),for:.normal)
        microphoneButton.addTarget(self,action:#selector(dictationTapped),for:.touchUpInside)
        rotateButton.setImage(UIImage(systemName:"rotate.right"),for:.normal)
        settingsButton.setImage(UIImage(systemName:"ellipsis"),for:.normal)
        lockButton.addTarget(self,action:#selector(lockTapped),for:.touchUpInside)
        lockButton.addGestureRecognizer(UILongPressGestureRecognizer(target:self,action:#selector(unlockHeld)))
        (lockButton.gestureRecognizers?.first as? UILongPressGestureRecognizer)?.minimumPressDuration=1.2
        rotateButton.addTarget(self,action:#selector(rotateTapped),for:.touchUpInside)
        settingsButton.addTarget(self,action:#selector(settingsTapped),for:.touchUpInside)
        view.addSubview(controls)
        controlTop=controls.topAnchor.constraint(equalTo:view.topAnchor,constant:12)
        controlTrailing=controls.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12)
        NSLayoutConstraint.activate([controlTop,controlTrailing])
        quickKeys.axis = .horizontal;quickKeys.spacing=8;quickKeys.distribution = .fillEqually
        quickKeys.backgroundColor=UIColor(white:0.055,alpha:0.9);quickKeys.layer.cornerRadius=18
        quickKeys.layer.borderWidth=0
        quickKeys.isLayoutMarginsRelativeArrangement=true
        quickKeys.directionalLayoutMargins=NSDirectionalEdgeInsets(top:4,leading:8,bottom:4,trailing:8)
        quickKeys.translatesAutoresizingMaskIntoConstraints=false
        for (index,key) in client.quickKeys.enumerated() {
            let name=key.rawValue,title=key.title
            let button=UIButton(type:.system);button.setTitle(title,for:.normal)
            button.accessibilityIdentifier="pad.key."+name;button.tag=index
            button.accessibilityLabel=key.accessibilityTitle
            button.titleLabel?.font = UIFontMetrics(forTextStyle:.body).scaledFont(for:.monospacedSystemFont(ofSize:16,weight:.medium),maximumPointSize:21)
            button.titleLabel?.adjustsFontSizeToFitWidth=true;button.titleLabel?.minimumScaleFactor=0.75
            button.backgroundColor = .clear;button.tintColor=UIColor(white:0.9,alpha:1)
            button.layer.cornerRadius=16
            button.addTarget(self,action:#selector(keyTapped(_:)),for:.touchUpInside)
            button.addTarget(self,action:#selector(keyPressed(_:)),for:.touchDown)
            button.addTarget(self,action:#selector(keyReleased(_:)),for:[.touchUpInside,.touchUpOutside,.touchCancel,.touchDragExit])
            keyButtons.append(button);quickKeys.addArrangedSubview(button)
        }
        microphoneButton.tintColor=UIColor(white:0.9,alpha:1)
        microphoneButton.backgroundColor=UIColor(white:0.18,alpha:1)
        microphoneButton.layer.cornerRadius=16;quickKeys.addArrangedSubview(microphoneButton)
        view.addSubview(quickKeys)
        keyRowWidth=quickKeys.widthAnchor.constraint(equalTo:view.safeAreaLayoutGuide.widthAnchor,constant:-32);keyRowWidth.priority = .defaultHigh
        rowWidth=quickKeys.widthAnchor.constraint(equalToConstant:60);rowWidth.isActive=false
        NSLayoutConstraint.activate([quickKeys.centerXAnchor.constraint(equalTo:view.safeAreaLayoutGuide.centerXAnchor),keyRowWidth,quickKeys.widthAnchor.constraint(lessThanOrEqualToConstant:380),quickKeys.heightAnchor.constraint(equalToConstant:52),quickKeys.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-16)])
        revealButton.translatesAutoresizingMaskIntoConstraints=false
        revealButton.tintColor=UIColor(white:0.65,alpha:1)
        revealButton.setImage(UIImage(systemName:"chevron.down",withConfiguration:UIImage.SymbolConfiguration(pointSize:12,weight:.semibold)),for:.normal)
        revealButton.accessibilityIdentifier="pad.revealControls"
        revealButton.addTarget(self,action:#selector(toggleControls),for:.touchUpInside)
        view.addSubview(revealButton)
        NSLayoutConstraint.activate([revealButton.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:8),revealButton.topAnchor.constraint(equalTo:controls.topAnchor),revealButton.widthAnchor.constraint(equalToConstant:44),revealButton.heightAnchor.constraint(equalToConstant:44)])
        client.$showQuickKeys.combineLatest(client.$showTopControls,client.$showMicrophone).sink{[weak self] _ in DispatchQueue.main.async{self?.updateVisibility()}}.store(in:&subscriptions)
        client.$quickKeys.sink{[weak self] keys in
            guard let self else{return}
            for (index,button) in self.keyButtons.enumerated(){let key=keys[index];self.configureKey(button,key:key)}
        }.store(in:&subscriptions)
        client.speech.objectWillChange.sink{[weak self] in DispatchQueue.main.async{self?.updateVoice()}}.store(in:&subscriptions)
        client.$ready.sink{[weak self] _ in DispatchQueue.main.async{self?.updateVoice()}}.store(in:&subscriptions)
        client.$showConnection.removeDuplicates().sink{[weak self] presented in DispatchQueue.main.async{
            guard let self else{return}
            if presented{self.chromeDismiss?.cancel()}else{self.updateVisibility()}
        }}.store(in:&subscriptions)
        updateVoice()
        client.$protected.removeDuplicates().sink{[weak self] protected in
            guard let self else{return}
            self.pad?.cancelForRotation()
            #if DEBUG
            let testOldValue=ProcessInfo.processInfo.arguments.contains("--ui-test-old-published")
            self.updateControls(protected:testOldValue ? nil:protected)
            #else
            self.updateControls(protected:protected)
            #endif
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures();self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }.store(in:&subscriptions)
        client.$landscape.removeDuplicates().sink{[weak self] landscape in self?.updateControls(landscape:landscape)}.store(in:&subscriptions)
        updateControls()
    }
    override var preferredScreenEdgesDeferringSystemGestures:UIRectEdge {client.protected ? .all:[]}
    override var prefersHomeIndicatorAutoHidden:Bool {client.protected}
    override func viewDidLayoutSubviews(){
        super.viewDidLayoutSubviews()
        let insets=view.window?.safeAreaInsets ?? view.safeAreaInsets
        controlTop.constant = max(12,insets.top+8)
        controlTrailing.constant = -max(12,insets.right+12)
    }
    private func updateControls(protected:Bool?=nil,landscape:Bool?=nil){
        let locked=protected ?? client.protected,horizontal=landscape ?? client.landscape
        lockButton.setImage(UIImage(systemName:locked ? "lock.fill":"lock.open"),for:.normal)
        lockButton.accessibilityLabel=PTText(locked ? "Hold to unlock trackpad":"Protect trackpad")
        lockButton.accessibilityHint=locked ? PTText("Hold for a moment to unlock. Settings and rotation remain available."):nil
        lockButton.accessibilityCustomActions=locked ? [UIAccessibilityCustomAction(name:PTText("Unlock trackpad"),target:self,selector:#selector(accessibilityUnlock))]:nil
        rotateButton.accessibilityLabel=PTText(horizontal ? "Rotate to portrait":"Rotate to landscape")
        settingsButton.accessibilityLabel=PTText("Trackpad settings")
    }
    @objc private func accessibilityUnlock()->Bool {if client.protected{client.toggleProtection()};return true}
    @objc private func lockTapped(){if !client.protected{client.toggleProtection()}}
    @objc private func unlockHeld(_ recognizer:UILongPressGestureRecognizer){if recognizer.state == .began,client.protected{client.toggleProtection()}}
    @objc private func rotateTapped(){pad?.cancelForRotation();client.toggleOrientation();armControlsDismiss()}
    private func configureKey(_ button:UIButton,key:PadQuickKey){
        button.setTitle(key == .backspace ? nil:key.title,for:.normal)
        button.setImage(key == .backspace ? UIImage(systemName:"delete.left",withConfiguration:UIImage.SymbolConfiguration(pointSize:18,weight:.regular)):nil,for:.normal)
        button.accessibilityLabel=PTText(key.accessibilityTitle);button.accessibilityIdentifier="pad.key."+key.rawValue
    }
    @objc private func keyPressed(_ button:UIButton){
        guard client.quickKeys.indices.contains(button.tag) else{return};let key=client.quickKeys[button.tag]
        if key.repeatable{pad?.cancelForRotation();client.beginKey(key)}
    }
    @objc private func keyReleased(_ button:UIButton){
        guard client.quickKeys.indices.contains(button.tag) else{return};client.endKey(client.quickKeys[button.tag]);armControlsDismiss()
    }
    @objc private func keyTapped(_ button:UIButton){
        guard client.ready else{client.showConnection=true;return}
        guard client.quickKeys.indices.contains(button.tag) else{return}
        if !client.quickKeys[button.tag].repeatable{pad?.cancelForRotation();client.sendKey(client.quickKeys[button.tag])}
    }
    private func updateVoice(){
        let speech=client.speech
        updateVisibility()
        microphoneButton.setImage(UIImage(systemName:speech.recording || speech.finishing ? "stop.fill":speech.preparing || speech.sending ? "ellipsis":speech.error != nil ? "exclamationmark.circle":"mic"),for:.normal)
        microphoneButton.backgroundColor=speech.recording ? UIColor(red:0.79,green:0.96,blue:0.36,alpha:1):UIColor(white:0.18,alpha:1)
        microphoneButton.tintColor=speech.recording ? UIColor(white:0.08,alpha:1):UIColor(white:0.9,alpha:1)
        microphoneButton.accessibilityLabel=PTText(speech.finishing ? "Retry stopping":speech.recording ? "Stop recording":speech.preparing ? "Cancel":"Start recording")
        microphoneButton.accessibilityValue=speech.status
        microphoneButton.isEnabled = !speech.sending || speech.recording || speech.finishing
        microphoneButton.alpha=microphoneButton.isEnabled ? 1:0.5
    }
    private func updateVisibility(){
        guard isViewLoaded else{return}
        let forceAll=revealingControls && !client.showQuickKeys && !client.showMicrophone && !client.showTopControls
        let keys = !controlsCollapsed && (client.showQuickKeys || forceAll)
        let mic = (!controlsCollapsed && (client.showMicrophone || forceAll)) || client.speech.busy
        controls.isHidden = controlsCollapsed || (!client.showTopControls && !revealingControls)
        controls.accessibilityElementsHidden=controls.isHidden
        for button in keyButtons{button.isHidden = !keys}
        microphoneButton.isHidden = !mic
        quickKeys.isHidden = !keys && !mic
        keyRowWidth.isActive=keys;rowWidth.isActive = !keys
        revealButton.isHidden=false
        let visible = !controls.isHidden || (!quickKeys.isHidden && !client.speech.busy)
        revealButton.accessibilityLabel=PTText(visible ? "Hide controls":"Show controls")
        revealButton.setImage(UIImage(systemName:visible ? "chevron.up":"chevron.down",withConfiguration:UIImage.SymbolConfiguration(pointSize:12,weight:.semibold)),for:.normal)
    }
    private func setControlsCollapsed(_ collapsed:Bool){
        controlsCollapsed=collapsed
        UIView.transition(with:view,duration:UIAccessibility.isReduceMotionEnabled ? 0:0.18,options:[.transitionCrossDissolve,.allowUserInteraction,.beginFromCurrentState]){self.updateVisibility()}
    }
    private func armControlsDismiss(){chromeDismiss?.cancel()}
    @objc private func toggleControls(){
        pad?.cancelForRotation();client.releaseInput()
        let visible = !controls.isHidden || (!quickKeys.isHidden && !client.speech.busy)
        revealingControls = !visible;setControlsCollapsed(visible)
        if !visible{armControlsDismiss()}else{chromeDismiss?.cancel()}
    }
    @objc private func dictationTapped(){pad?.cancelForRotation();client.releaseInput();client.speech.toggle(client:client)}
    @objc private func settingsTapped(){pad?.cancelForRotation();client.releaseInput();client.showConnection=true}

    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated);pad.becomeFirstResponder();armControlsDismiss()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-hidden"){client.showQuickKeys=false;client.showTopControls=false;client.showMicrophone=false;updateVisibility()}
        #endif
        client.landscape=view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        #if DEBUG
        if !controlsTestStarted,ProcessInfo.processInfo.arguments.contains("--ui-test-manualcontrols") {
            controlsTestStarted=true
            DispatchQueue.main.asyncAfter(deadline:.now()+2){[weak self] in self?.verifyManualControls(restore:false)}
        }
        if !controlsTestStarted,ProcessInfo.processInfo.arguments.contains("--ui-test-restorecontrols") {
            controlsTestStarted=true
            DispatchQueue.main.asyncAfter(deadline:.now()+2){[weak self] in self?.verifyManualControls(restore:true)}
        }
        if !controlsTestStarted,ProcessInfo.processInfo.arguments.contains("--ui-test-visibility") {
            controlsTestStarted=true
            DispatchQueue.main.asyncAfter(deadline:.now()+1){[weak self] in self?.verifyVisibility()}
        }
        if !controlsTestStarted,ProcessInfo.processInfo.arguments.contains("--ui-test-controls") {
            controlsTestStarted=true
            DispatchQueue.main.asyncAfter(deadline:.now()+3){[weak self] in self?.verifyControls()}
        }
        #endif
    }
    #if DEBUG
    private func verifyManualControls(restore:Bool){
        client.showQuickKeys=true;client.showTopControls=true;client.showMicrophone=true
        updateVisibility();view.layoutIfNeeded()
        if restore {
            var report:[String:Any]=["restoredCollapsed":controlsCollapsed && controls.isHidden && quickKeys.isHidden]
            toggleControls();view.layoutIfNeeded();report["canExpandAgain"] = !controls.isHidden && !quickKeys.isHidden
            if let data=try? JSONSerialization.data(withJSONObject:report){try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-ManualRestoreQA.json"))}
            return
        }
        controlsCollapsed=false;revealingControls=false;updateVisibility();armControlsDismiss()
        DispatchQueue.main.asyncAfter(deadline:.now()+7){[weak self] in
            guard let self else{return}
            var report:[String:Any]=["stillExpandedAfterSevenSeconds":!self.controls.isHidden && !self.quickKeys.isHidden]
            self.toggleControls();self.view.layoutIfNeeded()
            report["collapsedByButton"]=self.controls.isHidden && self.quickKeys.isHidden
            report["savedCollapsed"]=UserDefaults.standard.bool(forKey:"pad.controlsCollapsed")
            report["handleVisible"] = !self.revealButton.isHidden
            if let data=try? JSONSerialization.data(withJSONObject:report){try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-ManualControlsQA.json"))}
        }
    }
    private func verifyVisibility(){
        let saved=(client.showQuickKeys,client.showTopControls,client.showMicrophone)
        client.showQuickKeys=false;client.showTopControls=false;client.showMicrophone=false
        revealingControls=false;updateVisibility();view.layoutIfNeeded()
        var report:[String:Any]=["allHidden":controls.isHidden && quickKeys.isHidden,"restoreHandleVisible":!revealButton.isHidden,"surfaceCoverage":surfaceCoverage()]
        let point=revealButton.convert(CGPoint(x:22,y:22),to:view)
        let hit=view.hitTest(point,with:nil)
        report["restoreHandleTappable"]=hit === revealButton || hit?.isDescendant(of:revealButton)==true
        toggleControls();view.layoutIfNeeded()
        report["temporarilyRestored"] = !controls.isHidden && !quickKeys.isHidden && keyButtons.allSatisfy{!$0.isHidden}
        toggleControls();report["hiddenAgain"]=controls.isHidden && quickKeys.isHidden
        DispatchQueue.main.asyncAfter(deadline:.now()+4.5){[weak self] in
            guard let self else{return}
            self.client.showQuickKeys=saved.0;self.client.showTopControls=saved.1;self.client.showMicrophone=saved.2;self.updateVisibility()
            if let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys){try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-VisibilityQA.json"),options:.atomic)}
        }
    }
    private func controlHits()->[String:Any] {
        guard let window=view.window else{return ["error":"no window"]}
        var result=[String:Any]()
        for button in [lockButton,rotateButton,microphoneButton,settingsButton]+keyButtons {
            let frame=button.convert(button.bounds,to:window)
            var hits=0
            for x in [4.0,frame.width*0.25,frame.width*0.5,frame.width*0.75,frame.width-4] {for y in [4.0,frame.height*0.25,frame.height*0.5,frame.height*0.75,frame.height-4] {
                let actual=window.hitTest(CGPoint(x:frame.minX+x,y:frame.minY+y),with:nil)
                if actual === button || actual?.isDescendant(of:button)==true {hits+=1}
            }}
            result[button.accessibilityIdentifier ?? "button"]=["hits":hits,"total":25,"width":frame.width,"height":frame.height,"clearOfHomeIndicator":frame.maxY<=window.bounds.maxY-window.safeAreaInsets.bottom]
        }
        return result
    }
    private func surfaceCoverage()->Double {
        guard view.bounds.width>0,view.bounds.height>0 else{return 0}
        return pad.bounds.width*pad.bounds.height/(view.bounds.width*view.bounds.height)
    }
    private func verifyControls(){
        chromeDismiss?.cancel();controlsCollapsed=false;revealingControls=true;updateVisibility()
        var report:[String:Any]=["portrait":controlHits(),"portraitSurfaceCoverage":surfaceCoverage()]
        lockButton.sendActions(for:.touchUpInside)
        report["lockEnabled"]=client.protected;report["lockLabel"]=lockButton.accessibilityLabel==PTText("Hold to unlock trackpad");report["locked"]=controlHits()
        let before=view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        rotateButton.sendActions(for:.touchUpInside)
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5){[weak self] in
            guard let self else{return}
            report["rotationChanged"]=(self.view.window?.windowScene?.interfaceOrientation.isLandscape ?? false) != before
            report["landscape"]=self.controlHits();report["landscapeSurfaceCoverage"]=self.surfaceCoverage()
            self.settingsButton.sendActions(for:.touchUpInside)
            report["settingsAction"]=self.client.showConnection
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5){
                report["settingsPresented"]=self.view.window?.rootViewController?.presentedViewController != nil
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
                    try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-ControlQA.json"),options:.atomic)
                }
            }
        }
    }
    #endif
}
struct PadSurface:UIViewControllerRepresentable {
    let client:TrackpadClient
    func makeUIViewController(context:Context)->PadController { PadController(client:client) }
    func updateUIViewController(_ uiViewController:PadController,context:Context) {}
}
