import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only JSONL audit trail for every client tool call.
///
/// One file per day under `<app support>/tool_audit/audit-YYYYMMDD.jsonl`,
/// rotating into `.old` past [maxFileBytes]. Audit failures are swallowed by
/// design: the trail must never break a generation.
final class ToolCallAudit {
  ToolCallAudit._();

  static const maxFileBytes = 8 * 1024 * 1024;

  /// Test seam: override the audit directory (null = platform default).
  @visibleForTesting
  static Directory? Function() directoryResolverOverride = () => null;

  static Future<Directory?>? _baseDirFuture;
  static Future<void> _tail = Future<void>.value();

  /// Records one tool call. Safe to call from anywhere; never throws and
  /// never blocks the caller on disk I/O.
  static void record({
    required String tool,
    required Map<String, dynamic> arguments,
    String? toolCallId,
    String? conversationId,
    required int elapsedMs,
    required String status,
    String? error,
  }) {
    final entry = jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tool': tool,
      if (toolCallId != null) 'toolCallId': toolCallId,
      if (conversationId != null) 'conversationId': conversationId,
      'status': status,
      'elapsedMs': elapsedMs,
      'args': _truncateText(jsonEncode(arguments), 400),
      if (error != null) 'error': _truncateText(error, 400),
    });
    // Serialized write chain: no interleaved appends, audit order == call order.
    _tail = _tail
        .then((_) => _append(entry, DateTime.now()))
        .catchError((Object _) {});
  }

  /// Classifies a raw tool-handler result into an audit status string.
  /// Tool errors are maps carrying an `error` key (e.g. `approval_denied`).
  static String statusOf(Object? result) {
    if (result is Map) {
      final error = result['error'];
      if (error is String && error.isNotEmpty) return 'error:$error';
    }
    return 'ok';
  }

  static Future<void> _append(String line, DateTime now) async {
    try {
      final file = await _fileFor(now);
      if (file == null) return;
      await file.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {
      // The audit trail must never break a generation.
    }
  }

  static Future<File?> _fileFor(DateTime now) async {
    // The test seam swaps directories per test; only production resolution
    // (platform channels) is worth memoizing.
    if (directoryResolverOverride() != null) _baseDirFuture = null;
    _baseDirFuture ??= _resolveBase();
    final base = await _baseDirFuture!;
    if (base == null) return null;
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final file = File(
      [base.path, 'audit-$stamp.jsonl'].join(Platform.pathSeparator),
    );
    if (await file.exists() && await file.length() > maxFileBytes) {
      final old = File('${file.path}.old');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
    }
    return file;
  }

  static Future<Directory?> _resolveBase() async {
    try {
      final override = directoryResolverOverride();
      final resolved = override ?? await getApplicationSupportDirectory();
      final dir = Directory(
        [resolved.path, 'tool_audit'].join(Platform.pathSeparator),
      );
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  static String _truncateText(String text, int limit) =>
      text.length <= limit ? text : '${text.substring(0, limit)}…';
}
