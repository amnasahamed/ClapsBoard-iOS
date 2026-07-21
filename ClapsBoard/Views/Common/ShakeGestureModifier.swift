//
//  ShakeGestureModifier.swift
//  ClapsBoard
//
//  Shake gesture detection using CoreMotion
//

import SwiftUI
import CoreMotion

/// ObservableObject that manages motion detection for shake gestures
class ShakeDetector: ObservableObject {
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var onShake: (() -> Void)?

    // Shake detection threshold (in G-force)
    private let shakeThreshold: Double = 2.5

    // Last shake time to prevent multiple triggers
    private var lastShakeTime: TimeInterval = 0
    private let shakeDebounceInterval: TimeInterval = 0.5

    init() {
        motionQueue.name = "ShakeGestureQueue"
        motionQueue.maxConcurrentOperationCount = 1
    }

    func startDetecting(onShake: @escaping () -> Void) {
        self.onShake = onShake

        guard motionManager.isDeviceMotionAvailable else { return }

        motionManager.deviceMotionUpdateInterval = 0.1

        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else { return }

            // Calculate total acceleration magnitude
            let acceleration = motion.userAcceleration
            let totalAcceleration = sqrt(
                pow(acceleration.x, 2) +
                pow(acceleration.y, 2) +
                pow(acceleration.z, 2)
            )

            // Check if shake threshold exceeded
            if totalAcceleration > self.shakeThreshold {
                let currentTime = Date().timeIntervalSince1970

                // Debounce shake events
                if currentTime - self.lastShakeTime > self.shakeDebounceInterval {
                    self.lastShakeTime = currentTime
                    DispatchQueue.main.async {
                        self.onShake?()
                    }
                }
            }
        }
    }

    func stopDetecting() {
        motionManager.stopDeviceMotionUpdates()
        onShake = nil
    }
}

/// View modifier that detects shake gestures
struct ShakeGestureModifier: ViewModifier {
    let action: () -> Void
    @StateObject private var shakeDetector = ShakeDetector()

    func body(content: Content) -> some View {
        content
            .onAppear {
                shakeDetector.startDetecting(onShake: action)
            }
            .onDisappear {
                shakeDetector.stopDetecting()
            }
    }
}

extension View {
    /// Adds a shake gesture handler to the view
    func onShakeGesture(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeGestureModifier(action: action))
    }
}

#Preview {
    Text("Shake this view")
        .onShakeGesture {
            print("Shake detected!")
        }
}