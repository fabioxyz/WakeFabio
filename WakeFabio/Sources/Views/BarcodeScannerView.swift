import SwiftUI
import AVFoundation
import AudioToolbox

public enum ScannerMode {
    case register(onCodeScanned: (String) -> Void)
    case validate(targetCode: String, onCodeMatched: () -> Void)
    case test(targetCode: String, onDismiss: () -> Void)
}

public struct BarcodeScannerContainerView: View {
    let mode: ScannerMode
    @Environment(\.presentationMode) var presentationMode
    
    @State private var cameraPermissionStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var feedbackText: String = ""
    @State private var isMismatch: Bool = false
    
    public init(mode: ScannerMode) {
        self.mode = mode
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch cameraPermissionStatus {
            case .authorized:
                activeScannerView
            case .notDetermined:
                requestPermissionView
            case .denied, .restricted:
                permissionDeniedView
            @unknown default:
                permissionDeniedView
            }
        }
        .onAppear {
            checkCameraPermission()
        }
    }
    
    private var activeScannerView: some View {
        ZStack {
            ScannerRepresentable(mode: mode, onMismatch: { detected in
                feedbackText = "Código incorreto (\(detected.prefix(12))...). Escaneie o registado!"
                isMismatch = true
                AudioAlarmManager.shared.playFailureChime()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    isMismatch = false
                    feedbackText = ""
                }
            })
            .ignoresSafeArea()
            
            // Overlay visual da mira de leitura
            VStack {
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .padding()
                    }
                    Spacer()
                }
                
                Spacer()
                
                // Retângulo da mira
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isMismatch ? Color.red : Color.green, lineWidth: 3)
                        .frame(width: 260, height: 260)
                    
                    Rectangle()
                        .fill(isMismatch ? Color.red.opacity(0.15) : Color.green.opacity(0.1))
                        .frame(width: 250, height: 250)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    switch mode {
                    case .register:
                        Text("Aponte para o QR Code ou Código de Barras que deseja registar")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    case .validate(let target, _):
                        Text("Aponte para o código registado para desligar")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Referência: \(target)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    case .test(let target, _):
                        Text("Modo Teste: Verificando leitura de: \(target)")
                            .font(.subheadline)
                            .foregroundColor(.yellow)
                    }
                    
                    if !feedbackText.isEmpty {
                        Text(feedbackText)
                            .font(.footnote)
                            .bold()
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
    
    private var requestPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Acesso à Câmara Necessário")
                .font(.title2)
                .bold()
                .foregroundColor(.white)
            Text("O WakeFabio precisa da câmara para ler o seu Código QR ou de Barras de despertar.")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)
            
            Button("Permitir Acesso à Câmara") {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        self.cameraPermissionStatus = granted ? .authorized : .denied
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 60))
                .foregroundColor(.red)
            Text("Acesso à Câmara Bloqueado")
                .font(.title2)
                .bold()
                .foregroundColor(.white)
            Text("Para usar a missão de Código QR/Barras, autorize a câmara nas Definições do iOS.")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)
            
            Button("Abrir Definições do iOS") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("Cancelar") {
                presentationMode.wrappedValue.dismiss()
            }
            .foregroundColor(.white)
            .padding(.top, 10)
        }
        .padding()
    }
    
    private func checkCameraPermission() {
        self.cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }
}

// MARK: - Representable de AVCaptureSession com Gate Único de Callback

struct ScannerRepresentable: UIViewControllerRepresentable {
    let mode: ScannerMode
    let onMismatch: (String) -> Void
    
    func makeUIViewController(context: Context) -> ScannerSessionViewController {
        let controller = ScannerSessionViewController()
        controller.mode = mode
        controller.onMismatch = onMismatch
        return controller
    }
    
    func updateUIViewController(_ uiViewController: ScannerSessionViewController, context: Context) {}
}

final class ScannerSessionViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var mode: ScannerMode?
    var onMismatch: ((String) -> Void)?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasHandledCallback: Bool = false
    private let sessionQueue = DispatchQueue(label: "com.wakefabio.scannerQueue")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }
    
    deinit {
        stopSession()
    }
    
    private func setupCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let session = AVCaptureSession()
            guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
                print("[Scanner] Câmara não disponível no hardware (ex: Simulador)")
                return
            }
            
            do {
                let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                } else {
                    return
                }
                
                let metadataOutput = AVCaptureMetadataOutput()
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    // Suporte a QR Code e códigos de barras comuns
                    metadataOutput.metadataObjectTypes = [.qr, .ean8, .ean13, .code128, .code39, .upce]
                } else {
                    return
                }
                
                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: session)
                    preview.frame = self.view.layer.bounds
                    preview.videoGravity = .resizeAspectFill
                    self.view.layer.addSublayer(preview)
                    self.previewLayer = preview
                }
                
                session.startRunning()
                self.captureSession = session
            } catch {
                print("[Scanner] Erro ao inicializar captura: \(error)")
            }
        }
    }
    
    private func stopSession() {
        sessionQueue.async { [weak self] in
            if self?.captureSession?.isRunning == true {
                self?.captureSession?.stopRunning()
            }
            self?.captureSession = nil
        }
    }
    
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasHandledCallback else { return }
        
        guard let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let scannedString = readableObject.stringValue,
              !scannedString.isEmpty else { return }
        
        let trimmed = scannedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentMode = mode else { return }
        
        switch currentMode {
        case .register(let onScanned):
            hasHandledCallback = true
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            AudioAlarmManager.shared.playSuccessChime()
            stopSession()
            DispatchQueue.main.async {
                onScanned(trimmed)
            }
            
        case .validate(let target, let onMatched):
            if trimmed == target.trimmingCharacters(in: .whitespacesAndNewlines) {
                hasHandledCallback = true
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                AudioAlarmManager.shared.playSuccessChime()
                stopSession()
                DispatchQueue.main.async {
                    onMatched()
                }
            } else {
                onMismatch?(trimmed)
            }
            
        case .test(let target, let onDismiss):
            if trimmed == target.trimmingCharacters(in: .whitespacesAndNewlines) {
                hasHandledCallback = true
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                AudioAlarmManager.shared.playSuccessChime()
                stopSession()
                DispatchQueue.main.async {
                    onDismiss()
                }
            } else {
                onMismatch?(trimmed)
            }
        }
    }
}
