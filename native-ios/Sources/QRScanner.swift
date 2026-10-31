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
    var completed=false
    let detected:(String)->Void
    let failed:(String)->Void
    init(detected:@escaping(String)->Void,failed:@escaping(String)->Void) { self.detected=detected;self.failed=failed;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                if allowed { self.configure() } else { self.failed(PTText("Allow camera access in Settings, or paste the Mac address.")) }
            }
        }
    }
    private func configure() {
        guard let camera=AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),session.canAddInput(input) else { failed(PTText("Camera is unavailable."));return }
        session.addInput(input)
        let output=AVCaptureMetadataOutput();guard session.canAddOutput(output) else { failed(PTText("Could not start QR scanning."));return }
        session.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
        let layer=AVCaptureVideoPreviewLayer(session:session);layer.videoGravity = .resizeAspectFill;view.layer.addSublayer(layer);preview=layer;viewDidLayoutSubviews()
        captureQueue.async { [weak self] in self?.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews();preview?.frame=view.bounds }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !completed,let value=metadataObjects.compactMap({($0 as? AVMetadataMachineReadableCodeObject)?.stringValue}).first else { return }
        completed=true;stop();detected(value)
    }
    func stop() { captureQueue.async { [weak self] in self?.session.stopRunning() } }
}
