import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/key_vault/key_vault.dart';

void main() {
  // Force the real DPAPI path: flutter_test defaults to android platform,
  // which silently degrades to the passthrough vault (false-green trap).
  final vault = KeyVault.instance;
  final sealedPlatform = vault.isSupported;

  test('round trip restores plaintext', () {
    if (!sealedPlatform) return;
    const secret = 'sk-test-密钥-🔑-123';
    final sealed = vault.encryptString(secret);
    expect(sealed, isNot(secret));
    expect(vault.isEncrypted(sealed), isTrue);
    final opened = vault.decryptOrOriginal(sealed);
    expect(opened.decrypted, isTrue);
    expect(opened.value, secret);
  });

  test('encryptString is idempotent on sealed input', () {
    if (!sealedPlatform) return;
    final sealed = vault.encryptString('abc');
    expect(vault.encryptString(sealed), sealed);
  });

  test('legacy plaintext passes through unopened', () {
    final result = vault.decryptOrOriginal('sk-plain-key');
    expect(result.value, 'sk-plain-key');
    expect(result.decrypted, isFalse);
    expect(vault.isEncrypted('sk-plain-key'), isFalse);
  });

  test('foreign or corrupted blob degrades without throwing', () {
    if (!sealedPlatform) return;
    const bogus = 'dpapi:v1:not-a-real-blob';
    final result = vault.decryptOrOriginal(bogus);
    expect(result.value, bogus);
    expect(result.decrypted, isFalse);
  });

  test('two seals of one secret are nondeterministic ciphertexts', () {
    if (!sealedPlatform) return;
    expect(
      vault.encryptString('same-secret'),
      isNot(vault.encryptString('same-secret')),
    );
  });
}
