# App Store Review Notes

Paste the following into **App Review Information → Notes** when submitting ClapsBoard:

---

**VoIP / multitasking camera background modes**

ClapsBoard is a teaching whiteboard app for tutors. We use the `voip` background mode and the `com.apple.developer.avfoundation.multitasking-camera-access` entitlement so tutors can keep a live camera mirror visible in Picture-in-Picture while they switch to other apps (for example calendar or documents) during a lesson.

- The camera feed is a **live preview only**. Video is never recorded, saved, or uploaded.
- Picture-in-Picture shows the tutor’s face so students can continue to see them while the tutor multitasks.
- The **Voice Channel** feature uses local-network voice communication between tutor and nearby students during lessons (Bonjour / peer connectivity). Microphone access supports that feature and PiP audio session requirements.

How to verify:
1. Open a board → enable the camera overlay → tap the PiP control.
2. Leave the app (Home or switch apps). The PiP window should remain and continue showing the live camera feed.
3. Optionally open Voice Channel from the app to confirm local voice communication.

---
