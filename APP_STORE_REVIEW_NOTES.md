# App Store Review Notes

Paste the following into **App Review Information → Notes** when submitting ClapsBoard. Keep it in sync with the app: anything the app does in the background must be described here.

---

**About the app**

ClapsBoard is a whiteboard for tutors. There is no account, no sign-in, no server and no analytics: boards, documents, student notes and class schedules are stored only on the device.

**Picture-in-Picture camera mirror — background mode and entitlement**

Tutors can show a live mirror of their front camera in Picture-in-Picture and keep it on screen while they switch to other apps during a lesson (for example a document or calendar). This uses:

- The `audio` background mode ("Audio, AirPlay, and Picture in Picture"), which Picture-in-Picture requires.
- The `com.apple.developer.avfoundation.multitasking-camera-access` entitlement, so the capture session keeps running while the PiP window is visible.
- While PiP is showing, the app plays a **silent audio stream** through `AVAudioEngine`. It starts only when the tutor starts PiP and stops as soon as PiP closes or the app returns to the foreground. Its only purpose is to keep the PiP camera feed running; no sound is played and nothing is recorded.

The camera feed is a live preview only. Video is never recorded, saved or uploaded. The app does not use the `voip` background mode.

**Voice Channel (Settings → Voice Channel)**

An optional local-network voice channel between a tutor and nearby students (MultipeerConnectivity, encryption required). The host shares a 4-digit code and only devices that join with that code are admitted. Participants can be blocked, or reported and removed, from the participant list. It works only while the app is open, and it is the only feature that uses the microphone.

**How to verify**

1. Open the Board, tap ••• → Turn Camera On, then tap the Picture-in-Picture button.
2. Go to the Home Screen. The PiP window keeps showing the live camera feed.
3. Tap the PiP button again (or close the PiP window). PiP closes and stays closed.
4. Optional: Settings → Voice Channel → Host to see the 4-digit code; a second device can join with it.

---
