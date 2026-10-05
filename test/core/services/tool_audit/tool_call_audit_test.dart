import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/tool_audit/tool_call_audit.dart';

void main() {
  late Directory tempDir;
  late Directory auditDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tool_audit_test');
    auditDir = Directory(
      [tempDir.path, 'tool_audit'].join(Platform.pathSeparator),
    );
    ToolCallAudit.directoryResolverOverride = () => tempDir;
  });

  tearDown(() async {
    ToolCallAudit.directoryResolverOverride = () => null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String auditFileStamp() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return 'audit-${now.year}$mm$dd.jsonl';
  }

  Future<List<String>> readLines() async {
    final file = File(
      [auditDir.path, auditFileStamp()].join(Platform.pathSeparator),
    );
    for (var attempt = 0; attempt < 40; attempt++) {
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) return text.trim().split('\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('audit file never appeared');
  }

  test('records ok and denied statuses as JSONL with safe payloads', () async {
    ToolCallAudit.record(
      tool: 'mcp__gateway__phone_shell',
      arguments: {'command': 'dumpsys battery'},
      toolCallId: 'call-1',
      conversationId: 'conv-1',
      elapsedMs: 12,
      status: 'ok',
    );
    ToolCallAudit.record(
      tool: 'phone_install',
      arguments: {'apk_path': r'C:\tmp\a.apk'},
      conversationId: 'conv-1',
      elapsedMs: 3,
      status: 'error:approval_denied',
      error: 'User denied the tool call',
    );

    final lines = await readLines();
    expect(lines, hasLength(2));
    final first = jsonDecode(lines[0]) as Map<String, dynamic>;
    expect(first['tool'], 'mcp__gateway__phone_shell');
    expect(first['status'], 'ok');
    expect(first['conversationId'], 'conv-1');
    expect(first['elapsedMs'], 12);
    final second = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(second['status'], 'error:approval_denied');
    expect(second['error'], 'User denied the tool call');
  });

  test('oversized arguments are truncated', () async {
    ToolCallAudit.record(
      tool: 't',
      arguments: {'blob': 'x' * 2000},
      elapsedMs: 1,
      status: 'ok',
    );
    final lines = await readLines();
    expect((jsonDecode(lines[0]) as Map)['args'].length, 401);
  });

  test('statusOf classifies tool error maps', () {
    expect(ToolCallAudit.statusOf('plain'), 'ok');
    expect(
      ToolCallAudit.statusOf({'error': 'approval_denied'}),
      'error:approval_denied',
    );
    expect(ToolCallAudit.statusOf({'error': ''}), 'ok');
  });
}
