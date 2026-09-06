import CoreBluetooth

/// Created only by the Permissions page's explicit authorization action.
/// No device scan or connection is needed to request Bluetooth access.
@MainActor
final class BluetoothPermissionRequest: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    var onAuthorizationChanged: (() -> Void)?

    func request() {
        guard manager == nil else { return }
        manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationChanged?()
        }
    }
}
