import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

// The server resolves a placement per customer, so no offerings copy may outlive the customer or
// the attributes it was resolved for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;
  const path = '/v1/purchases/offerings';
  const attributesPath = '/v1/purchases/customer/attributes';

  Map<String, Object?> answer(String current) {
    final base = offeringsJson();
    final first = ((base['offerings'] as List).first as Map).cast<String, Object?>();
    return {
      ...base,
      'current': current,
      'offerings': [
        {...first, 'identifier': current},
      ],
    };
  }

  setUp(() {
    h = Harness();
    h.transport.json('GET', path, answer('variant_a'));
    h.transport.json(
      'POST',
      '/v1/purchases/customers/logout',
      session(
        token: 'tok_anon',
        customer: customerJson(id: 'cus_other'),
      ),
    );
    h.transport.json(
      'POST',
      '/v1/purchases/customers/login',
      session(
        token: 'tok_user',
        customer: customerJson(id: 'cus_user', externalId: 'user-1'),
      ),
    );
    h.transport.json('PUT', attributesPath, {'attributes': <String, Object?>{}});
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  test('logOut drops the memory copy of the old customer', () async {
    final sdk = await h.configure();
    expect((await sdk.getOfferings(placement: 'onboarding')).current!.identifier, 'variant_a');
    h.transport.json('GET', path, answer('variant_b'));
    await sdk.logOut();
    expect((await sdk.getOfferings(placement: 'onboarding')).current!.identifier, 'variant_b');
    expect(sdk.currentOffering, isNull);
  });

  test('logIn into another customer drops the memory copy', () async {
    final sdk = await h.configure();
    await sdk.getOfferings();
    h.transport.json('GET', path, answer('variant_b'));
    await sdk.logIn('user-1');
    expect((await sdk.getOfferings()).current!.identifier, 'variant_b');
  });

  test('setAttributes drops the memory copy so a rule can match', () async {
    final sdk = await h.configure();
    await sdk.getOfferings(placement: 'onboarding');
    h.transport.json('GET', path, answer('variant_b'));
    await sdk.setAttributes({'plan_hint': 'family'});
    expect((await sdk.getOfferings(placement: 'onboarding')).current!.identifier, 'variant_b');
  });

  test('a failed setAttributes keeps the copy', () async {
    final sdk = await h.configure();
    final first = await sdk.getOfferings();
    h.transport.json('PUT', attributesPath, {'error': 'x'}, status: 500);
    await expectLater(sdk.setAttributes({'a': 'b'}), throwsA(isA<GemicoreException>()));
    expect(await sdk.getOfferings(), same(first));
  });

  test('the copy on the device is not shown to another customer when offline', () async {
    final sdk = await h.configure();
    await sdk.getOfferings(placement: 'onboarding');
    await sdk.logOut();
    h.transport.on('GET', path, (_) => throw StateError('offline'));
    await expectLater(
      sdk.getOfferings(placement: 'onboarding'),
      throwsA(isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.network)),
    );
  });

  test('the copy on the device still serves the same customer after a restart', () async {
    final sdk = await h.configure();
    await sdk.getOfferings(placement: 'onboarding');
    await sdk.close();
    h.transport.on('GET', path, (_) => throw StateError('offline'));
    final again = await h.configure();
    expect((await again.getOfferings(placement: 'onboarding')).current!.identifier, 'variant_a');
  });

  test('setAttributes also drops the copy on the device', () async {
    final sdk = await h.configure();
    await sdk.getOfferings(placement: 'onboarding');
    await sdk.setAttributes({'plan_hint': 'family'});
    h.transport.on('GET', path, (_) => throw StateError('offline'));
    await expectLater(sdk.getOfferings(placement: 'onboarding'), throwsA(isA<GemicoreException>()));
  });

  test(
    'an offline first read of a placement shows the app offerings saved on the device',
    () async {
      final sdk = await h.configure();
      await sdk.getOfferings();
      await sdk.close();
      h.transport.on('GET', path, (_) => throw StateError('offline'));
      final again = await h.configure();
      final offerings = await again.getOfferings(placement: 'onboarding');
      expect(offerings.current!.identifier, 'variant_a');
      expect(jsonEncode(offerings.placement?.identifier), 'null');
    },
  );
}
