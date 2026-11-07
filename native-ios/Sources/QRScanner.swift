import AVFoundation
import SwiftUI

struct QRScanner:UIViewControllerRepresentable {
    let detected:(String)->Void
    let failed:(String)->Void
    func makeUIViewController(context:Context)->ScanController { ScanController(detected:detected,failed:failed) }
    func updateUIViewController(_ uiViewController:ScanController,context:Context) {}
    static func dismantleUIViewController(_ uiViewController:ScanController,coordinator:()) { uiViewController.stop() }
}
final class ScanController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    let session=AVCaptureSession()
    let captureQueue=DispatchQueue(label:"local.pockettrackpad.qr")
    var preview:AVCaptureVideoPreviewLayer?
    private var camera:AVCaptureDevice?
    private var zoom=CGFloat(1),pinchStart=CGFloat(1),maxZoom=CGFloat(1)
    private let zoomBadge=UIVisualEffectView(effect:UIBlurEffect(style:.systemUltraThinMaterialDark))
    private let zoomLabel=UILabel()
    private var hideZoom:DispatchWorkItem?
    private var stopped=false
    var completed=false
    let detected:(String)->Void
    let failed:(String)->Void
    init(detected:@escaping(String)->Void,failed:@escaping(String)->Void) { self.detected=detected;self.failed=failed;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        let pinch=UIPinchGestureRecognizer(target:self,action:#selector(pinched(_:)))
        view.addGestureRecognizer(pinch)
        view.isAccessibilityElement=true;view.accessibilityLabel=PTText("Scan Mac QR")
        view.accessibilityCustomActions=[
            UIAccessibilityCustomAction(name:PTText("Zoom in"),target:self,selector:#selector(accessibleZoomIn)),
            UIAccessibilityCustomAction(name:PTText("Zoom out"),target:self,selector:#selector(accessibleZoomOut))
        ]
        zoomBadge.translatesAutoresizingMaskIntoConstraints=false
        zoomBadge.layer.cornerRadius=18;zoomBadge.clipsToBounds=true
        zoomBadge.alpha=0;zoomBadge.isUserInteractionEnabled=false;zoomBadge.accessibilityElementsHidden=true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize:15,weight:.semibold)
        zoomLabel.textColor = .white;zoomLabel.textAlignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints=false
        zoomBadge.contentView.addSubview(zoomLabel);view.addSubview(zoomBadge)
        NSLayoutConstraint.activate([
            zoomBadge.centerXAnchor.constraint(equalTo:view.centerXAnchor),
            zoomBadge.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-24),
            zoomLabel.leadingAnchor.constraint(equalTo:zoomBadge.contentView.leadingAnchor,constant:14),
            zoomLabel.trailingAnchor.constraint(equalTo:zoomBadge.contentView.trailingAnchor,constant:-14),
            zoomLabel.topAnchor.constraint(equalTo:zoomBadge.contentView.topAnchor,constant:9),
            zoomLabel.bottomAnchor.constraint(equalTo:zoomBadge.contentView.bottomAnchor,constant:-9)
        ])
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self,!self.stopped else { return }
                if allowed { self.configure() } else { self.failed(PTText("Allow camera access in Settings, or paste the Mac address.")) }
            }
        }
    }
    private func configure() {
        guard !stopped else{return}
        guard let camera=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) ?? AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),session.canAddInput(input) else { failed(PTText("Camera is unavailable."));return }
        self.camera=camera;maxZoom=min(8,camera.maxAvailableVideoZoomFactor)
        session.addInput(input)
        let output=AVCaptureMetadataOutput();guard session.canAddOutput(output) else { failed(PTText("Could not start QR scanning."));return }
        session.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
        let layer=AVCaptureVideoPreviewLayer(session:session);layer.videoGravity = .resizeAspectFill;view.layer.insertSublayer(layer,at:0);preview=layer;viewDidLayoutSubviews()
        captureQueue.async { [weak self] in self?.session.startRunning() }
    }
    @objc private func accessibleZoomIn()->Bool{setZoom(zoom+0.5);return true}
    @objc private func accessibleZoomOut()->Bool{setZoom(zoom-0.5);return true}
    @objc private func pinched(_ gesture:UIPinchGestureRecognizer){
        if gesture.state == .began{pinchStart=camera?.videoZoomFactor ?? zoom}
        if gesture.state == .began || gesture.state == .changed{setZoom(pinchStart*gesture.scale)}
    }
    private func showZoom(){
        zoomLabel.text=String(format:"%.1f×",Double(zoom))
        view.accessibilityValue=PTText("Camera zoom")+" "+(zoomLabel.text ?? "")
        hideZoom?.cancel();zoomBadge.layer.removeAllAnimations();zoomBadge.alpha=1
        let hide=DispatchWorkItem{[weak self] in
            guard let self,!self.stopped else{return}
            UIView.animate(withDuration:0.2){self.zoomBadge.alpha=0}
        }
        hideZoom=hide;DispatchQueue.main.asyncAfter(deadline:.now()+0.9,execute:hide)
    }
    private func setZoom(_ requested:CGFloat){
        guard !stopped,!completed,let camera,requested.isFinite else{return}
        zoom=min(maxZoom,max(1,requested));showZoom()
        let target=zoom
        captureQueue.async {
            do {
                try camera.lockForConfiguration();defer{camera.unlockForConfiguration()}
                camera.cancelVideoZoomRamp()
                let supported=min(camera.maxAvailableVideoZoomFactor,max(camera.minAvailableVideoZoomFactor,target))
                camera.videoZoomFactor=supported
            }catch{
                DispatchQueue.main.async{[weak self] in
                    self?.zoom=camera.videoZoomFactor;self?.showZoom()
                }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews();preview?.frame=view.bounds }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !completed,let value=metadataObjects.compactMap({($0 as? AVMetadataMachineReadableCodeObject)?.stringValue}).first else { return }
        completed=true;stop();detected(value)
    }
    func stop() { stopped=true;hideZoom?.cancel();let session=self.session;captureQueue.async {session.stopRunning()} }
}
