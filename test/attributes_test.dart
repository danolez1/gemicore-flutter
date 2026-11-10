import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;
  const path = '/v1/purchases/customer/attributes';

  setUp(() {
    h = Harness();
    h.transport.on('PUT', path, (request) {
      final sent = request.json['attributes'] as Map;
      return TransportResponse(
        200,
        '{"attributes":{${sent.entries.where((e) => e.value != null).map((e) => '"${e.key}":"${e.value}"').join(',')}}}',
      );
    });
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  GemicoreException? issue(Object? error) => error is GemicoreException ? error : null;

  test(
    'setAttributes sends the map with the customer token and returns what the server holds',
    () async {
      final sdk = await h.configure();
      final stored = await sdk.setAttributes({'plan_hint': 'family', 'old': null});
      final request = h.transport.calls('PUT', path).single;
      expect(request.json, {
        'attributes': {'plan_hint': 'family', 'old': null},
      });
      expect(request.headers['x-customer-token'], 'tok_1');
      expect(request.headers['content-type'], 'application/json');
      expect(stored, {'plan_hint': 'family'});
    },
  );

  test(
    'setEmail, setDisplayName and setPhoneNumber write the reserved keys, null deletes',
    () async {
      final sdk = await h.configure();
      await sdk.setEmail('ada@example.com');
      await sdk.setDisplayName('Ada');
      await sdk.setPhoneNumber('+15550100');
      await sdk.setEmail(null);
      final sent = h.transport.calls('PUT', path).map((r) => r.json['attributes']).toList();
      expect(sent, [
        {r'$email': 'ada@example.com'},
        {r'$displayName': 'Ada'},
        {r'$phoneNumber': '+15550100'},
        {r'$email': null},
      ]);
    },
  );

  test('more than 50 keys is refused before any request', () async {
    final sdk = await h.configure();
    final many = {for (var i = 0; i < 51; i++) 'k$i': 'v'};
    await expectLater(
      sdk.setAttributes(many),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.invalidAttributes)
            .having((e) => e.details['reason'], 'reason', 'too_many'),
      ),
    );
    expect(h.transport.calls('PUT', path), isEmpty);
    // Exactly 50 is fine.
    await sdk.setAttributes({for (var i = 0; i < 50; i++) 'k$i': 'v'});
    expect(h.transport.calls('PUT', path), hasLength(1));
  });

  test('a key that breaks the pattern is refused without echoing it', () async {
    final sdk = await h.configure();
    for (final key in ['', '1abc', 'has space', 'a' * 41, 'ünï']) {
      Object? caught;
      try {
        await sdk.setAttributes({key: 'x'});
      } catch (error) {
        caught = error;
      }
      final error = issue(caught);
      expect(error, isNotNull, reason: 'key "$key"');
      expect(error!.code, GemicoreErrorCode.invalidAttributes);
      expect(error.details['reason'], 'key_invalid');
      expect(error.message.contains(key) && key.isNotEmpty, isFalse, reason: 'no echo of "$key"');
    }
    expect(h.transport.calls('PUT', path), isEmpty);
  });

  test('keys of 40 characters and the allowed punctuation pass', () async {
    final sdk = await h.configure();
    await sdk.setAttributes({'a' * 40: '1', r'$email': 'a@b.co', 'a.b-c_d': '2'});
    expect(h.transport.calls('PUT', path), hasLength(1));
  });

  test('a dollar key the server does not reserve is refused like the server does', () async {
    final sdk = await h.configure();
    await expectLater(
      sdk.setAttributes({r'$custom': 'x'}),
      throwsA(
        isA<GemicoreException>().having((e) => e.details['reason'], 'reason', 'key_reserved'),
      ),
    );
    expect(h.transport.calls('PUT', path), isEmpty);
  });

  test('a value over 256 characters names the key, never the value', () async {
    final sdk = await h.configure();
    final secret = 'x' * 257;
    Object? caught;
    try {
      await sdk.setAttributes({'bio': secret});
    } catch (error) {
      caught = error;
    }
    final error = issue(caught)!;
    expect(error.code, GemicoreErrorCode.invalidAttributes);
    expect(error.details['reason'], 'value_invalid');
    expect(error.details['field'], 'attributes.bio');
    expect(error.toString().contains(secret), isFalse);
    await sdk.setAttributes({'bio': 'y' * 256});
    expect(h.transport.calls('PUT', path), hasLength(1));
  });

  test('the server refusing the attributes comes back as a typed error', () async {
    h.transport.json('PUT', path, {
      'error': {
        'code': 'PURCHASE_ATTRIBUTES_INVALID',
        'message': 'no',
        'details': {'field': 'attributes', 'reason': 'too_many'},
      },
    }, status: 422);
    final sdk = await h.configure();
    await expectLater(
      sdk.setAttributes({'a': 'b'}),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.attributesInvalid)
            .having((e) => e.statusCode, 'status', 422),
      ),
    );
  });

  test('values are never logged', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    final sdk = await Gemicore.configure(
      apiKey: liveKey,
      baseUrl: 'https://api.test',
      transport: h.transport,
      storage: h.storage,
      store: h.store,
      appVersionProvider: () async => '1.0.0',
      observeAppLifecycle: false,
      logLevel: GemicoreLogLevel.debug,
    );
    h.transport.json('PUT', path, {
      'error': {'code': 'PURCHASE_ATTRIBUTES_INVALID', 'message': 'no'},
    }, status: 422);
    await sdk.setAttributes({'secret_note': 'hunter2-value'}).then((_) {}, onError: (_) {});
    await sdk.setEmail('private@example.com').then((_) {}, onError: (_) {});
    expect(lines.join('\n').contains('hunter2-value'), isFalse);
    expect(lines.join('\n').contains('private@example.com'), isFalse);
  });
}
