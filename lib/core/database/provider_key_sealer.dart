import 'dart:convert';
import 'dart:developer' as developer;

import '../services/key_vault/key_vault.dart';
import 'business_data.dart';

/// Seals/unseals provider credential fields at the at-rest boundary.
///
/// Rows in SQLite carry sealed credentials (DPAPI on Windows, no-op vault
/// elsewhere); plaintext exists only in repository read results and above.
/// DPAPI ciphertexts are nondeterministic, so equality between two sealed
/// payloads must never be used as a change signal — compare through
/// [unsealRows] instead. [KeyVault.encryptString] is idempotent on already
/// sealed input, which keeps restore paths that re-seal sealed blobs stable.
final class ProviderKeySealer {
  ProviderKeySealer._();

  static const _credentialFields = <String>{'apiKey'};
  static const _credentialListFields = <String>{'apiKeys'};

  static bool get _active => KeyVault.instance.isSupported;

  /// True when [payload] carries unsealed, non-empty credential fields.
  static bool hasPlainCredentials(String payload) {
    if (!_active) return false;
    final map = _decode(payload);
    if (map == null) return false;
    return _mapFields(map, _sealField).changed;
  }

  /// Seals credential fields in [row]. Non-provider kinds and platforms
  /// without a vault pass through untouched.
  static BusinessEntityValue sealRow(
    BusinessEntityKind kind,
    BusinessEntityValue row,
  ) {
    if (kind != BusinessEntityKind.provider || !_active) return row;
    return _mapRow(row, _sealField);
  }

  /// Unseals credential fields in [row]. Undecryptable sealed values fail
  /// closed to an empty credential; legacy plaintext passes through.
  static BusinessEntityValue unsealRow(
    BusinessEntityKind kind,
    BusinessEntityValue row,
  ) {
    if (kind != BusinessEntityKind.provider || !_active) return row;
    return _mapRow(row, _unsealField);
  }

  static List<BusinessEntityValue> unsealRows(
    BusinessEntityKind kind,
    List<BusinessEntityValue> rows,
  ) => [
    for (final row in rows) unsealRow(kind, row),
  ];

  static BusinessEntityValue _mapRow(
    BusinessEntityValue row,
    String Function(String) mapper,
  ) {
    final map = _decode(row.payload);
    if (map == null) return row;
    final result = _mapFields(map, mapper);
    if (!result.changed) return row;
    return row.copyWith(payload: jsonEncode(result.map));
  }

  static String _sealField(String value) =>
      KeyVault.instance.encryptString(value);

  static String _unsealField(String value) {
    final result = KeyVault.instance.decryptOrOriginal(value);
    if (result.decrypted) return result.value;
    if (KeyVault.instance.isEncrypted(value)) {
      // Sealed on another machine (or corrupted seal): fail closed to an
      // empty credential instead of sending an opaque blob to the provider.
      developer.log(
        'Provider credential could not be unsealed; treating as empty. '
        'Re-enter the key in provider settings.',
        name: 'Kelivo.security.vault',
      );
      return '';
    }
    return result.value;
  }

  static Map<String, dynamic>? _decode(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  static ({Map<String, dynamic> map, bool changed}) _mapFields(
    Map<String, dynamic> map,
    String Function(String) mapper,
  ) {
    var changed = false;
    final out = <String, dynamic>{};
    map.forEach((key, value) {
      if (_credentialFields.contains(key) &&
          value is String &&
          value.isNotEmpty) {
        final mapped = mapper(value);
        if (mapped != value) changed = true;
        out[key] = mapped;
      } else if (_credentialListFields.contains(key) && value is List) {
        final list = <Object?>[];
        for (final item in value) {
          if (item is String && item.isNotEmpty) {
            final mapped = mapper(item);
            if (mapped != item) changed = true;
            list.add(mapped);
          } else {
            list.add(item);
          }
        }
        out[key] = list;
      } else {
        out[key] = value;
      }
    });
    return (map: out, changed: changed);
  }
}
