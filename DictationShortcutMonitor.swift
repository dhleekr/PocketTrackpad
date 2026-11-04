import Cocoa
import ApplicationServices

/// Watches only previously connected applications and their dictation controls.
/// Value reads run off the input/UI thread. No global key or conversation logging.
@MainActor final class DictationShortcutMonitor {
    static let shared=DictationShortcutMonitor()
    private final class Entry {
        let pid:pid_t,bundle:String,launchDate:Date?
        var observer:AXObserver?,root:AXUIElement
        var fields=[AXUIElement](),valid=false,liveValues=false
        var probing=false,revision=0
        init(pid:pid_t,bundle:String,launchDate:Date?){self.pid=pid;self.bundle=bundle;self.launchDate=launchDate;root=AXUIElementCreateApplication(pid)}
    }
    private var entries=[String:Entry](),activation:NSObjectProtocol?,timer:Timer?
    private var readingPreferences=false,lastPreference:DictationProfiles.Profile?
    private init(){}
    func start(){
        guard activation==nil else{return}
        activation=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.attachKnownApps()}}
        timer=Timer.scheduledTimer(withTimeInterval:1.0,repeats:true){[weak self] _ in Task{@MainActor in self?.pollBoundFields();self?.pollPreferences()}}
        attachKnownApps()
    }
    private func attachKnownApps(){for bundle in DictationProfiles.configuredBundles(){if let entry=entry(bundle){probe(entry,discover:true)}}}
    private func entry(_ bundle:String)->Entry? {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else{return nil}
        if let old=entries[bundle],old.pid==app.processIdentifier,old.launchDate==app.launchDate{return old}
        if let old=entries.removeValue(forKey:bundle),let observer=old.observer{CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)}
        let item=Entry(pid:app.processIdentifier,bundle:bundle,launchDate:app.launchDate);entries[bundle]=item
        var observer:AXObserver?
        let callback:AXObserverCallback={_,element,notification,context in
            guard let context else{return};var pid:pid_t=0;AXUIElementGetPid(element,&pid)
            let monitor=Unmanaged<DictationShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
            let name=notification as String
            Task{@MainActor in monitor.changed(pid:pid,notification:name)}
        }
        if AXObserverCreate(item.pid,callback,&observer) == .success,let observer{
            item.observer=observer
            for name in [kAXWindowCreatedNotification,kAXFocusedWindowChangedNotification,kAXFocusedUIElementChangedNotification]{_ = AXObserverAddNotification(observer,item.root,name as CFString,Unmanaged.passUnretained(self).toOpaque())}
            CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
        }
        return item
    }
    func accept(_ profile:DictationProfiles.Profile,bundle:String){
        start()
        if profile.origin==DictationProfiles.codexSettingsOrigin{lastPreference=profile;return}
        guard let item=entry(bundle) else{return};item.valid=true;probe(item,discover:true)
    }
    private func pollPreferences(){
        let bundle="com.openai.codex"
        guard !readingPreferences,DictationProfiles.load(bundle:bundle)?.origin==DictationProfiles.codexSettingsOrigin else{return}
        readingPreferences=true
        Task{@MainActor [weak self] in
            let profile=await Task.detached(priority:.utility){CodexDictationPreference.read()}.value
            guard let self else{return};self.readingPreferences=false
            guard DictationProfiles.load(bundle:bundle)?.origin==DictationProfiles.codexSettingsOrigin else{return}
            if let profile{DictationProfiles.save(profile,bundle:bundle)}
            if profile != self.lastPreference{
                self.lastPreference=profile
                NotificationCenter.default.post(name:Notification.Name("PocketTrackpadDictationShortcutChanged"),object:bundle,userInfo:["available":profile != nil])
            }
        }
    }
    private func changed(pid:pid_t,notification:String){
        guard let item=entries.values.first(where:{$0.pid==pid}) else{return}
        if notification==kAXValueChangedNotification{item.valid=false;item.revision+=1}
        probe(item,discover:true)
    }
    private func pollBoundFields(){for item in entries.values where !item.fields.isEmpty{probe(item,discover:false)}}
    private func probe(_ item:Entry,discover:Bool){
        guard !item.probing,DictationProfiles.load(bundle:item.bundle)?.origin=="auto" else{return}
        item.probing=true
        let fields=item.fields,pid=item.pid,bundle=item.bundle,revision=item.revision
        Task{@MainActor [weak self,weak item] in
            let snapshot=await Task.detached(priority:.utility){
                discover ? DictationShortcutDiscovery.passive(pid:pid,bundle:bundle):DictationShortcutDiscovery.boundValues(fields,bundle:bundle)
            }.value
            guard let self,let item,self.entries[bundle] === item else{return};item.probing=false
            if item.revision != revision{self.probe(item,discover:true);return}
            guard NSRunningApplication.runningApplications(withBundleIdentifier:bundle).contains(where:{$0.processIdentifier==pid && $0.launchDate==item.launchDate}) else{item.valid=false;return}
            if let profile=snapshot.profile{
                let previous=DictationProfiles.load(bundle:bundle)
                let wasValid=item.valid
                DictationProfiles.save(profile,bundle:bundle);item.valid=true
                if previous != profile || !wasValid{NotificationCenter.default.post(name:Notification.Name("PocketTrackpadDictationShortcutChanged"),object:bundle,userInfo:["available":true])}
            }
            else if snapshot.settingsExposed{
                item.valid=false
                NotificationCenter.default.post(name:Notification.Name("PocketTrackpadDictationShortcutChanged"),object:bundle,userInfo:["available":false])
            }
            if discover,!snapshot.fields.isEmpty {
                item.fields=snapshot.fields;item.liveValues=false
                if let observer=item.observer {
                    for field in snapshot.fields {
                        let result=AXObserverAddNotification(observer,field,kAXValueChangedNotification as CFString,Unmanaged.passUnretained(self).toOpaque())
                        if result == .success || result == .notificationAlreadyRegistered {
                            let value=DictationShortcutDiscovery.boundValues([field],bundle:bundle)
                            if value.settingsExposed{item.liveValues=true}
                        }
                    }
                }
            }
        }
    }
    func current(bundle:String)async throws->DictationProfiles.Profile? {
        guard let saved=DictationProfiles.load(bundle:bundle) else{return nil}
        if saved.origin==DictationProfiles.codexSettingsOrigin{
            guard let fresh=await Task.detached(priority:.userInitiated,operation:{CodexDictationPreference.read()}).value else{throw DictationShortcutDiscovery.Failure.notAssigned}
            DictationProfiles.save(fresh,bundle:bundle);return fresh
        }
        guard saved.origin=="auto" else{return saved}
        start()
        if let item=entry(bundle),item.valid,item.liveValues {
            let fields=item.fields
            let live=await Task.detached(priority:.userInitiated){DictationShortcutDiscovery.boundValues(fields,bundle:bundle)}.value
            if let profile=live.profile{DictationProfiles.save(profile,bundle:bundle);return profile}
            if !live.settingsExposed,item.valid{return DictationProfiles.load(bundle:bundle)}
            item.valid=false
        }
        // New app process, missed notification support, or an observed change:
        // read the current value rather than emit a potentially obsolete key.
        let profile=try await DictationShortcutDiscovery.detect(bundle:bundle,restoreView:true)
        DictationProfiles.save(profile,bundle:bundle);accept(profile,bundle:bundle)
        return profile
    }
    func stop(){
        timer?.invalidate();timer=nil
        if let activation{NSWorkspace.shared.notificationCenter.removeObserver(activation)};activation=nil
        for item in entries.values{if let observer=item.observer{CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)}}
        entries.removeAll()
    }
}
