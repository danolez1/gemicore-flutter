import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

const offersBody = {
  'offers': [
    {
      'identifier': 'winter',
      'kind': 'promotional',
      'displayName': 'Winter sale',
      'appleOfferIdentifier': 'winter_apple',
      'googleOfferId': 'winter-play',
      'eligibility': 'existing_subscriber',
    },
    {
      'identifier': 'comeback',
      'kind': 'win_back',
      'displayName': 'Come back',
      'appleOfferIdentifier': 'comeback_apple',
      'googleOfferId': null,
      'eligibility': 'lapsed_subscriber',
    },
    {
      'identifier': 'code',
      'kind': 'offer_code',
      'displayName': 'Code',
      'appleOfferIdentifier': 'code_apple',
      'googleOfferId': null,
      'eligibility': 'anyone',
    },
    {
      'identifier': 'free_week',
      'kind': 'intro',
      'displayName': 'Free week',
      'appleOfferIdentifier': null,
      'googleOfferId': null,
      'eligibility': 'anyone',
    },
  ],
};

const signatureBody = {
  'productId': 'com.example.pro.monthly',
  'offerIdentifier': 'winter_apple',
  'signature': 'eyJ.storekit2.jws',
  'legacy': {
    'keyIdentifier': 'KEY123',
    'nonce': '2b1b4d8e-5f4a-4c6b-8f0e-0a1b2c3d4e5f',
    'timestamp': 1793800000000,
    'signature': 'MEUCIQ==',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness();
    h.store.catalog.add(storeDetail('com.example.pro.monthly', period: monthly));
    h.transport.json('GET', '/v1/purchases/offers', offersBody);
    h.transport.json('POST', '/v1/purchases', {
      'customer': customerJson(pro: true),
      'purchase': purchaseJson(),
    });
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Future<GemicoreProduct> proMonthly(Gemicore sdk) async =>
      (await sdk.getProducts()).firstWhere((p) => p.identifier == 'pro_monthly');

  Future<List<ProductOffer>> offers(Gemicore sdk, GemicoreProduct product) =>
      sdk.getEligibleOffers(product);

  Future<void> deliverPurchase(String storeId) async {
    await Future<void>.delayed(Duration.zero);
    h.store.emit(
      StorePurchaseUpdate(
        productId: storeId,
        state: StorePurchaseState.purchased,
        serverVerificationData: 'jws',
        needsCompletion: true,
      ),
    );
  }

  group('getEligibleOffers', () {
    test('asks for the catalog identifier and parses every offer kind', () async {
      final sdk = await h.configure();
      final found = await offers(sdk, await proMonthly(sdk));
      final request = h.transport.calls('GET', '/v1/purchases/offers').single;
      expect(request.url.queryParameters, {'productId': 'pro_monthly'});
      expect(request.headers['x-customer-token'], 'tok_1');
      expect(found.map((o) => o.kind), [
        OfferKind.promotional,
        OfferKind.winBack,
        OfferKind.offerCode,
        OfferKind.intro,
      ]);
      expect(found[0].identifier, 'winter');
      expect(found[0].appleOfferIdentifier, 'winter_apple');
      expect(found[0].googleOfferId, 'winter-play');
      expect(found[0].eligibility, OfferEligibility.existingSubscriber);
      expect(found[1].eligibility, OfferEligibility.lapsedSubscriber);
      expect(found[3].appleOfferIdentifier, isNull);
    });

    test('a server refusal reaches the caller with its code', () async {
      h.transport.json('GET', '/v1/purchases/offers', {
        'error': {'code': 'PURCHASE_PRODUCT_UNKNOWN', 'message': 'no'},
      }, status: 404);
      final sdk = await h.configure();
      await expectLater(
        offers(sdk, await proMonthly(sdk)),
        throwsA(
          isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.productUnknown),
        ),
      );
    });
  });

  group('purchase with an offer on iOS', () {
    test('a promotional offer is signed by the server and passed to the store', () async {
      h.transport.json('POST', '/v1/purchases/apple/promotional-offer', signatureBody);
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final winter = (await offers(sdk, product)).first;
      final future = sdk.purchase(product, offer: winter);
      await deliverPurchase('com.example.pro.monthly');
      expect((await future).isCompleted, isTrue);

      final sign = h.transport.calls('POST', '/v1/purchases/apple/promotional-offer').single;
      expect(sign.json, {'productId': 'pro_monthly', 'offerId': 'winter'});
      final promo = h.store.buys.single.offer!.promotional!;
      expect(promo.offerId, 'winter_apple');
      expect(promo.keyId, 'KEY123');
      expect(promo.nonce, '2b1b4d8e-5f4a-4c6b-8f0e-0a1b2c3d4e5f');
      expect(promo.timestamp, 1793800000000);
      expect(promo.signature, 'MEUCIQ==');
      expect(h.store.buys.single.offer!.winBackOfferId, isNull);
    });

    test('a signature with no legacy block cannot be used and starts no purchase', () async {
      h.transport.json('POST', '/v1/purchases/apple/promotional-offer', {
        ...signatureBody,
        'legacy': null,
      });
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final winter = (await offers(sdk, product)).first;
      await expectLater(
        sdk.purchase(product, offer: winter),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.offerNotSupported,
          ),
        ),
      );
      expect(h.store.buys, isEmpty);
    });

    test('a refused signature is the server error and leaves nothing in progress', () async {
      h.transport.json('POST', '/v1/purchases/apple/promotional-offer', {
        'error': {'code': 'PURCHASE_NOT_ELIGIBLE', 'message': 'no'},
      }, status: 403);
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final winter = (await offers(sdk, product)).first;
      await expectLater(
        sdk.purchase(product, offer: winter),
        throwsA(
          isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.notEligible),
        ),
      );
      expect(h.store.buys, isEmpty);
      // The failed attempt must not block the next one with "already in progress".
      final retry = sdk.purchase(product);
      await deliverPurchase('com.example.pro.monthly');
      expect((await retry).isCompleted, isTrue);
    });

    test('a win-back offer needs no signature, the store checks it', () async {
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final comeback = (await offers(sdk, product))[1];
      final future = sdk.purchase(product, offer: comeback);
      await deliverPurchase('com.example.pro.monthly');
      await future;
      expect(h.transport.calls('POST', '/v1/purchases/apple/promotional-offer'), isEmpty);
      expect(h.store.buys.single.offer!.winBackOfferId, 'comeback_apple');
      expect(h.store.buys.single.offer!.promotional, isNull);
    });

    test('an offer code is redeemed in the store, so purchase refuses it', () async {
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final code = (await offers(sdk, product))[2];
      await expectLater(
        sdk.purchase(product, offer: code),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.offerNotSupported,
          ),
        ),
      );
      expect(h.store.buys, isEmpty);
    });

    test('an introductory offer uses Apple default eligibility and no server call', () async {
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final intro = (await offers(sdk, product))[3];
      final future = sdk.purchase(product, offer: intro);
      await deliverPurchase('com.example.pro.monthly');
      await future;
      expect(h.store.buys.single.offer, isNull);
      expect(h.transport.calls('POST', '/v1/purchases/apple/introductory-eligibility'), isEmpty);
    });

    test('a plain purchase never calls the introductory eligibility route', () async {
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final future = sdk.purchase(product);
      await deliverPurchase('com.example.pro.monthly');
      await future;
      expect(h.store.buys.single.offer, isNull);
      expect(h.transport.requests.where((r) => r.url.path.contains('introductory')), isEmpty);
    });

    test('useServerIntroEligibility passes the signed JWS to the store', () async {
      h.transport.json('POST', '/v1/purchases/apple/introductory-eligibility', {
        'productId': 'com.example.pro.monthly',
        'allowIntroductoryOffer': false,
        'signature': 'eyJ.intro.jws',
      });
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      final future = sdk.purchase(product, useServerIntroEligibility: true);
      await deliverPurchase('com.example.pro.monthly');
      await future;
      expect(
        h.transport.calls('POST', '/v1/purchases/apple/introductory-eligibility').single.json,
        {'productId': 'pro_monthly'},
      );
      expect(h.store.buys.single.offer!.introductoryEligibilityJws, 'eyJ.intro.jws');
    });

    test('the opt in with a failing server route stops before the store sheet', () async {
      h.transport.json('POST', '/v1/purchases/apple/introductory-eligibility', {
        'error': {'code': 'PURCHASE_STORE_NOT_CONFIGURED', 'message': 'no key'},
      }, status: 409);
      final sdk = await h.configure();
      final product = await proMonthly(sdk);
      await expectLater(
        sdk.purchase(product, useServerIntroEligibility: true),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.storeNotConfigured,
          ),
        ),
      );
      expect(h.store.buys, isEmpty);
    });

    test('in the test store an offer is ignored', () async {
      h.store.available = false;
      h.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(store: 'test_store'),
      });
      final sdk = await h.configure(apiKey: testKey);
      final product = await proMonthly(sdk);
      final result = await sdk.purchase(
        product,
        offer: const ProductOffer(
          identifier: 'winter',
          kind: OfferKind.promotional,
          displayName: 'Winter',
          eligibility: OfferEligibility.anyone,
          appleOfferIdentifier: 'winter_apple',
        ),
      );
      expect(result.isCompleted, isTrue);
      expect(h.transport.calls('POST', '/v1/purchases/apple/promotional-offer'), isEmpty);
    });
  });

  group('purchase with an offer on Android', () {
    late Harness a;

    setUp(() {
      a = Harness(platform: 'android');
      a.transport.json('GET', '/v1/purchases/products', {
        'products': [
          productViewJson(
            'pro_monthly',
            storeProductId: 'com.example.pro',
            googleBasePlanId: 'monthly',
          ),
        ],
      });
      a.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(store: 'play_store'),
      });
      a.store.catalog.addAll([
        storeDetail('com.example.pro', basePlanId: 'annual', rawPrice: 39.99, price: '\$39.99'),
        storeDetail(
          'com.example.pro',
          basePlanId: 'monthly',
          offerId: 'winter-play',
          price: 'Free',
        ),
        storeDetail('com.example.pro', basePlanId: 'monthly'),
        storeDetail('com.example.pro', basePlanId: 'annual', offerId: 'winter-play'),
      ]);
    });

    Future<void> deliver() async {
      await Future<void>.delayed(Duration.zero);
      a.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'play-token-12345',
          needsCompletion: true,
        ),
      );
    }

    const winter = ProductOffer(
      identifier: 'winter',
      kind: OfferKind.promotional,
      displayName: 'Winter',
      eligibility: OfferEligibility.anyone,
      googleOfferId: 'winter-play',
    );

    test('the plain base plan is the default even when an offer is listed first', () async {
      final sdk = await a.configure();
      final product = (await sdk.getProducts()).single;
      expect((product.storeDetails! as StoreProductDetails).offerId, isNull);
      expect((product.storeDetails! as StoreProductDetails).basePlanId, 'monthly');
      expect(product.storeVariants, hasLength(4));
      expect(product.priceString, '\$4.99');
      final future = sdk.purchase(product);
      await deliver();
      await future;
      expect(a.store.buys.single.details.offerId, isNull);
      expect(a.store.buys.single.details.basePlanId, 'monthly');
    });

    test('an offer buys the entry of the catalog base plan whose offer id matches', () async {
      final sdk = await a.configure();
      final product = (await sdk.getProducts()).single;
      final future = sdk.purchase(product, offer: winter);
      await deliver();
      await future;
      expect(a.store.buys.single.details.offerId, 'winter-play');
      expect(a.store.buys.single.details.basePlanId, 'monthly');
      expect(a.store.buys.single.offer, isNull);
      expect(a.transport.requests.where((r) => r.url.path.contains('apple')), isEmpty);
    });

    test('an offer Play does not list for this customer is not available', () async {
      final sdk = await a.configure();
      final product = (await sdk.getProducts()).single;
      await expectLater(
        sdk.purchase(
          product,
          offer: const ProductOffer(
            identifier: 'gone',
            kind: OfferKind.promotional,
            displayName: 'Gone',
            eligibility: OfferEligibility.anyone,
            googleOfferId: 'gone-play',
          ),
        ),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.productNotAvailable,
          ),
        ),
      );
      expect(a.store.buys, isEmpty);
    });

    test('an offer with no Google Play id cannot be applied on Android', () async {
      final sdk = await a.configure();
      final product = (await sdk.getProducts()).single;
      await expectLater(
        sdk.purchase(
          product,
          offer: const ProductOffer(
            identifier: 'apple_only',
            kind: OfferKind.promotional,
            displayName: 'Apple only',
            eligibility: OfferEligibility.anyone,
            appleOfferIdentifier: 'x',
          ),
        ),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.offerNotSupported,
          ),
        ),
      );
    });
  });

  group('setConsumptionConsent', () {
    test('puts the answer and keeps it in the customer model and on disk', () async {
      h.transport.json('PUT', '/v1/purchases/customer/consumption-consent', {
        'consented': true,
        'at': '2026-11-04T12:30:00.000Z',
      });
      final sdk = await h.configure();
      expect(sdk.cachedCustomerInfo!.consumptionConsent, isNull);
      final consent = await sdk.setConsumptionConsent(true);
      expect(consent.consented, isTrue);
      expect(consent.at, DateTime.parse('2026-11-04T12:30:00.000Z'));
      final put = h.transport.calls('PUT', '/v1/purchases/customer/consumption-consent').single;
      expect(put.json, {'consented': true});
      expect(put.headers['x-customer-token'], 'tok_1');
      expect(put.headers['content-type'], 'application/json');
      expect(sdk.cachedCustomerInfo!.consumptionConsent!.consented, isTrue);

      // A refresh answers without the field; the stored answer stays.
      final refreshed = await sdk.getCustomerInfo(forceRefresh: true);
      expect(refreshed.consumptionConsent!.consented, isTrue);

      // And it survives a restart from the cache.
      await sdk.close();
      h.transport.on('GET', '/v1/purchases/customer', (_) => throw StateError('offline'));
      final restarted = await h.configure();
      expect(restarted.cachedCustomerInfo!.consumptionConsent!.consented, isTrue);
    });

    test('a withdrawn answer replaces the earlier one', () async {
      var answer = true;
      h.transport.on('PUT', '/v1/purchases/customer/consumption-consent', (request) {
        answer = request.json['consented'] == true;
        return TransportResponse(200, jsonEncode({'consented': answer, 'at': null}));
      });
      final sdk = await h.configure();
      await sdk.setConsumptionConsent(true);
      await sdk.setConsumptionConsent(false);
      expect(answer, isFalse);
      expect(sdk.cachedCustomerInfo!.consumptionConsent!.consented, isFalse);
      expect(sdk.cachedCustomerInfo!.consumptionConsent!.at, isNull);
    });

    test('an answer the server returns inside the customer is read as it is', () async {
      h.transport.json('GET', '/v1/purchases/customer', {
        ...customerJson(),
        'consumptionConsent': {'consented': true, 'at': '2026-11-01T00:00:00.000Z'},
      });
      final sdk = await h.configure();
      final info = await sdk.getCustomerInfo(forceRefresh: true);
      expect(info.consumptionConsent!.consented, isTrue);
    });

    test('the answer of one customer is not carried to the next one', () async {
      h.transport.json('PUT', '/v1/purchases/customer/consumption-consent', {
        'consented': true,
        'at': null,
      });
      final sdk = await h.configure();
      await sdk.setConsumptionConsent(true);
      h.transport.json(
        'POST',
        '/v1/purchases/customers/logout',
        session(
          token: 'tok_2',
          customer: customerJson(id: '11111111-2222-4333-8444-555555555555'),
        ),
      );
      final next = await sdk.logOut();
      expect(next.consumptionConsent, isNull);
    });

    test('a server error is raised and nothing is cached', () async {
      h.transport.json('PUT', '/v1/purchases/customer/consumption-consent', {
        'error': {'code': 'VALIDATION_ERROR', 'message': 'bad'},
      }, status: 422);
      final sdk = await h.configure();
      await expectLater(sdk.setConsumptionConsent(true), throwsA(isA<GemicoreException>()));
      expect(sdk.cachedCustomerInfo!.consumptionConsent, isNull);
    });
  });
}
