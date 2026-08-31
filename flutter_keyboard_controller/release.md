
### Android — Critical fix: black screen on cold-start from notification

- **Root cause**: `onAttachedToActivity()` called `setupKeyboardTracking()` synchronously, which calls `WindowCompat.setDecorFitsSystemWindows(window, false)`. This triggers a window re-layout that races with Flutter's SurfaceView/EGL-Vulkan initialisation. On cold-start from a system notification (e.g. a Live Activity / foreground-service notification), the Flutter engine attaches its surface at exactly the same time — the race caused the SurfaceView to render a blank black frame that never recovered.

- **Fix — Native (`FlutterKeyboardControllerPlugin.kt`)**: `onAttachedToActivity()` now only stores the `Activity` reference. All window configuration is deferred.

- **Fix — Dart (`KeyboardProvider`)**: On Android, `initState` schedules a `postFrameCallback` that invokes the new `setupEdgeToEdge` method channel. By the time `postFrameCallback` fires, Flutter has already committed its first frame and the SurfaceView is fully stable — `setDecorFitsSystemWindows(false)` and inset-listener registration happen safely with no race condition.

- **`isListenersAttached` guard**: Added boolean flag to `setupInsetListeners` to prevent duplicate `ViewCompat.setOnApplyWindowInsetsListener` / `WindowInsetsAnimationCompat.Callback` registration on config-change reattach.

---

