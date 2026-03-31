# CarPlay Support Analysis — March 2026

## Executive Summary

This report compares the current `main` branch CarPlay implementation with two
fork branches that were created to address CarPlay deficiencies:

| Branch | Status | Outcome |
|--------|--------|---------|
| `feat/carplay-pause-on-mute` | Abandoned (no code added) | Branch diverged from main on 2026-02-06 and was never implemented. Main has since advanced significantly. |
| `copilot/fix-carplay-audio-issues` | Implemented but **not merged** | 6 concrete fixes were implemented and documented, none of which have been merged into `main`. |

**Bottom line:** `main` has improved CarPlay substantially (podcast support,
offline-update fix, metadata sync, iOS 26 home improvements), but 5 of the 6
fixes proposed in `copilot/fix-carplay-audio-issues` are still missing.

---

## Branch-by-Branch Analysis

### `feat/carplay-pause-on-mute`

- **Created:** 2026-02-06 (at commit `452c3db`)
- **Last commit:** `452c3db Make watch context update more reliable`
- **Unique CarPlay changes:** None — the branch was created with the intention
  of adding mute-detection / pause-on-mute, but no code was ever committed.
- **Relationship to `main`:** Entirely behind. `main` is the superset;
  this branch is a strict ancestor of `main` with no diverging commits.
- **Verdict:** Can be safely deleted. The mute-pause behaviour it intended
  was partially addressed in `main` via the `handleVolumeChange` observer
  (pauses when software volume drops to 0).

---

### `copilot/fix-carplay-audio-issues`

- **Created:** 2026-02-28 (branched from commit `c89100f`)
- **Unique commits:** 4 (initial plan, implementation, docs, code-review fix-up)
- **Contains a detailed analysis document:** `docs/CARPLAY_ANALYSIS.md`
- **Relationship to `main`:** 4 commits ahead of its divergence point;
  `main` has since advanced ~25 commits beyond the divergence point.
  **None of the 6 fixes from this branch have been merged into `main`.**
- **Verdict:** The implementation is sound, but a rebase onto current `main`
  is required before merging, since `main` has changed substantially.

---

## What Main Has Already Fixed

The following CarPlay improvements were shipped in `main` after the fork
branches were created:

| Commit | Improvement |
|--------|-------------|
| `cad9da3` | Fix play next when pausing at end of book |
| `9511d72` | Revamp Watch audio player |
| `823cb8f` | Improve CarPlay home for iOS 26 (image rows, personalized sections) |
| `c7ea1b8` | Add podcasts and episodes support to CarPlay |
| `2ffd627` | Unify playback speed across CarPlay and app |
| `214e394` | Fix Now Playing metadata sync in CarPlay (#160) |
| `b2910c1` | Fix Now Playing metadata for Bluetooth/USB car displays (#181) |
| `7ddc6b0` | Fix CarPlay offline tab not updating (#169) |

**Mute handling** (`handleVolumeChange` in `BookPlayerModel.swift`) is also
present in `main`:

```swift
private func handleVolumeChange(from old: Float, to new: Float) {
  if new == 0 && old > 0 {
    // pause when volume drops to zero
    interruptionBeganAt = isPlaying ? Date() : nil
    player?.pause()
  } else if new > 0 && old == 0, let beganAt = interruptionBeganAt {
    if Date().timeIntervalSince(beganAt) < 60 * 5 {
      // resume when volume is restored within 5 minutes
      applySmartRewind(reason: .onInterruption)
      player?.resume()
    }
    interruptionBeganAt = nil
  }
}
```

**Offline auto-play** (`CarPlayOffline.swift`) is also working correctly in
`main` — both `onBookSelected` and `onEpisodeSelected` call
`PlayerManager.shared.play()` before `nowPlaying?.showNowPlaying()`.

---

## What Is Still Missing

The following items from `copilot/fix-carplay-audio-issues` are **not present**
in `main` and represent real gaps in CarPlay behaviour.

---

### ❌ Issue 1 — Audio Route Change Handling (HIGH)

**Symptom:** When CarPlay is disconnected (cable removed, Bluetooth lost),
headphones are unplugged, or an AirPlay connection drops, playback continues
through the device's built-in speaker. The user is surprised by audio leaking
out of their phone.

**Root cause:** `BookPlayerModel` has no observer for
`AVAudioSession.routeChangeNotification`. The existing interruption handling
only covers phone calls and Siri; it does not cover hardware route changes.

**What `copilot/fix-carplay-audio-issues` added:**

```swift
// BookPlayerModel.setupPlayerObservers()
NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
  .receive(on: DispatchQueue.main)
  .sink { [weak self] notification in
    self?.handleRouteChange(notification)
  }
  .store(in: &cancellables)
```

```swift
private func handleRouteChange(_ notification: Notification) {
  guard let reason = /* extract RouteChangeReason */ else { return }
  switch reason {
  case .oldDeviceUnavailable:
    // Lost CarPlay/Bluetooth/headphones → pause
    if hadExternalOutput && isPlaying { player?.pause() }
  case .newDeviceAvailable:
    // New output appeared → resume if recently paused
    if let beganAt = interruptionBeganAt, Date().timeIntervalSince(beganAt) < 300 {
      applySmartRewind(reason: .onInterruption)
      player?.play()
    }
  default: break
  }
}
```

---

### ❌ Issue 2 — Secondary Audio Silence Hint (HIGH)

**Symptom:** When the car's navigation system plays a turn-by-turn voice
prompt (or Siri speaks), the audiobook and navigation audio overlap. The user
cannot hear either clearly.

**Root cause:** `BookPlayerModel` does not observe
`AVAudioSession.silenceSecondaryAudioHintNotification`. Using `.spokenAudio`
mode (as AudioBooth does) makes the app eligible to be silenced by the system,
but the app must explicitly respond to the hint.

**What `copilot/fix-carplay-audio-issues` added:**

```swift
// BookPlayerModel.setupPlayerObservers()
NotificationCenter.default.publisher(for: AVAudioSession.silenceSecondaryAudioHintNotification)
  .receive(on: DispatchQueue.main)
  .sink { [weak self] notification in
    self?.handleSilenceSecondaryAudioHint(notification)
  }
  .store(in: &cancellables)
```

```swift
private func handleSilenceSecondaryAudioHint(_ notification: Notification) {
  switch type {
  case .begin:
    if isPlaying { interruptionBeganAt = Date(); player?.pause() }
  case .end:
    if let beganAt = interruptionBeganAt, Date().timeIntervalSince(beganAt) < 300 {
      applySmartRewind(reason: .onInterruption)
      player?.play()
    }
    interruptionBeganAt = nil
  }
}
```

---

### ❌ Issue 3 — CPNowPlayingTemplateObserver Not Registered (MEDIUM)

**Symptom:** Tapping the **Up Next** button on the CarPlay Now Playing screen
does nothing. No feedback is given to the user.

**Root cause:** `CarPlayNowPlaying` never calls `template.add(self)` and does
not conform to `CPNowPlayingTemplateObserver`.

**What `copilot/fix-carplay-audio-issues` added:**

```swift
// CarPlayNowPlaying.init()
template.add(self) // register as observer

// New extension:
extension CarPlayNowPlaying: CPNowPlayingTemplateObserver {
  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    guard let current = PlayerManager.shared.current else { return }
    chapters.show(for: current)
  }
  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    // no-op — prevents silent crash if CarPlay invokes the method
  }
}
```

---

### ❌ Issue 4 — No Sleep Timer in CarPlay (MEDIUM)

**Symptom:** Drivers who use AudioBooth's sleep timer have no way to activate
it from CarPlay. The iOS player has a full sleep-timer sheet, but CarPlay
exposes no equivalent control.

**Root cause:** `CarPlayNowPlaying.updateButtons()` does not include a sleep
timer button.

**What `copilot/fix-carplay-audio-issues` added:**

```swift
// CarPlayNowPlaying.updateButtons()
let sleepTimerButton = CPNowPlayingImageButton(image: UIImage(systemName: "moon.fill")!) { [weak self] _ in
  self?.onSleepTimerButtonTapped()
}
// Added to the buttons array alongside chapter and rate buttons

private func onSleepTimerButtonTapped() {
  guard let current = PlayerManager.shared.current else { return }
  let timer = current.timer
  if timer.current != .none {
    timer.onOffSelected()          // cancel running timer
  } else {
    timer.onQuickTimerSelected(15) // start 15-min preset
  }
}
```

---

### ❌ Issue 5 — Audio Session Not Configured on CarPlay Connect (LOW)

**Symptom:** Connecting CarPlay when no book is loaded may result in delayed
or incorrect audio routing when playback eventually starts, because the audio
session has not yet been configured for long-form spoken-word content.

**Root cause:** `BookPlayerModel` configures the audio session when a book
starts playing. If CarPlay connects first (before any playback), the session
may not have the `.longFormAudio` policy set.

**What `copilot/fix-carplay-audio-issues` added:**

```swift
// CarPlayDelegate.templateApplicationScene(_:didConnect:)
do {
  let audioSession = AVAudioSession.sharedInstance()
  try audioSession.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
  try audioSession.setActive(true)
} catch {
  AppLogger.player.error("Failed to activate audio session for CarPlay: \(error)")
}
```

---

## Comparison Table

| # | Issue | `feat/carplay-pause-on-mute` | `copilot/fix-carplay-audio-issues` | `main` (current) | Severity |
|---|-------|:--:|:--:|:--:|:--|
| 1 | Pause on audio route loss (CarPlay disconnect, BT loss, headphones) | ❌ Not implemented | ✅ Implemented | ❌ Missing | **High** |
| 2 | Pause for secondary audio (navigation prompts, Siri) | ❌ Not implemented | ✅ Implemented | ❌ Missing | **High** |
| 3 | `CPNowPlayingTemplateObserver` / Up Next button | ❌ Not implemented | ✅ Implemented | ❌ Missing | Medium |
| 4 | Sleep timer button in CarPlay | ❌ Not implemented | ✅ Implemented | ❌ Missing | Medium |
| 5 | Audio session activation on CarPlay connect | ❌ Not implemented | ✅ Implemented | ❌ Missing | Low |
| 6 | Offline book/episode auto-play | ❌ Not implemented | ✅ Fixed | ✅ Already fixed | — |
| 7 | Pause when software volume → 0 (mute) | ❌ Not implemented | ✅ Already present at time of analysis | ✅ Present | — |
| 8 | Podcast support in CarPlay | ❌ Not implemented | N/A (not in scope) | ✅ Added | — |
| 9 | CarPlay home for iOS 26 | ❌ Not implemented | N/A | ✅ Added | — |
| 10 | Now Playing metadata sync for BT/USB | ❌ Not implemented | N/A | ✅ Fixed | — |

---

## Action Plan

### Priority 1 — Merge or rebase `copilot/fix-carplay-audio-issues` into `main`

The five missing items can all be resolved by rebasing the
`copilot/fix-carplay-audio-issues` branch onto the current `main` and merging.
The implementation is already reviewed and documented.

**Steps:**

```sh
git checkout copilot/fix-carplay-audio-issues
git rebase origin/main
# resolve any conflicts (the main changes are unrelated to the changed files)
git push --force-with-lease origin copilot/fix-carplay-audio-issues
# then open a PR from copilot/fix-carplay-audio-issues → main
```

**Files that need conflict review after rebase:**

| File | Likely conflict area |
|------|---------------------|
| `BookPlayerModel.swift` | `setupPlayerObservers()` — new observers added near the volume KVO block |
| `CarPlayNowPlaying.swift` | `updateButtons()` — sleep timer button insertion |
| `CarPlayDelegate.swift` | `didConnect` — audio session activation block |

### Priority 2 — Delete `feat/carplay-pause-on-mute`

This branch is entirely behind `main` (strict ancestor), contains no unique
CarPlay code, and has been superseded by the volume-change observer already in
`main`. It can be safely deleted.

```sh
git push origin --delete feat/carplay-pause-on-mute
```

### Priority 3 — Add Manual Test Cases

The CarPlay fixes cannot be unit-tested in isolation (they depend on hardware
notifications from `AVAudioSession`). Recommended manual test cases:

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| Route loss — CarPlay cable | Play book → unplug Lightning/USB-C from car | Playback pauses immediately |
| Route loss — Bluetooth | Play book → turn off car Bluetooth | Playback pauses |
| Route reconnect — resume | After route loss → reconnect within 5 min | Playback resumes with smart rewind |
| Route reconnect — no resume | After route loss → reconnect after 5+ min | Playback stays paused |
| Navigation prompt overlap | Play book → trigger car navigation voice | Book pauses; nav voice plays cleanly; book resumes |
| Up Next button | CarPlay → Now Playing → tap Up Next | Chapter list appears |
| Sleep timer — start | CarPlay → Now Playing → tap moon button | 15-min timer starts |
| Sleep timer — cancel | While timer running → tap moon button | Timer cancelled |
| CarPlay connect (no playback) | Connect CarPlay before starting any book | No crash; audio session configured silently |

---

## Files to Change (when implementing the action plan)

| File | Change | Issue # |
|------|--------|---------|
| `AudioBooth/Screens/BookPlayer/BookPlayerModel.swift` | Add `routeChangeNotification` + `silenceSecondaryAudioHintNotification` observers and handlers | 1, 2 |
| `AudioBooth/CarPlay/CarPlayNowPlaying.swift` | Register `CPNowPlayingTemplateObserver`, add sleep timer button | 3, 4 |
| `AudioBooth/CarPlay/CarPlayDelegate.swift` | Activate `AVAudioSession` with `.longFormAudio` policy on connect | 5 |

---

*Report generated: 2026-03-31. Branch analysed: `main` at commit `cad9da3`.*
