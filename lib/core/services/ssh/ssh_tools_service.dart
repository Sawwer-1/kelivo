import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../features/home/services/local_tools_service.dart'
    show LocalToolNames;
import 'ssh_hosts_store.dart';

/// G2 SSH/SFTP local tools. Phase 1: per-call credentials. Phase 2 (this
/// file now): saved host profiles with vault-sealed passwords (Settings →
/// SSH hosts) and key-file authentication. Resolution order per call:
/// explicit host+username wins; otherwise `profile` looks up the saved
/// store. Credentials confirmed through the standard per-tool approval and
/// redacted from the audit trail by key name.

class _AuthConfig {
  const _AuthConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.keyPath,
    required this.keyPassphrase,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String keyPath;
  final String keyPassphrase;

  bool get useKey => keyPath.isNotEmpty;
}

abstract final class SshToolsService {
  static const int defaultPort = 22;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration commandTimeout = Duration(seconds: 90);
  static const int maxTransferBytes = 64 * 1024 * 1024;

  /// Returns (errorJson, null) on bad arguments, or (null, auth) on success.
  static Future<(String?, _AuthConfig?)> _resolveAuth(
    Map<String, dynamic> args,
  ) async {
    final profileName = '${args['profile'] ?? ''}'.trim();
    final host = '${args['host'] ?? ''}'.trim();
    final username = '${args['username'] ?? ''}'.trim();
    final keyPathArg = '${args['key_path'] ?? ''}'.trim();
    final keyPassphraseArg = '${args['key_passphrase'] ?? ''}';

    var port = defaultPort;
    final portRaw = '${args['port'] ?? ''}'.trim();
    if (portRaw.isNotEmpty) {
      final parsed = int.tryParse(portRaw);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        return (
          _argError('port must be an integer between 1 and 65535.'),
          null,
        );
      }
      port = parsed;
    }

    // Saved profile fills any credential the call did not spell out.
    if (profileName.isNotEmpty) {
      final profile = SshHostsStore.instance.byName(profileName);
      if (profile == null) {
        return (
          jsonEncode({
            'error': 'unknown_profile',
            'message': "No saved SSH host profile named '$profileName'. "
                'Add one in Settings → SSH hosts.',
          }),
          null,
        );
      }
      return (
        null,
        _AuthConfig(
          host: host.isNotEmpty ? host : profile.host,
          port: portRaw.isNotEmpty ? port : profile.port,
          username: username.isNotEmpty ? username : profile.username,
          password: keyPathArg.isEmpty
              ? (args['password'] is String
                  ? args['password'] as String
                  : profile.password)
              : '',
          keyPath: profile.useKeyAuth && profile.keyPath.isNotEmpty
              ? profile.keyPath
              : keyPathArg,
          keyPassphrase: keyPassphraseArg.isNotEmpty
              ? keyPassphraseArg
              : profile.keyPassphrase,
        ),
      );
    }

    if (host.isEmpty || username.isEmpty) {
      return (
        _argError(
          'Provide either a saved `profile`, or host + username plus a '
              'password (or key_path).',
        ),
        null,
      );
    }
    return (
      null,
      _AuthConfig(
        host: host,
        port: port,
        username: username,
        password: keyPathArg.isEmpty ? '${args['password'] ?? ''}' : '',
        keyPath: keyPathArg,
        keyPassphrase: keyPassphraseArg,
      ),
    );
  }

  static String _argError(String message) =>
      jsonEncode({'error': 'invalid_argument', 'message': message});

  static Future<String> exec(Map<String, dynamic> args) async {
    final (authError, auth) = await _resolveAuth(args);
    if (authError != null) return authError;
    if (auth == null) return _argError('unreachable');
    final command = '${args['command'] ?? ''}'.trim();
    if (command.isEmpty) {
      return _argError('command is required.');
    }
    SSHClient? client;
    try {
      client = await _connect(auth);
      final session = await client.execute(command);
      // SSHProcess exposes stdout/stderr as byte streams and exitCode as a
      // plain int; drain both streams concurrently before decoding.
      Future<Uint8List> drain(Stream<Uint8List> stream) async {
        final builder = BytesBuilder();
        await for (final chunk in stream) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      }

      Future<Uint8List> guard(Future<Uint8List> future) =>
          future.timeout(commandTimeout, onTimeout: () {
            throw TimeoutException('command exceeded $commandTimeout');
          });
      final stdout = utf8.decode(await guard(drain(session.stdout)),
          allowMalformed: true);
      final stderr = utf8.decode(await guard(drain(session.stderr)),
          allowMalformed: true);
      final exitCode = session.exitCode;
      return jsonEncode({
        'exit_code': exitCode,
        'stdout': stdout,
        if (stderr.isNotEmpty) 'stderr': stderr,
      });
    } on TimeoutException catch (e) {
      return jsonEncode({'error': 'ssh_timeout', 'message': '${e.message}'});
    } catch (e) {
      return jsonEncode({'error': 'ssh_failed', 'message': '$e'});
    } finally {
      client?.close();
    }
  }

  static Future<String> upload(Map<String, dynamic> args) async {
    final (authError, auth) = await _resolveAuth(args);
    if (authError != null) return authError;
    if (auth == null) return _argError('unreachable');
    final localPath = '${args['local_path'] ?? ''}'.trim();
    final remotePath = '${args['remote_path'] ?? ''}'.trim();
    if (localPath.isEmpty || remotePath.isEmpty) {
      return _argError('local_path and remote_path are required.');
    }
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      return jsonEncode({
        'error': 'local_file_not_found',
        'message': 'No such local file: $localPath',
      });
    }
    final size = await localFile.length();
    if (size > maxTransferBytes) {
      return jsonEncode({
        'error': 'file_too_large',
        'message': 'Local file is $size bytes; the per-file cap is '
            '$maxTransferBytes bytes.',
      });
    }
    return _transfer(
      auth,
      remotePath: remotePath,
      bytes: () => localFile.readAsBytes(),
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
      describe: (sent) => {
        'ok': true,
        'direction': 'upload',
        'remote_path': remotePath,
        'bytes': sent,
      },
    );
  }

  static Future<String> download(Map<String, dynamic> args) async {
    final (authError, auth) = await _resolveAuth(args);
    if (authError != null) return authError;
    if (auth == null) return _argError('unreachable');
    final localPath = '${args['local_path'] ?? ''}'.trim();
    final remotePath = '${args['remote_path'] ?? ''}'.trim();
    if (localPath.isEmpty || remotePath.isEmpty) {
      return _argError('local_path and remote_path are required.');
    }
    return _transfer(
      auth,
      remotePath: remotePath,
      bytes: () async {
        final client = await _connect(auth);
        try {
          final sftp = await client.sftp();
          final remote =
              await sftp.open(remotePath, mode: SftpFileOpenMode.read);
          try {
            final stat = await remote.stat();
            final size = stat.size ?? 0;
            if (size > maxTransferBytes) {
              throw StateError(
                  'Remote file is $size bytes; the per-file cap is '
                  '$maxTransferBytes bytes.');
            }
            final bytes = await remote.readBytes();
            final localFile = File(localPath);
            await localFile.parent.create(recursive: true);
            await localFile.writeAsBytes(bytes, flush: true);
            return bytes;
          } finally {
            await remote.close();
          }
        } finally {
          client.close();
        }
      },
      mode: null,
      describe: (received) => {
        'ok': true,
        'direction': 'download',
        'local_path': localPath,
        'bytes': received,
      },
    );
  }

  /// Shared plumbing for the SFTP directions. [bytes] produces the payload
  /// (the download branch opens its own connection because the remote stat
  /// must happen before anything local); [mode] selects remote open flags
  /// (null = read-only download).
  static Future<String> _transfer(
    _AuthConfig auth, {
    required String remotePath,
    required Future<Uint8List> Function() bytes,
    required SftpFileOpenMode? mode,
    required Map<String, Object?> Function(int) describe,
  }) async {
    SSHClient? client;
    try {
      final data = await bytes().timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('transfer exceeded 5 min'),
      );
      if (mode != null) {
        client = await _connect(auth);
        final sftp = await client.sftp();
        final remote = await sftp.open(remotePath, mode: mode);
        try {
          await remote.writeBytes(data);
        } finally {
          await remote.close();
        }
      }
      return jsonEncode(describe(data.length));
    } on TimeoutException catch (e) {
      return jsonEncode({'error': 'ssh_timeout', 'message': '${e.message}'});
    } on SSHError catch (e) {
      return jsonEncode({'error': 'ssh_failed', 'message': '$e'});
    } catch (e) {
      return jsonEncode({'error': 'ssh_failed', 'message': '$e'});
    } finally {
      client?.close();
    }
  }

  static Future<SSHClient> _connect(_AuthConfig auth) async {
    final socket = await SSHSocket.connect(
      auth.host,
      auth.port,
      timeout: connectTimeout,
    );
    if (auth.useKey) {
      final pem = await File(auth.keyPath).readAsString();
      // dartssh2 2.22: fromPem takes an optional positional passphrase and
      // is synchronous.
      final identities = SSHKeyPair.fromPem(
        pem,
        auth.keyPassphrase.isEmpty ? null : auth.keyPassphrase,
      );
      return SSHClient(socket, username: auth.username, identities: identities);
    }
    return SSHClient(
      socket,
      username: auth.username,
      onPasswordRequest: () => auth.password,
    );
  }

  // ---------------------------------------------------------------------------
  // Tool definitions. All three require per-call approval; auth comes from a
  // saved profile (Settings → SSH hosts) or explicit per-call credentials.

  static const String _authParamsDescription =
      'Authentication: either a saved `profile` name (Settings → SSH hosts, '
      'recommended — no password in the call), or host + username plus a '
      'password, or host + username + key_path.';

  static const Map<String, dynamic> sshExecDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.sshExec,
      'description':
          'Run ONE shell command on a remote host over SSH and return '
          'stdout/stderr/exit code as JSON. Use only for hosts the user '
          'explicitly asked to work with. Every call requires user approval '
          '(the approval card shows the host and command). '
          '$_authParamsDescription',
      'parameters': {
        'type': 'object',
        'properties': {
          'profile': {
            'type': 'string',
            'description':
                'Saved SSH host profile name (Settings → SSH hosts). When '
                'given, host/port/username/credentials come from it.',
          },
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description':
                'SSH password (skip when using profile or key_path).',
          },
          'key_path': {
            'type': 'string',
            'description':
                'Local path of an SSH private key file (key auth).',
          },
          'key_passphrase': {
            'type': 'string',
            'description': 'Passphrase for the private key, if any.',
          },
          'command': {
            'type': 'string',
            'description': 'One shell command to run on the remote host.',
          },
        },
        'required': ['command'],
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> sshUploadDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.sshUpload,
      'description':
          'Upload a local file to a remote host over SFTP (overwrite target, '
          'per-file cap 64 MB). Every call requires user approval (the '
          'approval card shows host, local and remote paths). '
          '$_authParamsDescription',
      'parameters': {
        'type': 'object',
        'properties': {
          'profile': {
            'type': 'string',
            'description':
                'Saved SSH host profile name (Settings → SSH hosts). When '
                'given, host/port/username/credentials come from it.',
          },
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description':
                'SSH password (skip when using profile or key_path).',
          },
          'key_path': {
            'type': 'string',
            'description':
                'Local path of an SSH private key file (key auth).',
          },
          'key_passphrase': {
            'type': 'string',
            'description': 'Passphrase for the private key, if any.',
          },
          'local_path': {
            'type': 'string',
            'description': 'Absolute path of the local file to upload.',
          },
          'remote_path': {
            'type': 'string',
            'description': 'Absolute destination path on the remote host.',
          },
        },
        'required': ['local_path', 'remote_path'],
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> sshDownloadDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.sshDownload,
      'description':
          'Download a remote file to a local path over SFTP (per-file cap '
          '64 MB). Every call requires user approval (the approval card '
          'shows host, remote and local paths). '
          '$_authParamsDescription',
      'parameters': {
        'type': 'object',
        'properties': {
          'profile': {
            'type': 'string',
            'description':
                'Saved SSH host profile name (Settings → SSH hosts). When '
                'given, host/port/username/credentials come from it.',
          },
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description':
                'SSH password (skip when using profile or key_path).',
          },
          'key_path': {
            'type': 'string',
            'description':
                'Local path of an SSH private key file (key auth).',
          },
          'key_passphrase': {
            'type': 'string',
            'description': 'Passphrase for the private key, if any.',
          },
          'remote_path': {
            'type': 'string',
            'description': 'Absolute path of the remote file to download.',
          },
          'local_path': {
            'type': 'string',
            'description': 'Absolute local destination path.',
          },
        },
        'required': ['remote_path', 'local_path'],
        'additionalProperties': false,
      },
    },
  };
}
