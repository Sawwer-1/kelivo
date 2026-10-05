import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/services/key_vault/key_vault.dart';

/// Regression for the startup at-rest seal: plain keys get sealed, already
/// sealed rows stay untouched, empty keys are ignored (no DPAPI on them).
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

  Future<void> seedProvider(String id, String payload) async {
    await database.customStatement(
      'INSERT INTO provider_rows (provider_key, sort_order, payload, '
      'updated_at) VALUES (?, ?, ?, ?);',
      <Object?>[id, 0, payload, 1],
    );
  }

  Future<String> payloadOf(String id) async {
    final rows = await database
        .customSelect(
          'SELECT payload FROM provider_rows WHERE provider_key = ?;',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.single.read<String>('payload');
  }

  test('routine seals plain, keeps sealed, skips empty keys', () async {
    await seedProvider('p1', '{"id":"p1","apiKey":"sk-plain"}');
    await seedProvider('p2', '{"id":"p2","apiKey":"dpapi:v1:AAAA"}');
    await seedProvider('p3', '{"id":"p3","apiKey":""}');

    await repository.sealProviderKeysAtRest();

    final p1 = await payloadOf('p1');
    final p2 = await payloadOf('p2');
    final p3 = await payloadOf('p3');
    if (sealedPlatform) {
      expect(p1, contains('dpapi:v1:'));
      expect(p1, isNot(contains('sk-plain')));
    } else {
      expect(p1, contains('sk-plain'));
    }
    expect(p2, contains('dpapi:v1:AAAA'));
    expect(p3, contains('"apiKey":""'));

    // Second run is a no-op.
    await repository.sealProviderKeysAtRest();
    expect(await payloadOf('p1'), p1);
  });
}
