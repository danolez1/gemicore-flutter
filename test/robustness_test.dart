import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

const monthlyId = 'com.example.pro.monthly';

StorePurchaseUpdate purchased([String data = 'jws1']) => StorePurchaseUpdate(
  productId: monthlyId,
  state: StorePurchaseState.purchased,
  serverVerificationData: data,
  needsCompletion: true,
);

Map<String, Object?> recorded() => {
  'customer': customerJson(pro: true),
  'purchase': purchaseJson(),
};

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() => h = Harness());

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  group('startup', () {
    test('a store update that arrives during start waits for the customer token', () async {
      h.transport.on('POST', '/v1/purchases/customers', (_) {
        // Delivered while configure is still creating the customer, like an interrupted purchase.
        h.store.emit(purchased());
        return TransportResponse(201, jsonEncode(session()));
      });
      h.transport.on('POST', '/v1/purchases', (request) {
        if (request.headers['x-customer-token'] == null) {
          return TransportResponse(
            401,
            jsonEncode({
              'error': {'code': 'PURCHASE_CUSTOMER_TOKEN_INVALID', 'message': 'no token'},
            }),
          );
        }
        return TransportResponse(200, jsonEncode(recorded()));
      });
      await h.configure();
      await settle();
      final calls = h.transport.calls('POST', '/v1/purchases');
      expect(calls, hasLength(1));
      expect(calls.single.headers['x-customer-token'], 'tok_1');
      expect(h.store.completed, hasLength(1));
    });

    test('a configure that fails does not leave a second listener behind', () async {
      h.transport.json('POST', '/v1/purchases/customers', {
        'error': {'code': 'PURCHASE_STORE_NOT_CONFIGURED', 'message': 'no'},
      }, status: 400);
      await expectLater(h.configure(), throwsA(isA<GemicoreException>()));
      h.transport.json('POST', '/v1/purchases/customers', session(), status: 201);
      h.transport.json('POST', '/v1/purchases', recorded());
      await h.configure();
      h.store.emit(purchased());
      await settle();
      expect(h.transport.calls('POST', '/v1/purchases'), hasLength(1));
      expect(h.store.completed, hasLength(1));
    });
  });

  group('cache write failures', () {
    test('a failing cache write does not fail a recorded purchase', () async {
      final storage = FlakyStorage();
      h.store.catalog.add(storeDetail(monthlyId));
      final sdk = await h.configure(storage: storage);
      h.transport.json('POST', '/v1/purchases', recorded());
      final product = (await sdk.getProducts()).first;
      final future = sdk.purchase(product);
      await settle();
      storage.failWrites = true;
      h.store.emit(purchased());
      final result = await future;
      expect(result.isCompleted, isTrue);
    });

    test('getCustomerInfo survives a failing cache write', () async {
      final storage = FlakyStorage();
      final sdk = await h.configure(storage: storage);
      storage.failWrites = true;
      h.transport.json('GET', '/v1/purchases/customer', customerJson(pro: true));
      final info = await sdk.getCustomerInfo(forceRefresh: true);
      expect(info.activeEntitlements, contains('pro'));
    });
  });

  group('entitlement expiry from the cache', () {
    Map<String, Object?> withExpiry(String? expiresAt, {List<Map<String, Object?>>? purchases}) {
      final json = customerJson(pro: true, purchases: purchases ?? const []);
      final entitlements = json['entitlements']! as Map<String, Object?>;
      for (final set in ['active', 'all']) {
        final entry = (entitlements[set]! as Map<String, Object?>)['pro']! as Map<String, Object?>;
        entry['expiresAt'] = expiresAt;
      }
      return json;
    }

    test('an entitlement whose expiry passed is not active, whatever the cached flag says', () {
      final past = DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String();
      expect(CustomerInfo.fromJson(withExpiry(past)).hasEntitlement('pro'), isFalse);
    });

    test('an entitlement with a future or no expiry stays active', () {
      final future = DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String();
      expect(CustomerInfo.fromJson(withExpiry(future)).hasEntitlement('pro'), isTrue);
      expect(CustomerInfo.fromJson(withExpiry(null)).hasEntitlement('pro'), isTrue);
    });

    test('a purchase still inside its grace period keeps the entitlement', () {
      final past = DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String();
      final grace = DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String();
      final info = CustomerInfo.fromJson(
        withExpiry(
          past,
          purchases: [
            {...purchaseJson(status: 'in_grace_period'), 'gracePeriodExpiresAt': grace},
          ],
        ),
      );
      expect(info.hasEntitlement('pro'), isTrue);
    });
  });

  group('store availability', () {
    test('a store that was unavailable once is asked again', () async {
      h.store.available = false;
      h.store.catalog.add(storeDetail(monthlyId));
      final sdk = await h.configure();
      expect((await sdk.getProducts()).first.priceString, isNull);
      h.store.available = true;
      expect((await sdk.getProducts()).first.priceString, isNotNull);
    });

    test('a test key does not fall back to the test store because the store check threw', () async {
      h.store.availabilityError = StateError('billing not connected');
      final sdk = await h.configure(apiKey: testKey);
      final product = (await sdk.getProducts()).first;
      await expectLater(sdk.purchase(product), throwsA(isA<GemicoreException>()));
      expect(h.transport.calls('POST', '/v1/purchases'), isEmpty);
    });
  });

  group('polling', () {
    Map<String, Object?> pendingCard() =>
        purchaseJson(id: 'card1', status: 'pending', isActive: false, store: 'card');

    Future<(Gemicore, GemicoreProduct)> start() async {
      h.transport.json('GET', '/v1/purchases/products', productsJson);
      final sdk = await h.configure();
      final tshirt = (await sdk.getProducts()).last;
      h.transport.json('POST', '/v1/purchases/checkout', {
        'paymentId': 'p',
        'url': 'https://x.test/c',
        'purchase': pendingCard(),
      });
      return (sdk, tshirt);
    }

    test('polls that bring nothing new do not emit or rewrite the cache', () async {
      final (sdk, tshirt) = await start();
      var counter = 0;
      h.transport.on('GET', '/v1/purchases/customer', (_) {
        counter++;
        // The server stamps every answer, so only the data decides what changed.
        final json = customerJson(purchases: [pendingCard()])
          ..['requestedAt'] = '2026-11-04T12:00:${counter.toString().padLeft(2, '0')}.000Z';
        return TransportResponse(200, jsonEncode(json));
      });
      final emitted = <CustomerInfo>[];
      final sub = sdk.customerInfoStream.listen(emitted.add);
      final result = await sdk.payWithCard(
        tshirt,
        email: 'b@example.com',
        timeout: const Duration(milliseconds: 80),
        pollInterval: const Duration(milliseconds: 5),
      );
      await sub.cancel();
      expect(result.isPending, isTrue);
      expect(counter, greaterThan(3));
      expect(emitted.length, lessThanOrEqualTo(1));
    });

    test('a failed payment is an error, not a cancelled result', () async {
      final (sdk, tshirt) = await start();
      h.transport.json(
        'GET',
        '/v1/purchases/customer',
        customerJson(
          purchases: [
            {...pendingCard(), 'status': 'failed'},
          ],
        ),
      );
      await expectLater(
        sdk.payWithCard(
          tshirt,
          email: 'b@example.com',
          pollInterval: const Duration(milliseconds: 5),
        ),
        throwsA(isA<GemicoreException>()),
      );
    });

    test('the caller can stop the wait', () async {
      final (sdk, tshirt) = await start();
      h.transport.json('GET', '/v1/purchases/customer', customerJson(purchases: [pendingCard()]));
      final stop = Completer<void>();
      final future = sdk.payWithCard(
        tshirt,
        email: 'b@example.com',
        pollInterval: const Duration(milliseconds: 5),
        cancel: stop.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      stop.complete();
      final result = await future.timeout(const Duration(seconds: 2));
      expect(result.isCancelled, isTrue);
    });
  });

  group('restore', () {
    test('two restores at once share one run', () async {
      h.store.restoreEmits = [
        const StorePurchaseUpdate(
          productId: monthlyId,
          state: StorePurchaseState.restored,
          serverVerificationData: 'jwsR',
          needsCompletion: true,
        ),
      ];
      h.transport.json('POST', '/v1/purchases/restore', {'customer': customerJson(pro: true)});
      final sdk = await h.configure();
      final first = sdk.restorePurchases();
      final second = sdk.restorePurchases();
      final results = await Future.wait([first, second]);
      expect(results[0].hasEntitlement('pro'), isTrue);
      expect(results[1].hasEntitlement('pro'), isTrue);
      expect(h.store.restores, hasLength(1));
      expect(h.transport.calls('POST', '/v1/purchases/restore'), hasLength(1));
    });
  });
}
