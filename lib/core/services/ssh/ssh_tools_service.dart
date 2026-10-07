import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../features/home/services/local_tools_service.dart'
    show LocalToolNames;

/// G2 SSH/SFTP local tools (phase 1): credentials are passed per call by
/// the model and confirmed through the standard per-tool approval; the
/// audit trail redacts password-shaped keys automatically. Vault-backed
/// host profiles (no per-call passwords) are phase 2.

abstract final class SshToolsService {
  static const int defaultPort = 22;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration commandTimeout = Duration(seconds: 90);
  static const int maxTransferBytes = 64 * 1024 * 1024;

  static ({String host, int port, String username, String password})?
      _parseCommon(Map<String, dynamic> args) {
    final host = '${args['host'] ?? ''}'.trim();
    if (host.isEmpty) return null;
    final port = int.tryParse('${args['port'] ?? ''}'.trim()) ?? defaultPort;
    if (port < 1 || port > 65535) return null;
    final username = '${args['username'] ?? ''}'.trim();
    if (username.isEmpty) return null;
    final password = '${args['password'] ?? ''}';
    return (host: host, port: port, username: username, password: password);
  }

  static String _argError(String message) =>
      jsonEncode({'error': 'invalid_argument', 'message': message});

  static Future<String> exec(Map<String, dynamic> args) async {
    final common = _parseCommon(args);
    if (common == null) {
      return _argError(
          'host, username are required; port must be 1-65535 if given.');
    }
    final command = '${args['command'] ?? ''}'.trim();
    if (command.isEmpty) {
      return _argError('command is required.');
    }
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        common.host,
        common.port,
        timeout: connectTimeout,
      );
      client = SSHClient(
        socket,
        username: common.username,
        onPasswordRequest: () => common.password,
      );
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
      final stdout = utf8.decode(
          await guard(drain(session.stdout)), allowMalformed: true);
      final stderr = utf8.decode(
          await guard(drain(session.stderr)), allowMalformed: true);
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
    final common = _parseCommon(args);
    if (common == null) {
      return _argError(
          'host, username are required; port must be 1-65535 if given.');
    }
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
      common,
      remotePath: remotePath,
      bytes: () => localFile.readAsBytes(),
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
      describe: (sent) => {
        'ok': true,
        'direction': 'upload',
        'remote_path': remotePath,
        'bytes': sent,
      },
    );
  }

  static Future<String> download(Map<String, dynamic> args) async {
    final common = _parseCommon(args);
    if (common == null) {
      return _argError(
          'host, username are required; port must be 1-65535 if given.');
    }
    final localPath = '${args['local_path'] ?? ''}'.trim();
    final remotePath = '${args['remote_path'] ?? ''}'.trim();
    if (localPath.isEmpty || remotePath.isEmpty) {
      return _argError('local_path and remote_path are required.');
    }
    return _transfer(
      common,
      remotePath: remotePath,
      bytes: () async {
        final client = await _connect(common);
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

  /// Shared plumbing for the SFTP directions. [bytes] opens its own
  /// client (the download branch needs the connection before the local
  /// side does anything); [mode] selects remote open flags (null = read).
  static Future<String> _transfer(
    ({String host, int port, String username, String password}) common, {
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
        client = await _connect(common);
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

  static Future<SSHClient> _connect(
    ({String host, int port, String username, String password}) common,
  ) async {
    final socket = await SSHSocket.connect(
      common.host,
      common.port,
      timeout: connectTimeout,
    );
    return SSHClient(
      socket,
      username: common.username,
      onPasswordRequest: () => common.password,
    );
  }

  // ---------------------------------------------------------------------------
  // Tool definitions. All three require per-call approval; the shared
  // credential block is repeated verbatim so each definition stands alone.

  static const Map<String, dynamic> sshExecDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.sshExec,
      'description':
          'Run ONE shell command on a remote host over SSH and return '
          'stdout/stderr/exit code as JSON. Use only for hosts the user '
          'explicitly asked to work with. Every call requires user approval '
          '(the approval card shows the host and command).',
      'parameters': {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description': 'SSH password (key auth is phase 2).',
          },
          'command': {
            'type': 'string',
            'description': 'One shell command to run on the remote host.',
          },
        },
        'required': ['host', 'username', 'password', 'command'],
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
          'approval card shows host, local and remote paths).',
      'parameters': {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description': 'SSH password (key auth is phase 2).',
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
        'required': ['host', 'username', 'password', 'local_path',
            'remote_path'],
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
          'shows host, remote and local paths).',
      'parameters': {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': 'SSH host or IP.'},
          'port': {
            'type': 'integer',
            'description': 'SSH port (default 22).',
          },
          'username': {'type': 'string'},
          'password': {
            'type': 'string',
            'description': 'SSH password (key auth is phase 2).',
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
        'required': ['host', 'username', 'password', 'remote_path',
            'local_path'],
        'additionalProperties': false,
      },
    },
  };
}
