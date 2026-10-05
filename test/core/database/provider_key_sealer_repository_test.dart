import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/services/key_vault/key_vault.dart';

void main() {
  late AppDatabase database;
  late BusinessRepository repository;
  final sealedPlatform = KeyVault.instance.isSupported;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = BusinessRepository(database);
    await database.customSelect('SELECT 1;').getSingle();
  });

  tearDown(() => database.close());

  BusinessEntityValue providerRow(
    String id, {
    String key = 'sk-secret-1',
    List<String> keys = const <String>[],
  }) => BusinessEntityValue(
    id: id,
    sortOrder: 0,
    payload: jsonEncode({
      'id': id,
      'name': 'provider-$id',
      'apiKey': key,
      'apiKeys': keys,
    }),
  );

  Future<String> rawPayload(String id) async {
    final rows = await database
        .customSelect(
          'SELECT payload FROM provider_rows WHERE provider_key = ?;',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.single.read<String>('payload');
  }

  Future<int> rawUpdatedAt(String id) async {
    final rows = await database
        .customSelect(
          'SELECT updated_at FROM provider_rows WHERE provider_key = ?;',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.single.read<int>('updated_at');
  }

  test('credentials are sealed at rest and read back as plaintext', () async {
    await repository.upsertEntity(
      BusinessEntityKind.provider,
      providerRow('p1', key: 'sk-abc', keys: const ['sk-def']),
    );

    final read = await repository.readEntities(BusinessEntityKind.provider);
    expect(read, hasLength(1));
    expect(read.first.payload, contains('sk-abc'));
    expect(read.first.payload, contains('sk-def'));

    final raw = await rawPayload('p1');
    if (sealedPlatform) {
      expect(raw, contains('dpapi:v1:'));
      expect(raw, isNot(contains('sk-abc')));
      expect(raw, isNot(contains('sk-def')));
    } else {
      expect(raw, contains('sk-abc'));
      expect(raw, contains('sk-def'));
    }
  });

  test('re-saving identical credentials does not rewrite the row', () async {
    await repository.upsertEntity(
      BusinessEntityKind.provider,
      providerRow('p1', key: 'sk-abc'),
    );
    final before = await rawUpdatedAt('p1');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await repository.synchronizeEntities(BusinessEntityKind.provider, [
      providerRow('p1', key: 'sk-abc'),
    ]);

    expect(await rawUpdatedAt('p1'), before);
  });

  test('changing one provider leaves other sealed rows untouched', () async {
    await repository.upsertEntity(
      BusinessEntityKind.provider,
      providerRow('p1', key: 'sk-abc'),
    );
    await repository.upsertEntity(
      BusinessEntityKind.provider,
      providerRow('p2', key: 'sk-xyz'),
    );
    final p1Before = await rawUpdatedAt('p1');

    await repository.synchronizeEntities(BusinessEntityKind.provider, [
      providerRow('p1', key: 'sk-abc'),
      providerRow('p2', key: 'sk-rotated'),
    ]);

    expect(await rawUpdatedAt('p1'), p1Before);
    final read = await repository.readEntities(BusinessEntityKind.provider);
    final payloads = {for (final row in read) row.id: row.payload};
    expect(payloads['p2'], contains('sk-rotated'));
  });

  test('startup migration seals legacy plaintext rows', () async {
    await database.customStatement(
      'INSERT INTO provider_rows (provider_key, sort_order, payload, updated_at) '
      'VALUES (?, ?, ?, ?);',
      <Object?>[
        'p1',
        0,
        jsonEncode({'id': 'p1', 'apiKey': 'sk-legacy'}),
        1,
      ],
    );

    await repository.sealProviderKeysAtRest();

    final read = await repository.readEntities(BusinessEntityKind.provider);
    expect(read.single.payload, contains('sk-legacy'));
    final raw = await rawPayload('p1');
    if (sealedPlatform) {
      expect(raw, contains('dpapi:v1:'));
      expect(raw, isNot(contains('sk-legacy')));
    } else {
      expect(raw, contains('sk-legacy'));
    }

    // Second run is a no-op.
    await repository.sealProviderKeysAtRest();
    final readAgain = await repository.readEntities(BusinessEntityKind.provider);
    expect(readAgain.single.payload, contains('sk-legacy'));
  });

  test('undecryptable sealed blob fails closed to empty credential', () async {
    await database.customStatement(
      'INSERT INTO provider_rows (provider_key, sort_order, payload, updated_at) '
      'VALUES (?, ?, ?, ?);',
      <Object?>[
        'p1',
        0,
        jsonEncode({'id': 'p1', 'apiKey': 'dpapi:v1:not-a-real-blob'}),
        1,
      ],
    );

    final read = await repository.readEntities(BusinessEntityKind.provider);
    if (sealedPlatform) {
      expect(read.single.payload, contains('"apiKey":""'));
      expect(read.single.payload, isNot(contains('dpapi:v1')));
    } else {
      expect(read.single.payload, contains('dpapi:v1:not-a-real-blob'));
    }
  });

  test('non-provider kinds never carry credential transforms', () async {
    await repository.upsertEntity(
      BusinessEntityKind.providerGroup,
      BusinessEntityValue(
        id: 'g1',
        sortOrder: 0,
        payload: jsonEncode({'id': 'g1', 'apiKey': 'sk-not-a-credential'}),
      ),
    );
    final raw = await database
        .customSelect('SELECT payload FROM provider_group_rows;')
        .getSingle();
    expect(raw.read<String>('payload'), contains('sk-not-a-credential'));
  });
}
