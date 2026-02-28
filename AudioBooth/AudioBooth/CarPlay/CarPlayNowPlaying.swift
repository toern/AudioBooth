@preconcurrency import CarPlay
import Combine
import Foundation

final class CarPlayNowPlaying: NSObject {
  private let interfaceController: CPInterfaceController
  private var cancellables = Set<AnyCancellable>()
  private let chapters: CarPlayChapters

  let template: CPNowPlayingTemplate

  init(interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    self.chapters = CarPlayChapters(interfaceController: interfaceController)
    template = CPNowPlayingTemplate.shared

    super.init()

    // Register as the now-playing template observer so CarPlay notifies us
    // when the user taps the "Up Next" or album-art buttons on the now-playing
    // screen. Without this, those taps are silently ignored.
    template.add(self)

    setupButtons()
    setupObserver()
  }

  private func setupButtons() {
    updateButtons()
  }

  private func updateButtons() {
    let hasChapters = PlayerManager.shared.current?.chapters?.chapters.isEmpty == false

    let previousChapterButton = CPNowPlayingImageButton(image: UIImage(systemName: "backward.end.fill")!) {
      [weak self] _ in
      self?.onPreviousChapterTapped()
    }

    let nextChapterButton = CPNowPlayingImageButton(image: UIImage(systemName: "forward.end.fill")!) { [weak self] _ in
      self?.onNextChapterTapped()
    }

    let playbackRateButton = CPNowPlayingPlaybackRateButton(handler: { [weak self] _ in
      self?.onPlaybackRateButtonTapped()
    })

    let chaptersButton = CPNowPlayingImageButton(image: UIImage(systemName: "list.bullet")!) { [weak self] _ in
      self?.onChaptersButtonTapped()
    }
    chaptersButton.isEnabled = hasChapters

    // Sleep timer button — mirrors the sleep-timer feature available in the
    // iOS full-screen player. Cycles through preset durations so the driver
    // can set a timer without looking at the screen.
    let sleepTimerButton = CPNowPlayingImageButton(image: UIImage(systemName: "moon.fill")!) { [weak self] _ in
      self?.onSleepTimerButtonTapped()
    }

    let buttons: [CPNowPlayingButton] = [
      previousChapterButton,
      playbackRateButton,
      sleepTimerButton,
      chaptersButton,
      nextChapterButton,
    ]

    template.updateNowPlayingButtons(buttons)
  }

  private func setupObserver() {
    PlayerManager.shared.$current
      .sink { [weak self] current in
        guard let self else { return }

        if let current {
          self.observePlayerChanges(for: current)
        } else {
          self.hideNowPlaying()
        }
      }
      .store(in: &cancellables)
  }

  private func observePlayerChanges(for player: BookPlayer.Model) {
    withObservationTracking {
      _ = player.chapters
    } onChange: { [weak self, weak player] in
      Task { @MainActor [weak self, weak player] in
        guard let self, let player else { return }
        self.updateButtons()
        self.observePlayerChanges(for: player)

        if let chapters = player.chapters {
          self.observeChapterChanges(for: player, chapters: chapters)
        }
      }
    }

    updateButtons()
  }

  private func observeChapterChanges(for player: BookPlayer.Model, chapters: ChapterPickerSheet.Model) {
    withObservationTracking {
      _ = chapters.currentIndex
    } onChange: { [weak self, weak player, weak chapters] in
      Task { @MainActor [weak self, weak player, weak chapters] in
        guard let self, let player, let chapters else { return }
        self.updateButtons()
        self.observeChapterChanges(for: player, chapters: chapters)
      }
    }
  }

  func showNowPlaying() {
    guard !interfaceController.templates.isEmpty else { return }

    if !interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) {
      interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
  }

  private func hideNowPlaying() {
    if interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) {
      interfaceController.popToRootTemplate(animated: true, completion: nil)
    }
  }

  private func onPreviousChapterTapped() {
    guard let current = PlayerManager.shared.current,
      let chapters = current.chapters
    else { return }

    chapters.onPreviousChapterTapped()
  }

  private func onNextChapterTapped() {
    guard let current = PlayerManager.shared.current,
      let chapters = current.chapters
    else { return }

    chapters.onNextChapterTapped()
  }

  private func onPlaybackRateButtonTapped() {
    guard let current = PlayerManager.shared.current else { return }

    let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    let currentSpeed = current.speed.playbackSpeed

    if let currentIndex = speeds.firstIndex(of: currentSpeed) {
      let nextIndex = (currentIndex + 1) % speeds.count
      current.speed.onSpeedChanged(speeds[nextIndex])
    } else {
      current.speed.onSpeedChanged(1.0)
    }
  }

  private func onChaptersButtonTapped() {
    guard let current = PlayerManager.shared.current else { return }
    chapters.show(for: current)
  }

  /// Toggles the sleep timer on or off. When no timer is active, starts a
  /// 15-minute preset. When a timer is already running, cancels it. This
  /// simple two-state toggle is suited to the limited CarPlay interaction model.
  private func onSleepTimerButtonTapped() {
    guard let current = PlayerManager.shared.current else { return }

    let timer = current.timer

    if timer.current != .none {
      // Timer is running — cancel it.
      timer.onOffSelected()
    } else {
      // No timer active — start a 15-minute preset (the shortest common option).
      // Uses the same onQuickTimerSelected(_:) method as the iOS timer sheet.
      timer.onQuickTimerSelected(15)
    }
  }
}

// MARK: - CPNowPlayingTemplateObserver
// Implementing this protocol lets CarPlay notify us when the user interacts
// with the "Up Next" or album-art buttons on the now-playing screen.
// Previously these taps were silently dropped because no observer was registered.

extension CarPlayNowPlaying: CPNowPlayingTemplateObserver {
  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    // Show the chapter list when the user taps "Up Next" — the closest
    // equivalent to a queue/chapter overview in an audiobook context.
    guard let current = PlayerManager.shared.current else { return }
    chapters.show(for: current)
  }

  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    // No-op for now — album/artist drill-down isn't applicable for audiobooks.
    // Implementing the method prevents a crash if CarPlay invokes it.
  }
}
