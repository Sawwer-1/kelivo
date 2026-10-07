import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../utils/utf16_safe_cut.dart';

/// Append-only JSONL audit trail for every client tool call.
///
/// One file per day under `<app support>/tool_audit/audit-YYYYMMDD.jsonl`,
/// rotating into `.old` past [maxFileBytes]. Audit failures are swallowed by
/// design: the trail must never break a generation.
final class ToolCallAudit {
  ToolCallAudit._();

  static const maxFileBytes = 8 * 1024 * 1024;

  /// User-facing switch (SettingsProvider mirrors the persisted pref into
  /// this field). Defaults to on: the trail is an opt-out, not opt-in —
  /// a missing audit after a incident is worse than a small local file.
  static bool enabled = true;

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
    if (!enabled) return;
    // jsonEncode must never escape this method: arguments come from tool
    // handlers and could theoretically carry a non-JSON-encodable object.
    // The trail is best-effort — a bad payload is dropped, not thrown.
    final String entry;
    try {
      entry = jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'tool': tool,
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (conversationId != null) 'conversationId': conversationId,
        'status': status,
        'elapsedMs': elapsedMs,
        'args': _truncateText(jsonEncode(_redactArgs(arguments)), 400),
        if (error != null) 'error': _truncateText(error, 400),
      });
    } catch (_) {
      return;
    }
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
      text.length <= limit ? text : '${truncateHeadUtf16Safe(text, limit)}…';

  /// Key names whose values must never reach the audit file in plaintext.
  static final RegExp _redactKeyName = RegExp(
    r'(key|token|secret|auth|password)',
    caseSensitive: false,
  );

  /// Recursive redaction for tool arguments: values under credential-ish
  /// key names become `***` before anything is serialized to disk.
  static Map<String, dynamic> _redactArgs(Map<String, dynamic> args) {
    var changed = false;
    final out = <String, dynamic>{};
    args.forEach((key, value) {
      final redactedValue = _redactValue(value);
      if (!identical(redactedValue, value) && redactedValue != value) {
        changed = true;
      }
      out[key] = _redactKeyName.hasMatch(key)
          ? (value is String && value.isNotEmpty ? '***' : redactedValue)
          : redactedValue;
    });
    return changed ? out : args;
  }

  static dynamic _redactValue(dynamic value) {
    if (value is Map) {
      return _redactArgs(Map<String, dynamic>.from(value));
    }
    if (value is List) {
      return [for (final item in value) _redactValue(item)];
    }
    return value;
  }
}
