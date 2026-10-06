import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Gates plaintext-credential views behind platform user verification
/// (Windows Hello PIN/face/fingerprint, Touch ID, Android biometrics).
///
/// Policy: when the device has a platform authenticator, revealing stored
/// credentials requires a fresh confirmation. When the device has none (or
/// the plugin errors), the gate fails open with a log — locking a user out
/// of their own key is worse than a local, already-gated plaintext view.
final class BiometricGate {
  BiometricGate._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// Returns true when revealing may proceed.
  static Future<bool> confirm({required String reason}) async {
    try {
      if (!await _auth.isDeviceSupported()) {
        // No platform authenticator available: fail open, keep the UX alive.
        return true;
      }
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      developer.log(
        'BiometricGate error ($e); failing open.',
        name: 'Kelivo.security.vault',
      );
      return true;
    }
  }

  /// Convenience wrapper for reveal toggles: runs [toggle] only when the
  /// gate passes (or when [revealing] is false — hiding needs no gate).
  static Future<void> gatedToggle({
    required bool revealing,
    required String reason,
    required VoidCallback toggle,
  }) async {
    if (!revealing) {
      toggle();
      return;
    }
    if (await confirm(reason: reason)) toggle();
  }
}
