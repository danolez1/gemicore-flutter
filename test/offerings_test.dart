import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness();
    h.transport.json('GET', '/v1/purchases/offerings', offeringsJson());
    h.store.catalog.addAll([
      storeDetail(
        'com.example.pro.monthly',
        period: monthly,
        trial: SubscriptionPeriod(7, PeriodUnit.day),
      ),
      storeDetail('com.example.pro.annual', price: '\$39.99', rawPrice: 39.99, period: annual),
    ]);
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  group('getOfferings', () {
    test('parses offerings and merges this device store prices into every package', () async {
      final sdk = await h.configure();
      expect(sdk.currentOffering, isNull, reason: 'nothing is known before the first fetch');
      final offerings = await sdk.getOfferings();
      final request = h.transport.calls('GET', '/v1/purchases/offerings').single;
      expect(request.headers['authorization'], 'Bearer $liveKey');
      expect(request.headers['x-gemicore-platform'], 'ios');

      final current = offerings.current!;
      expect(current.identifier, 'default');
      expect(current.isCurrent, isTrue);
      expect(current.metadata, {'campaign': 'launch'});
      expect(offerings['default'], same(current));
      expect(sdk.currentOffering, same(current));
      expect(current.packages.map((p) => p.identifier), [r'$rc_monthly', r'$rc_annual']);
      expect(current.monthly!.packageType, PackageType.monthly);
      expect(current.annual!.displayName, 'Pro annual');
      expect(current.lifetime, isNull);
      expect(current.package(r'$rc_annual')!.product.priceString, '\$39.99');
      final monthlyProduct = current.monthly!.product;
      expect(monthlyProduct.priceString, '\$4.99');
      expect(monthlyProduct.availableInStore, isTrue);
      expect(monthlyProduct.entitlements, ['pro']);
      expect(current.paywall!.revision, 3);
      expect(current.paywall!.config, isNotNull);
    });

    test('an app with no current offering has a null current and still lists the others', () async {
      h.transport.json('GET', '/v1/purchases/offerings', offeringsJson(current: false));
      final sdk = await h.configure();
      final offerings = await sdk.getOfferings();
      expect(offerings.current, isNull);
      expect(offerings.all.keys, ['default']);
    });

    test('asks the store once for the ids of every package', () async {
      final sdk = await h.configure();
      await sdk.getOfferings();
      expect(h.store.queries, [
        {'com.example.pro.monthly', 'com.example.pro.annual'},
      ]);
    });

    test('answers from memory for five minutes and refetches on demand', () async {
      final sdk = await h.configure();
      final first = await sdk.getOfferings();
      expect(await sdk.getOfferings(), same(first));
      expect(h.transport.calls('GET', '/v1/purchases/offerings'), hasLength(1));
      await sdk.getOfferings(forceRefresh: true);
      expect(h.transport.calls('GET', '/v1/purchases/offerings'), hasLength(2));
    });

    test('refetches once the cache is older than the configured age', () async {
      final sdk = await h.configure(cacheMaxAge: const Duration(milliseconds: 30));
      await sdk.getOfferings();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sdk.getOfferings();
      expect(h.transport.calls('GET', '/v1/purchases/offerings'), hasLength(2));
    });

    test('a start with no network shows the offerings saved on the device', () async {
      final sdk = await h.configure();
      await sdk.getOfferings();
      await sdk.close();

      h.transport.on('GET', '/v1/purchases/offerings', (_) => throw StateError('offline'));
      final restarted = await h.configure();
      final offerings = await restarted.getOfferings();
      expect(offerings.current!.identifier, 'default');
      expect(offerings.current!.monthly!.product.priceString, '\$4.99');
      // The saved copy is not a fresh answer, so the next call tries the network again.
      await restarted.getOfferings();
      expect(h.transport.calls('GET', '/v1/purchases/offerings'), hasLength(3));
    });

    test('keeps showing the last answer when a refresh fails', () async {
      final sdk = await h.configure();
      final first = await sdk.getOfferings();
      h.transport.on('GET', '/v1/purchases/offerings', (_) => throw StateError('offline'));
      expect(await sdk.getOfferings(forceRefresh: true), same(first));
    });

    test('with no saved copy a network failure is an error', () async {
      h.transport.on('GET', '/v1/purchases/offerings', (_) => throw StateError('offline'));
      final sdk = await h.configure();
      await expectLater(
        sdk.getOfferings(),
        throwsA(isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.network)),
      );
    });

    test('an error the network did not cause is not hidden by the saved copy', () async {
      final sdk = await h.configure();
      await sdk.getOfferings();
      h.transport.json('GET', '/v1/purchases/offerings', {
        'error': {'code': 'VALIDATION_ERROR', 'message': 'no'},
      }, status: 422);
      await expectLater(
        sdk.getOfferings(forceRefresh: true),
        throwsA(isA<GemicoreException>().having((e) => e.statusCode, 'status', 422)),
      );
    });

    test('an unreadable saved copy is ignored', () async {
      final sdk = await h.configure();
      await sdk.getOfferings();
      await sdk.close();
      for (final key in h.storage.values.keys.where((k) => k.endsWith('.offerings')).toList()) {
        h.storage.values[key] = '{not json';
      }
      h.transport.on('GET', '/v1/purchases/offerings', (_) => throw StateError('offline'));
      final restarted = await h.configure();
      await expectLater(restarted.getOfferings(), throwsA(isA<GemicoreException>()));
    });

    test('an answer that is not offerings is an invalid response, not a crash', () async {
      h.transport.json('GET', '/v1/purchases/offerings', {
        'current': null,
        'offerings': [
          {'displayName': 'no identifier'},
        ],
      });
      final sdk = await h.configure();
      await expectLater(
        sdk.getOfferings(),
        throwsA(
          isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.invalidResponse),
        ),
      );
    });

    test('a paywall the SDK cannot read leaves the offering usable with no config', () async {
      h.transport.json(
        'GET',
        '/v1/purchases/offerings',
        offeringsJson(paywallConfig: {'version': 9}),
      );
      final sdk = await h.configure();
      final offering = (await sdk.getOfferings()).current!;
      expect(offering.paywall, isNotNull);
      expect(offering.paywall!.config, isNull);
      expect(offering.packages, hasLength(2));
    });

    test('with no store a test key still lists the offerings, without prices', () async {
      h.store.available = false;
      final sdk = await h.configure(apiKey: testKey);
      final monthlyProduct = (await sdk.getOfferings()).current!.monthly!.product;
      expect(monthlyProduct.priceString, isNull);
      expect(monthlyProduct.availableInStore, isFalse);
    });
  });

  group('purchasePackage', () {
    test('buys the package product through the existing purchase path', () async {
      final sdk = await h.configure();
      final package = (await sdk.getOfferings()).current!.annual!;
      h.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(),
      });
      final future = sdk.purchasePackage(package);
      await Future<void>.delayed(Duration.zero);
      expect(h.store.buys.single.productId, 'com.example.pro.annual');
      expect(h.store.buys.single.accountId, customerId);
      expect(h.store.buys.single.offer, isNull);
      h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.annual',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'jws-annual',
          needsCompletion: true,
        ),
      );
      final result = await future;
      expect(result.isCompleted, isTrue);
      expect(result.customerInfo!.hasEntitlement('pro'), isTrue);
      expect(
        (jsonDecode(h.transport.calls('POST', '/v1/purchases').single.body!)
            as Map)['signedTransaction'],
        'jws-annual',
      );
    });

    test('in the test store a package is recorded by its product identifier', () async {
      h.store.available = false;
      h.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(store: 'test_store'),
      });
      final sdk = await h.configure(apiKey: testKey);
      final package = (await sdk.getOfferings()).current!.monthly!;
      final result = await sdk.purchasePackage(package);
      expect(result.isCompleted, isTrue);
      expect(h.transport.calls('POST', '/v1/purchases').single.json, {
        'store': 'test_store',
        'productId': 'pro_monthly',
      });
    });
  });

  test('openUrl goes through the injectable opener', () async {
    final sdk = await h.configure();
    expect(await sdk.openUrl(Uri.parse('https://example.com/terms')), isTrue);
    expect(h.opener.opened.single.toString(), 'https://example.com/terms');
  });
}
