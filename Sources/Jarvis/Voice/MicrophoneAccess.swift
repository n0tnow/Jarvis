import AVFoundation

/// The microphone permission as macOS reports it. This is the ONLY place that asks the system (and the only source file that may
/// name the capture-authorization API — `verify.sh` allows exactly this file). Nothing is requested at launch, in tests, or by
/// polling: `request()` is called when the user holds Push-to-Talk for the first time.
@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    var status: MicrophonePermission { get }
    func request() async -> MicrophonePermission
}

@MainActor
final class SystemMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func request() async -> MicrophonePermission {
        guard status == .notDetermined else { return status }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return status
    }
}
