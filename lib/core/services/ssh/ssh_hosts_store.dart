import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../key_vault/key_vault.dart';

/// G2 phase 2: saved SSH host profiles. One shared_preferences key holds a
/// JSON list; the password field is sealed with the same DPAPI vault as
/// provider keys (A1 lineage), so the blob on disk never carries a plaintext
/// credential. Key-file profiles store only the path — the key itself never
/// enters the store.
@immutable
class SshHostProfile {
  const SshHostProfile({
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.useKeyAuth = false,
    this.password = '',
    this.keyPath = '',
    this.keyPassphrase = '',
  });

  final String name;
  final String host;
  final int port;
  final String username;
  final bool useKeyAuth;
  final String password; // plaintext in memory, sealed at rest
  final String keyPath;
  final String keyPassphrase;

  SshHostProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    bool? useKeyAuth,
    String? password,
    String? keyPath,
    String? keyPassphrase,
  }) =>
      SshHostProfile(
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        useKeyAuth: useKeyAuth ?? this.useKeyAuth,
        password: password ?? this.password,
        keyPath: keyPath ?? this.keyPath,
        keyPassphrase: keyPassphrase ?? this.keyPassphrase,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'useKeyAuth': useKeyAuth,
        'password': KeyVault.instance.encryptString(password),
        if (keyPath.isNotEmpty) 'keyPath': keyPath,
        if (keyPassphrase.isNotEmpty)
          'keyPassphrase': KeyVault.instance.encryptString(keyPassphrase),
      };

  static SshHostProfile fromJson(Map<String, dynamic> json) {
    String unseal(String value) =>
        KeyVault.instance.decryptOrOriginal(value).value;
    return SshHostProfile(
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: json['port'] as int? ?? 22,
      username: json['username'] as String? ?? '',
      useKeyAuth: json['useKeyAuth'] as bool? ?? false,
      password: unseal(json['password'] as String? ?? ''),
      keyPath: json['keyPath'] as String? ?? '',
      keyPassphrase: unseal(json['keyPassphrase'] as String? ?? ''),
    );
  }
}

class SshHostsStore extends ChangeNotifier {
  SshHostsStore._();
  static final SshHostsStore instance = SshHostsStore._();

  static const _key = 'ssh_hosts_v1';

  List<SshHostProfile> _hosts = const <SshHostProfile>[];
  bool _loaded = false;

  List<SshHostProfile> get hosts => List.unmodifiable(_hosts);

  SshHostProfile? byName(String name) {
    for (final host in _hosts) {
      if (host.name == name) return host;
    }
    return null;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final List<SshHostProfile> hosts = const <SshHostProfile>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        hosts.addAll([
          for (final item in decoded)
            if (item is Map)
              SshHostProfile.fromJson(item.cast<String, dynamic>()),
        ]);
      } catch (_) {
        // Corrupt blob: start empty rather than crash the settings UI.
      }
    }
    _hosts = hosts;
    _loaded = true;
    // First load happens after listeners (e.g. the settings pane) subscribed
    // asynchronously — announce it so the list renders.
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final h in _hosts) h.toJson()]),
    );
  }

  Future<void> upsert(SshHostProfile profile) async {
    await _ensureLoaded();
    final next = List<SshHostProfile>.of(_hosts);
    final index = next.indexWhere((h) => h.name == profile.name);
    if (index == -1) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    _hosts = next;
    await _persist();
    notifyListeners();
  }

  Future<bool> remove(String name) async {
    await _ensureLoaded();
    final next = List<SshHostProfile>.of(_hosts)
      ..removeWhere((h) => h.name == name);
    if (next.length == _hosts.length) return false;
    _hosts = next;
    await _persist();
    notifyListeners();
    return true;
  }
}
