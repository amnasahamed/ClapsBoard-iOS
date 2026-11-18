# App Store Review Notes

Paste the following into **App Review Information → Notes** when submitting ClapsBoard. Keep it in sync with the app: anything the app does in the background must be described here.

---

**About the app**

ClapsBoard is a whiteboard for tutors. There is no account, no sign-in, no server and no analytics: boards, documents, student notes and class schedules are stored only on the device.

**Picture-in-Picture camera mirror — background mode and entitlement**

Tutors can show a live mirror of their front camera in Picture-in-Picture and keep it on screen while they switch to other apps during a lesson (for example a document or calendar). PiP starts when the tutor taps the PiP button, or automatically when they leave the app with the camera mirror on. If the app only loses focus briefly (Control Center, Notification Center, a system alert) and comes back without going to the background, that automatic PiP is closed again. This uses:

- The `audio` background mode ("Audio, AirPlay, and Picture in Picture"), which Picture-in-Picture requires.
- The `com.apple.developer.avfoundation.multitasking-camera-access` entitlement, so the capture session keeps running while the PiP window is visible.
- A **silent audio stream** played through `AVAudioEngine`, whose only purpose is to keep the PiP camera feed running while the app is in the background. No sound is heard and nothing is recorded.
  - It starts when iOS reports that PiP can start and the app asks for it, and again each time the app leaves the foreground with PiP showing. It is restarted if the system stops it (for example after a phone call) while PiP is still showing.
  - It stops when PiP closes for any reason (the in-app PiP button, the close button on the PiP window, or returning to the app from the PiP window), when PiP fails to start, when the camera is turned off, and whenever the app returns to the foreground.
  - If the tutor leaves the app while PiP is still being started, the silent audio can run for up to about 10 seconds without a PiP window; if PiP has not appeared by then it stops.

The app does not configure or activate an audio session at launch. With the camera mirror on, the audio session category is set to playback (mixing with other audio) so PiP is available; the session is active only while the silent audio above is playing.

The camera mirror is a live preview only: its video is never recorded, saved or uploaded. Separately, Docs → Take Photo opens the system camera to take one photo, which is saved as a document on the device only. The app does not use the `voip` background mode.

**Voice Channel (Settings → Voice Channel)**

An optional local-network voice channel between a tutor and nearby students (MultipeerConnectivity, encryption required). The host shares a 4-digit code and only devices that join with that code are admitted.

- Lifetime: a channel stays on while the tutor uses other screens of the app (for example the board). It ends when the tutor taps End Session, when the host ends it, or when the app goes to the background — leaving the app turns the microphone off and disconnects. Voice Channel does not run in the background.
- Microphone: Voice Channel is the only feature that captures microphone audio. Microphone permission is requested the first time a channel is hosted or joined; if it is denied the channel does not start and the app explains how to enable it. Audio is sent only to the connected devices and is never recorded or stored.
- Block / Report: touch and hold a participant. **Block** stops that device's audio being played and stops audio being sent to it, removes it from the participant list, asks that device to leave when the blocker is the host, and refuses it if it tries to join a channel hosted on this device again. Blocked devices are listed on the Voice Channel screen with an Unblock button. **Report and remove** does the same and also flags the device locally; because the app has no server, a report is not sent to us or to anyone else.
- Participants are shown by device name plus a short per-install code; no account or personal information is exchanged.

**Class countdown Live Activity**

If the app is open in the five minutes before a scheduled class, it starts a local Live Activity counting down to the class. It is started and ended on the device (no push notifications) and is removed a few minutes after the class start time.

**How to verify**

1. Open the Board, tap ••• → Turn Camera On, then tap the Picture-in-Picture button.
2. Go to the Home Screen. The PiP window keeps showing the live camera feed.
3. Tap the PiP button again (or close the PiP window). PiP closes and stays closed.
4. Optional: Settings → Voice Channel → Host to see the 4-digit code; a second device can join with it. Going back to the board keeps the channel on; going to the Home Screen ends it.

---
