import 'dart:convert';
import 'dart:developer' as developer;

import 'key_vault.dart';

/// Seals/unseals credential fields inside JSON blobs persisted outside the
/// business-entity tables (SharedPreferences-backed configs: MCP servers,
/// ASR services, TTS services).
///
/// Mirrors [ProviderKeySealer] semantics: sealed at the write boundary,
/// unsealed at the read boundary, idempotent on already-sealed input
/// ([KeyVault.encryptString] keeps sealed input stable), plaintext
/// passthrough when the vault is unsupported. Undecryptable seals fail
/// closed to an empty credential (cross-machine restore).
final class CredentialSealer {
  CredentialSealer._();

  static bool get _active => KeyVault.instance.isSupported;

  /// Header/env key names whose values carry credentials (MCP configs).
  static final RegExp _sensitiveKeyName = RegExp(
    r'(authorization|token|secret|password|api[-_]?key)',
    caseSensitive: false,
  );

  /// OAuth state fields inside MCP server configs.
  static const _oauthTokenFields = <String>{
    'accessToken',
    'refreshToken',
    'clientSecret',
    'idToken',
  };

  /// Seals the `apiKey` field of every element in a JSON array blob
  /// (ASR / TTS service lists).
  static String sealApiKeyList(String raw) => _mapApiKeyList(raw, _seal);

  /// Unseals the `apiKey` field of every element in a JSON array blob.
  static String unsealApiKeyList(String raw) => _mapApiKeyList(raw, _unseal);

  /// Seals credential fields inside the MCP server list blob: `headers` /
  /// `env` entries with sensitive key names, plus OAuth token fields.
  /// Non-sensitive keys (urls, timeouts, tool schemas) pass through.
  static String sealMcpServers(String raw) => _mapMcpServers(raw, _seal);

  /// Unseals credential fields inside the MCP server list blob.
  static String unsealMcpServers(String raw) => _mapMcpServers(raw, _unseal);

  /// True when [raw] still carries unsealed credential fields.
  static bool hasPlainCredentialsMcp(String raw) =>
      _active && sealMcpServers(raw) != raw;

  static String _seal(String value) => KeyVault.instance.encryptString(value);

  static String _unseal(String value) {
    final result = KeyVault.instance.decryptOrOriginal(value);
    if (result.decrypted) return result.value;
    if (KeyVault.instance.isEncrypted(value)) {
      developer.log(
        'Stored credential could not be unsealed; treating as empty. '
        'Re-enter it in settings.',
        name: 'Kelivo.security.vault',
      );
      return '';
    }
    return result.value;
  }

  static ({List<dynamic> list, bool changed})? _decodeList(String raw) {
    if (!_active || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    return (list: decoded, changed: false);
  }

  static String _mapApiKeyList(String raw, String Function(String) mapper) {
    final decoded = _decodeList(raw);
    if (decoded == null) return raw;
    var changed = false;
    final out = <dynamic>[];
    for (final item in decoded.list) {
      if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        final value = map['apiKey'];
        if (value is String && value.isNotEmpty) {
          final mapped = mapper(value);
          if (mapped != value) changed = true;
          map['apiKey'] = mapped;
        }
        out.add(map);
      } else {
        out.add(item);
      }
    }
    if (!changed) return raw;
    return jsonEncode(out);
  }

  static String _mapMcpServers(String raw, String Function(String) mapper) {
    final decoded = _decodeList(raw);
    if (decoded == null) return raw;
    var changed = false;
    final out = <dynamic>[];
    for (final item in decoded.list) {
      if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        for (final containerKey in const <String>{'headers', 'env'}) {
          final container = map[containerKey];
          if (container is Map) {
            final sealed = <String, dynamic>{};
            container.forEach((key, value) {
              if (key is String &&
                  value is String &&
                  value.isNotEmpty &&
                  _sensitiveKeyName.hasMatch(key)) {
                final mapped = mapper(value);
                if (mapped != value) changed = true;
                sealed[key] = mapped;
              } else {
                sealed[key as String] = value;
              }
            });
            map[containerKey] = sealed;
          }
        }
        for (final oauthKey in const <String>{'oauth', 'oauthClient'}) {
          final state = map[oauthKey];
          if (state is Map) {
            final sealed = <String, dynamic>{};
            state.forEach((key, value) {
              if (_oauthTokenFields.contains(key) &&
                  value is String &&
                  value.isNotEmpty) {
                final mapped = mapper(value);
                if (mapped != value) changed = true;
                sealed[key as String] = mapped;
              } else {
                sealed[key as String] = value;
              }
            });
            map[oauthKey] = sealed;
          }
        }
        out.add(map);
      } else {
        out.add(item);
      }
    }
    if (!changed) return raw;
    return jsonEncode(out);
  }
}
