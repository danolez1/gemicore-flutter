import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

const monthlyId = 'com.example.pro.monthly';

const update = StorePurchaseUpdate(
  productId: monthlyId,
  state: StorePurchaseState.purchased,
  serverVerificationData: 'jws1',
  needsCompletion: true,
);

Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

TransportResponse unavailable(RecordedRequest _) => TransportResponse(
  503,
  jsonEncode({
    'error': {'code': 'PURCHASE_STORE_UNAVAILABLE', 'message': 'try later'},
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() => h = Harness());

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  group('verified identity', () {
    test('configure with an appUserId sends the user token from the provider', () async {
      var asked = 0;
      await h.configure(
        appUserId: 'u1',
        userTokenProvider: () async {
          asked++;
          return 'ut_u1';
        },
      );
      final call = h.transport.calls('POST', '/v1/purchases/customers').single;
      expect(call.headers['x-user-token'], 'ut_u1');
      expect(call.json['externalId'], 'u1');
      expect(asked, 1);
    });

    test('logIn sends it too, and logOut and later calls do not', () async {
      final sdk = await h.configure(userTokenProvider: () async => 'ut_u2');
      h.transport.json('POST', '/v1/purchases/customers/login', session(token: 'tok_2'));
      h.transport.json('POST', '/v1/purchases/customers/logout', session(token: 'tok_3'));
      await sdk.logIn('u2');
      expect(
        h.transport.calls('POST', '/v1/purchases/customers/login').single.headers['x-user-token'],
        'ut_u2',
      );
      await sdk.logOut();
      await sdk.getCustomerInfo(forceRefresh: true);
      expect(
        h.transport.calls('POST', '/v1/purchases/customers/logout').single.headers,
        isNot(contains('x-user-token')),
      );
      expect(
        h.transport.calls('GET', '/v1/purchases/customer').last.headers,
        isNot(contains('x-user-token')),
      );
    });

    test('an anonymous customer needs no token, so the provider is not asked', () async {
      var asked = 0;
      await h.configure(
        userTokenProvider: () async {
          asked++;
          return 'ut';
        },
      );
      expect(asked, 0);
      expect(
        h.transport.calls('POST', '/v1/purchases/customers').single.headers,
        isNot(contains('x-user-token')),
      );
    });

    test('a null token sends no header, so an open mode app still works', () async {
      await h.configure(appUserId: 'u1', userTokenProvider: () async => null);
      expect(
        h.transport.calls('POST', '/v1/purchases/customers').single.headers,
        isNot(contains('x-user-token')),
      );
    });

    test('a provider that throws is an identity error, not a network error', () async {
      await expectLater(
        h.configure(appUserId: 'u1', userTokenProvider: () async => throw StateError('signed out')),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.identityUnverified,
          ),
        ),
      );
      expect(h.transport.calls('POST', '/v1/purchases/customers'), isEmpty);
    });
  });

  group('recording retries', () {
    test('an update that could not be recorded is retried after the delay', () async {
      var attempts = 0;
      h.transport.on('POST', '/v1/purchases', (request) {
        attempts++;
        if (attempts == 1) return unavailable(request);
        return TransportResponse(
          200,
          jsonEncode({'customer': customerJson(pro: true), 'purchase': purchaseJson()}),
        );
      });
      final sdk = await h.configure(recordRetryDelay: const Duration(milliseconds: 20));
      h.store.emit(update);
      await settle(150);
      expect(attempts, 2);
      expect(h.store.completed, hasLength(1));
      expect(sdk.cachedCustomerInfo!.hasEntitlement('pro'), isTrue);
    });

    test('the app coming back to the foreground retries it', () async {
      var attempts = 0;
      h.transport.on('POST', '/v1/purchases', (request) {
        attempts++;
        if (attempts == 1) return unavailable(request);
        return TransportResponse(
          200,
          jsonEncode({'customer': customerJson(pro: true), 'purchase': purchaseJson()}),
        );
      });
      final sdk = await h.configure(recordRetryDelay: const Duration(hours: 1));
      h.store.emit(update);
      await settle();
      expect(attempts, 1);
      sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(attempts, 2);
      expect(h.store.completed, hasLength(1));
    });

    test('a log in retries it', () async {
      var attempts = 0;
      h.transport.on('POST', '/v1/purchases', (request) {
        attempts++;
        if (attempts == 1) return unavailable(request);
        return TransportResponse(
          200,
          jsonEncode({'customer': customerJson(pro: true), 'purchase': purchaseJson()}),
        );
      });
      h.transport.json('POST', '/v1/purchases/customers/login', session(token: 'tok_2'));
      final sdk = await h.configure(recordRetryDelay: const Duration(hours: 1));
      h.store.emit(update);
      await settle();
      await sdk.logIn('u1');
      await settle();
      expect(attempts, 2);
      expect(h.store.completed, hasLength(1));
    });
  });
}
