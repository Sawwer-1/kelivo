import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:ffi/ffi.dart' as ffi;

/// At-rest encryption for provider API keys (AAA Secret Vault lineage,
/// desktop flavor: Windows DPAPI instead of Android Keystore).
///
/// Ciphertexts are tagged with [_tag] so legacy plaintext values, foreign
/// blobs and undecryptable restores can be told apart. [decryptOrOriginal]
/// never throws: anything it cannot open comes back as the original string
/// plus `decrypted = false`, letting callers degrade instead of crashing.
abstract class KeyVault {
  static final KeyVault instance = _createForPlatform();

  static KeyVault _createForPlatform() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return DpapiKeyVault();
    }
    return PassthroughKeyVault();
  }

  bool get isSupported;

  /// True when [value] carries this vault's ciphertext tag.
  bool isEncrypted(String value);

  String encryptString(String plaintext);

  /// Decrypts a tagged ciphertext. Un-tagged input is returned as-is
  /// (legacy plaintext). Tagged-but-undecryptable input (e.g. a DPAPI blob
  /// restored on another machine) also returns the original string with
  /// `decrypted: false` so callers can warn instead of crashing.
  ({String value, bool decrypted}) decryptOrOriginal(String value);
}

/// No-op vault for platforms without a DPAPI equivalent wired yet.
final class PassthroughKeyVault implements KeyVault {
  @override
  bool get isSupported => false;

  @override
  bool isEncrypted(String value) => false;

  @override
  String encryptString(String plaintext) => plaintext;

  @override
  ({String value, bool decrypted}) decryptOrOriginal(String value) =>
      (value: value, decrypted: false);
}

/// Windows DPAPI (user-scoped). Ciphertexts only open under the same Windows
/// account, so backups carrying them restore as unusable keys on a new
/// machine by design — callers surface a re-entry hint in that case.
final class DpapiKeyVault implements KeyVault {
  static const _tag = 'dpapi:v1:';
  static const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  DpapiKeyVault() {
    _protect = _crypt32
        .lookup<
          NativeFunction<
            Int32 Function(
              Pointer<_DataBlob>,
              Pointer<ffi.Utf16>,
              Pointer<_DataBlob>,
              Pointer<Void>,
              Pointer<Void>,
              Uint32,
              Pointer<_DataBlob>,
            )
          >
        >('CryptProtectData')
        .asFunction();
    _unprotect = _crypt32
        .lookup<
          NativeFunction<
            Int32 Function(
              Pointer<_DataBlob>,
              Pointer<ffi.Utf16>,
              Pointer<_DataBlob>,
              Pointer<Void>,
              Pointer<Void>,
              Uint32,
              Pointer<_DataBlob>,
            )
          >
        >('CryptUnprotectData')
        .asFunction();
    _localFree = _kernel32
        .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
          'LocalFree',
        )
        .asFunction();
  }

  final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  /// One-off acceptance diagnostics: last Win32 error after a failed call.
  late final int Function() _getLastError = _kernel32
      .lookup<NativeFunction<Uint32 Function()>>('GetLastError')
      .asFunction();

  late final int Function(
    Pointer<_DataBlob>,
    Pointer<ffi.Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _protect;
  late final int Function(
    Pointer<_DataBlob>,
    Pointer<ffi.Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _unprotect;
  late final Pointer<Void> Function(Pointer<Void>) _localFree;

  @override
  bool get isSupported => true;

  @override
  bool isEncrypted(String value) => value.startsWith(_tag);

  @override
  String encryptString(String plaintext) {
    if (plaintext.startsWith(_tag)) return plaintext; // already sealed
    final bytes = Uint8List.fromList(utf8.encode(plaintext));
    return _tag + base64Encode(_protectData(bytes));
  }

  @override
  ({String value, bool decrypted}) decryptOrOriginal(String value) {
    if (!value.startsWith(_tag)) return (value: value, decrypted: false);
    Uint8List cipher;
    try {
      cipher = base64Decode(value.substring(_tag.length));
    } on FormatException {
      return (value: value, decrypted: false);
    }
    try {
      return (value: utf8.decode(_unprotectData(cipher)), decrypted: true);
    } catch (_) {
      // Foreign-machine blob or corrupted seal: degrade, never throw.
      return (value: value, decrypted: false);
    }
  }

  Uint8List _protectData(Uint8List plain) {
    return _withBlob(plain, (inBlob, outBlob) {
      final ok = _protect(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw StateError('CryptProtectData failed (GetLastError='
            '${_getLastError()})');
      }
      final out = outBlob.ref;
      final bytes = Uint8List.fromList(out.pbData.asTypedList(out.cbData));
      _localFree(out.pbData.cast<Void>());
      return bytes;
    });
  }

  Uint8List _unprotectData(Uint8List cipher) {
    return _withBlob(cipher, (inBlob, outBlob) {
      final ok = _unprotect(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) throw StateError('CryptUnprotectData failed');
      final out = outBlob.ref;
      final bytes = Uint8List.fromList(out.pbData.asTypedList(out.cbData));
      _localFree(out.pbData.cast<Void>());
      return bytes;
    });
  }

  R _withBlob<R>(
    Uint8List bytes,
    R Function(Pointer<_DataBlob>, Pointer<_DataBlob>) body,
  ) {
    // Allocator.call<T>(x) treats x as ALIGNMENT and allocates sizeof(T) —
    // allocate<T>(n) is the explicit byte-count form. DATA_BLOB is 16 bytes
    // on x64; the data buffer needs exactly len.
    final inBlob = ffi.malloc.allocate<_DataBlob>(16);
    final dataBuf =
        ffi.malloc.allocate<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final outBlob = ffi.malloc.allocate<_DataBlob>(16);
    try {
      dataBuf.asTypedList(bytes.length).setAll(0, bytes);
      inBlob.ref
        ..pbData = bytes.isEmpty ? nullptr : dataBuf
        ..cbData = bytes.length;
      return body(inBlob, outBlob);
    } finally {
      ffi.malloc.free(inBlob);
      ffi.malloc.free(dataBuf);
      ffi.malloc.free(outBlob);
    }
  }
}

/// mirrors crypt32's DATA_BLOB / CRYPTOAPI_BLOB: { DWORD cbData; BYTE* pbData; }
/// (field order matters: cbData comes FIRST, unlike the MSDN prose order)
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}
