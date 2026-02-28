@preconcurrency import CarPlay
import AVFoundation
import Foundation
import Logging
import OSLog

public final class CarPlayDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var controller: CarPlayController?

  public func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController

    // Activate the audio session with the long-form-audio policy when CarPlay
    // connects. This tells the system we intend to play spoken-word content and
    // ensures proper prioritisation over navigation prompts and other transient
    // audio on the car's head unit.
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
      try audioSession.setActive(true)
    } catch {
      AppLogger.player.error("Failed to activate audio session for CarPlay: \(error)")
    }

    updateController()
  }

  public func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    // When CarPlay disconnects (cable removed, Bluetooth lost, etc.) we tear
    // down the controller. Playback pause is handled by the route-change
    // observer in BookPlayerModel (oldDeviceUnavailable) so we don't force-
    // pause here — that would interfere with users who continue listening on
    // the phone speaker after disconnecting the car.
    self.interfaceController = nil
    controller = nil
  }
}

private extension CarPlayDelegate {
  func updateController() {
    Task {
      guard let interfaceController else { return }

      if controller == nil {
        controller = try await CarPlayController(interfaceController: interfaceController)
      }
    }
  }
}
