import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/memory_entry.dart';
import 'package:Kelivo/core/services/memory/memory_repository.dart';

void main() {
  late AppDatabase database;
  late ChatDatabaseRepository chatRepository;
  late MemoryRepository memoryRepository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    chatRepository = ChatDatabaseRepository(database);
    memoryRepository = MemoryRepository(
      BusinessPreferences(BusinessRepository(database)),
    );
  });

  tearDown(() => database.close());

  Future<void> seedEntry(
    String id, {
    MemoryScope scope = MemoryScope.assistant,
    String? assistantId = 'a1',
    String? conversationId,
    String content = 'c',
    MemoryType type = MemoryType.workflow,
  }) async {
    final entry = MemoryEntry(
      id: id,
      scope: scope,
      assistantId: assistantId,
      conversationId: conversationId,
      type: type,
      content: content,
      source: MemorySource.manual,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await database.customStatement(
      'INSERT INTO memory_entry_rows '
      '(id, sort_order, scope, assistant_id, type, status, content, '
      'content_normalized, entry_created_at, entry_updated_at, payload, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        entry.id,
        0,
        MemoryEntry.scopeToString(entry.scope),
        entry.assistantId,
        MemoryEntry.typeToString(entry.type),
        'active',
        entry.content,
        MemoryEntry.normalizeContent(entry.content),
        entry.createdAt.microsecondsSinceEpoch,
        entry.updatedAt.microsecondsSinceEpoch,
        jsonEncode(entry.toPayload()),
        1,
      ],
    );
  }

  List<String> ids(List<MemoryEntry> entries) =>
      entries.map((e) => e.id).toList();

  test('payload round trip keeps conversationId', () {
    final stamp = DateTime.utc(2026, 1, 1);
    final entry = MemoryEntry(
      id: 'mem_1',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      conversationId: 'conv-9',
      type: MemoryType.workflow,
      content: 'likes tea',
      createdAt: stamp,
      updatedAt: stamp,
    );
    final restored = MemoryEntry.fromPayload(entry.toPayload());
    expect(restored.conversationId, 'conv-9');
  });

  test('unbound payloads stay backward compatible', () {
    final entry = MemoryEntry.fromPayload({
      'id': 'mem_2',
      'scope': 'global',
      'type': 'workflow',
      'content': 'c',
      'createdAt': 0,
      'updatedAt': 0,
    });
    expect(entry.conversationId, isNull);
  });

  test('create rejects conversation binding without assistant scope', () async {
    await expectLater(
      memoryRepository.create(
        scope: MemoryScope.global,
        conversationId: 'conv-1',
        type: MemoryType.workflow,
        content: 'x',
        source: MemorySource.manual,
      ),
      throwsArgumentError,
    );
  });

  test('dedup key separates the same content across conversations', () async {
    final a = await memoryRepository.create(
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      conversationId: 'conv-1',
      type: MemoryType.workflow,
      content: 'same text',
      source: MemorySource.manual,
    );
    final b = await memoryRepository.create(
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      conversationId: 'conv-2',
      type: MemoryType.workflow,
      content: 'same text',
      source: MemorySource.manual,
    );
    expect(a.id, isNot(b.id));
  });

  test('query filters conversation-bound entries per conversation', () async {
    await seedEntry('g1', scope: MemoryScope.global, assistantId: null);
    await seedEntry('a1');
    await seedEntry('c1', conversationId: 'conv-1');
    await seedEntry('c2', conversationId: 'conv-2');

    // Injection for conv-1: unbound + its own bound entries.
    final forConv1 = await chatRepository.queryVisibleMemories(
      assistantId: 'a1',
      conversationId: 'conv-1',
    );
    expect(ids(forConv1), containsAll(['g1', 'a1', 'c1']));
    expect(ids(forConv1), isNot(contains('c2')));

    // No conversation context (detached prep): bound entries stay hidden.
    final detached = await chatRepository.queryVisibleMemories(
      assistantId: 'a1',
      excludeConversationBound: true,
    );
    expect(ids(detached), containsAll(['g1', 'a1']));
    expect(ids(detached), isNot(contains('c1')));

    // No filtering at all (management UI): everything visible.
    final all = await chatRepository.queryVisibleMemories(assistantId: 'a1');
    expect(ids(all), containsAll(['g1', 'a1', 'c1', 'c2']));
  });

  test('write scope enum round trips perConversation', () {
    const scope = MemoryWriteScope.perConversation;
    expect(
      Assistant.memoryWriteScopeFromString(
        Assistant.memoryWriteScopeToString(scope),
      ),
      scope,
    );
    // Older app versions reading the new value fall back safely.
    expect(
      Assistant.memoryWriteScopeFromString('unknown-future-value'),
      MemoryWriteScope.alwaysGlobal,
    );
  });
}
