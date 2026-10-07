import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../hotkeys/chat_action_bus.dart';
import 'quick_capture_dialog.dart';
import 'screen_capture.dart';

/// F2 QuickCapture (phase 1) orchestration:
/// hotkey → full-screen BitBlt (Kelivo still behind, so the shot is the
/// screen as the user saw it) → raise the Kelivo window → preview + question
/// dialog → broadcast the payload on [ChatActionBus] for the chat page to
/// send through the normal composer path. Failures stay silent: the hotkey
/// context has no guaranteed scaffold, and a missed capture must never
/// disrupt whatever the user was doing.
abstract final class QuickCaptureService {
  static bool _inFlight = false;

  static Future<void> captureAndAsk(BuildContext context) async {
    if (_inFlight) return; // hotkey repeat / double fire guard
    if (!ScreenCapture.isSupported) return;
    _inFlight = true;
    try {
      final png = await ScreenCapture.capturePng();
      if (png == null) return;
      // The screenshot is already taken; only now is it safe to raise the
      // Kelivo window for the question dialog.
      try {
        if (!(await windowManager.isVisible())) {
          await windowManager.show();
        }
        await windowManager.focus();
      } catch (_) {}
      if (!context.mounted) return;
      final result = await QuickCaptureDialog.show(context, png);
      if (result == null) return;
      ChatActionBus.instance.fireQuickCaptureSend(
        QuickCaptureSend(text: result.text, imagePath: result.imageFile.path),
      );
    } catch (_) {
      // Never let a capture hiccup crash the caller (hotkey context).
    } finally {
      _inFlight = false;
    }
  }
}
