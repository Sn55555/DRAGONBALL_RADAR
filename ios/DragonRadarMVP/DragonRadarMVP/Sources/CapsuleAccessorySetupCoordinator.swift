import AccessorySetupKit
import CoreBluetooth
import Observation
import UIKit

struct CapsuleAuthorizedAccessorySelection: Equatable {
    let eventID = UUID()
    let bluetoothIdentifier: UUID
    let displayName: String
}

enum CapsuleAccessorySetupPhase: Equatable {
    case idle
    case waitingForSession
    case removingAuthorization
    case presenting
    case pairing
    case authorized
    case failed(String)
}

@MainActor
@Observable
final class CapsuleAccessorySetupCoordinator {
    static let radarServiceUUID = CBUUID(string: "7d540100-f82d-4b2f-91c6-4f0f88aa5a11")

    private var session: ASAccessorySession?
    private var isActivated = false
    private var activationRequested = false
    private var shouldPresentWhenActivated = false
    private var isPickerPresented = false
    private var pendingSelection: CapsuleAuthorizedAccessorySelection?
    private var shouldRemoveAuthorizationWhenActivated = false
    private(set) var hasAttemptedAutomaticPresentation = false

    private(set) var phase: CapsuleAccessorySetupPhase = .idle
    private(set) var completedSelection: CapsuleAuthorizedAccessorySelection?
    var errorMessage: String?

    init() {}

    private func activateSessionIfNeeded() {
        guard !isActivated, !activationRequested else { return }
        activationRequested = true
        let session = ASAccessorySession()
        self.session = session
        session.activate(on: .main) { [weak self] event in
            self?.handle(event)
        }
    }

    func presentPicker() {
        guard !isPickerPresented else { return }
        guard isActivated else {
            shouldPresentWhenActivated = true
            phase = .waitingForSession
            activateSessionIfNeeded()
            return
        }
        presentActivatedPicker()
    }

    func presentPickerAutomatically() {
        guard !hasAttemptedAutomaticPresentation else { return }
        hasAttemptedAutomaticPresentation = true
        presentPicker()
    }

    func reconnectAuthorizedAccessory() {
        guard let selection = completedSelection else {
            presentPicker()
            return
        }
        publish(
            CapsuleAuthorizedAccessorySelection(
                bluetoothIdentifier: selection.bluetoothIdentifier,
                displayName: selection.displayName
            )
        )
    }

    func removeAuthorizationAndPresentPicker() {
        guard !isPickerPresented else { return }
        guard isActivated else {
            shouldRemoveAuthorizationWhenActivated = true
            phase = .waitingForSession
            activateSessionIfNeeded()
            return
        }
        removeCurrentAuthorizationAndPresentPicker()
    }

    func clearError() {
        errorMessage = nil
        if case .failed = phase {
            phase = .idle
        }
    }

    private func presentActivatedPicker() {
        guard let session else {
            fail("系统配件会话未启动")
            return
        }
        guard let productImage = UIImage(named: "CapsuleRadarSystemPickerProduct") else {
            fail("缺少 Capsule Radar 系统配件图片")
            return
        }

        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = Self.radarServiceUUID
        descriptor.bluetoothNameSubstring = "CapsuleRadar"
        descriptor.bluetoothRange = .immediate
        descriptor.supportedOptions = [.bluetoothPairingLE]

        let item = ASPickerDisplayItem(
            name: "Capsule Radar",
            productImage: productImage,
            descriptor: descriptor
        )
        item.setupOptions = [.finishInApp]

        pendingSelection = nil
        phase = .presenting
        session.showPicker(for: [item]) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.fail("系统配件设置失败 · \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            activationRequested = false
            if shouldRemoveAuthorizationWhenActivated {
                shouldRemoveAuthorizationWhenActivated = false
                removeCurrentAuthorizationAndPresentPicker()
                return
            }
            if let accessory = session?.accessories.first(where: { $0.bluetoothIdentifier != nil }),
               let identifier = accessory.bluetoothIdentifier {
                shouldPresentWhenActivated = false
                publish(
                    CapsuleAuthorizedAccessorySelection(
                        bluetoothIdentifier: identifier,
                        displayName: accessory.displayName
                    )
                )
            } else if shouldPresentWhenActivated {
                shouldPresentWhenActivated = false
                presentActivatedPicker()
            } else {
                phase = .idle
            }

        case .pickerDidPresent:
            isPickerPresented = true
            phase = .presenting

        case .pickerSetupPairing:
            phase = .pairing

        case .accessoryAdded, .accessoryChanged:
            guard
                let accessory = event.accessory,
                let identifier = accessory.bluetoothIdentifier
            else { return }
            let selection = CapsuleAuthorizedAccessorySelection(
                bluetoothIdentifier: identifier,
                displayName: accessory.displayName
            )
            pendingSelection = selection
            if !isPickerPresented {
                publish(selection)
            }

        case .pickerDidDismiss:
            isPickerPresented = false
            if let pendingSelection {
                publish(pendingSelection)
            } else if case .failed = phase {
                break
            } else {
                phase = .idle
            }

        case .pickerSetupFailed:
            fail(event.error.map {
                "系统蓝牙配对失败 · \($0.localizedDescription)"
            } ?? "系统蓝牙配对失败，请确认雷达已开机并靠近 iPhone")

        case .invalidated:
            isActivated = false
            activationRequested = false
            fail("系统配件设置会话已失效，请重新打开 App")

        case .accessoryRemoved:
            guard let removedIdentifier = event.accessory?.bluetoothIdentifier else { return }
            if completedSelection?.bluetoothIdentifier == removedIdentifier {
                completedSelection = nil
            }

        case .unknown, .migrationComplete, .accessoryDiscovered,
             .pickerSetupBridging, .pickerSetupRename:
            break

        @unknown default:
            break
        }
    }

    private func publish(_ selection: CapsuleAuthorizedAccessorySelection) {
        pendingSelection = nil
        completedSelection = selection
        phase = .authorized
    }

    private func removeCurrentAuthorizationAndPresentPicker() {
        guard let session else {
            fail("系统配件会话未启动")
            return
        }
        let selectedIdentifier = completedSelection?.bluetoothIdentifier
        let accessory = session.accessories.first(where: {
            guard let identifier = $0.bluetoothIdentifier else { return false }
            return selectedIdentifier == nil || identifier == selectedIdentifier
        })

        guard let accessory else {
            completedSelection = nil
            pendingSelection = nil
            presentActivatedPicker()
            return
        }

        phase = .removingAuthorization
        session.removeAccessory(accessory) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.fail("无法清除 iPhone 旧配件授权 · \(error.localizedDescription)")
                    return
                }
                self.completedSelection = nil
                self.pendingSelection = nil
                self.presentActivatedPicker()
            }
        }
    }

    private func fail(_ message: String) {
        shouldRemoveAuthorizationWhenActivated = false
        shouldPresentWhenActivated = false
        isPickerPresented = false
        pendingSelection = nil
        phase = .failed(message)
        errorMessage = message
    }
}
