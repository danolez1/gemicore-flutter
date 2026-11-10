import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

late FakeTransport transport;
late FakeStore store;
late MemoryGemicoreStorage storage;
late FakeOpener opener;

Future<Gemicore> configure({String apiKey = liveKey, String? appUserId, bool? useTestStore}) =>
    Gemicore.configure(
      apiKey: apiKey,
      baseUrl: 'https://api.test',
      appUserId: appUserId,
      useTestStore: useTestStore,
      transport: transport,
      storage: storage,
      store: store,
      checkoutOpener: opener,
      observeAppLifecycle: false,
      restoreQuietPeriod: const Duration(milliseconds: 50),
      restoreTimeout: const Duration(seconds: 2),
      logLevel: GemicoreLogLevel.none,
    );

StoreProductDetails detail(String id, {String? basePlanId}) => StoreProductDetails(
  id: id,
  title: id,
  price: '\$4.99',
  rawPrice: 4.99,
  currencyCode: 'USD',
  basePlanId: basePlanId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    transport = FakeTransport();
    store = FakeStore();
    storage = MemoryGemicoreStorage();
    opener = FakeOpener();
    transport.json('POST', '/v1/purchases/customers', session(), status: 201);
    transport.json('GET', '/v1/purchases/customer', customerJson());
    transport.json('GET', '/v1/purchases/products', productsJson);
    store.catalog.addAll([detail('com.example.pro.monthly'), detail('com.example.coins100')]);
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  group('configure', () {
    test('refuses a secret key', () {
      expect(
        () => Gemicore.configure(apiKey: 'sk_live_x', transport: transport, store: store),
        throwsA(isA<GemicoreException>()),
      );
    });

    test('creates a customer and stores its token when the device has none', () async {
      final sdk = await configure();
      final create = transport.calls('POST', '/v1/purchases/customers').single;
      expect(create.headers['authorization'], 'Bearer $liveKey');
      expect(create.headers['x-gemicore-platform'], 'ios');
      expect(create.headers.containsKey('x-customer-token'), isFalse);
      expect(create.json, isEmpty);
      expect(storage.values.values, contains('tok_1'));
      expect(sdk.cachedCustomerInfo!.id, customerId);
      expect(Gemicore.instance, same(sdk));
    });

    test('passes appUserId as the external id of a new customer', () async {
      await configure(appUserId: 'user-9');
      expect(transport.calls('POST', '/v1/purchases/customers').single.json, {
        'externalId': 'user-9',
      });
    });

    test('reuses a stored token and refreshes the customer', () async {
      await configure();
      await Gemicore.instance.close();
      transport.requests.clear();
      final sdk = await configure();
      expect(transport.calls('POST', '/v1/purchases/customers'), isEmpty);
      final get = transport.calls('GET', '/v1/purchases/customer').single;
      expect(get.headers['x-customer-token'], 'tok_1');
      expect(sdk.cachedCustomerInfo, isNotNull);
    });

    test('a rejected token starts a fresh anonymous customer', () async {
      await configure();
      await Gemicore.instance.close();
      transport.json('GET', '/v1/purchases/customer', {
        'error': {'code': 'PURCHASE_CUSTOMER_TOKEN_INVALID', 'message': 'gone'},
      }, status: 401);
      transport.json('POST', '/v1/purchases/customers', session(token: 'tok_new'), status: 201);
      await configure();
      expect(storage.values.values, contains('tok_new'));
    });

    test('starts offline from the cache when the network fails', () async {
      await configure();
      await Gemicore.instance.close();
      transport.on('GET', '/v1/purchases/customer', (_) => throw StateError('offline'));
      final sdk = await configure();
      expect(sdk.cachedCustomerInfo!.id, customerId);
    });
  });

  group('identity', () {
    test('logIn swaps the token and returns the logged in customer', () async {
      final sdk = await configure();
      transport.json(
        'POST',
        '/v1/purchases/customers/login',
        session(
          token: 'tok_user',
          customer: customerJson(externalId: 'user-1', pro: true),
        ),
      );
      final info = await sdk.logIn('user-1');
      expect(info.externalId, 'user-1');
      final login = transport.calls('POST', '/v1/purchases/customers/login').single;
      expect(login.json, {'externalId': 'user-1'});
      expect(login.headers['x-customer-token'], 'tok_1');
      expect(storage.values.values, contains('tok_user'));
      await sdk.getCustomerInfo(forceRefresh: true);
      expect(transport.requests.last.headers['x-customer-token'], 'tok_user');
    });

    test('logOut stores the new anonymous token', () async {
      final sdk = await configure();
      transport.json('POST', '/v1/purchases/customers/logout', session(token: 'tok_anon'));
      final info = await sdk.logOut();
      expect(info.isAnonymous, isTrue);
      expect(storage.values.values, contains('tok_anon'));
    });

    test('configure with a different appUserId logs in on start', () async {
      await configure();
      await Gemicore.instance.close();
      transport.json(
        'POST',
        '/v1/purchases/customers/login',
        session(
          token: 'tok_user',
          customer: customerJson(externalId: 'user-2'),
        ),
      );
      await configure(appUserId: 'user-2');
      expect(transport.calls('POST', '/v1/purchases/customers/login'), hasLength(1));
    });
  });

  group('products', () {
    test('merges store prices into the server catalog', () async {
      final sdk = await configure();
      final products = await sdk.getProducts();
      expect(products.map((p) => p.identifier), ['pro_monthly', 'coins_100', 'tshirt']);
      expect(products[0].priceString, '\$4.99');
      expect(products[0].availableInStore, isTrue);
      expect(products[0].entitlements, ['pro']);
      expect(products[2].availableInStore, isFalse);
      expect(products[2].card!.amount, 2500);
    });

    test('picks the Google base plan the catalog names', () async {
      store = FakeStore(platform: 'android');
      store.catalog.addAll([
        detail('com.example.pro', basePlanId: 'monthly'),
        detail('com.example.pro', basePlanId: 'annual'),
      ]);
      transport.json('GET', '/v1/purchases/products', {
        'products': [
          {
            'identifier': 'pro_annual',
            'type': 'subscription',
            'displayName': 'Pro annual',
            'description': null,
            'storeProductId': 'com.example.pro',
            'googleBasePlanId': 'annual',
            'entitlements': ['pro'],
            'card': null,
          },
        ],
      });
      final sdk = await configure();
      final product = (await sdk.getProducts()).single;
      expect((product.storeDetails! as StoreProductDetails).basePlanId, 'annual');
    });
  });

  group('purchase', () {
    test('records the App Store JWS, then finishes the transaction', () async {
      final sdk = await configure();
      final product = (await sdk.getProducts()).first;
      final recorded = Completer<void>();
      transport.on('POST', '/v1/purchases', (req) {
        expect(store.completed, isEmpty, reason: 'must not finish before the server answers');
        recorded.complete();
        return TransportResponse(
          200,
          jsonEncode({
            'customer': customerJson(pro: true, purchases: [purchaseJson()]),
            'purchase': purchaseJson(),
          }),
        );
      });
      final future = sdk.purchase(product);
      await Future<void>.delayed(Duration.zero);
      expect(store.buys.single.accountId, customerId);
      expect(store.buys.single.consumable, isFalse);
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'eyJ.jws.sig',
          needsCompletion: true,
        ),
      );
      final result = await future;
      expect(result.isCompleted, isTrue);
      expect(result.customerInfo!.hasEntitlement('pro'), isTrue);
      expect(result.purchase!.id, 'p1');
      expect(transport.calls('POST', '/v1/purchases').single.json, {
        'store': 'app_store',
        'signedTransaction': 'eyJ.jws.sig',
      });
      expect(store.completed, hasLength(1));
    });

    test('posts the Play purchase token and product id on Android', () async {
      store = FakeStore(platform: 'android');
      store.catalog.add(detail('com.example.coins100'));
      transport.json('POST', '/v1/purchases', {
        'customer': customerJson(),
        'purchase': purchaseJson(store: 'play_store'),
      });
      final sdk = await configure();
      final coins = (await sdk.getProducts()).firstWhere((p) => p.identifier == 'coins_100');
      final future = sdk.purchase(coins);
      await Future<void>.delayed(Duration.zero);
      expect(store.buys.single.consumable, isTrue);
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.coins100',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'play-token-1',
          needsCompletion: true,
        ),
      );
      await future;
      expect(transport.calls('POST', '/v1/purchases').single.json, {
        'store': 'play_store',
        'purchaseToken': 'play-token-1',
        'productId': 'com.example.coins100',
      });
      expect(transport.requests.last.headers['x-gemicore-platform'], 'android');
    });

    test('a cancelled sheet is a cancelled result, not an error', () async {
      final sdk = await configure();
      final product = (await sdk.getProducts()).first;
      final future = sdk.purchase(product);
      await Future<void>.delayed(Duration.zero);
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.canceled,
          serverVerificationData: '',
        ),
      );
      expect((await future).isCancelled, isTrue);
      expect(transport.calls('POST', '/v1/purchases'), isEmpty);
    });

    test('a server error leaves the store transaction unfinished', () async {
      final sdk = await configure();
      final product = (await sdk.getProducts()).first;
      transport.json('POST', '/v1/purchases', {
        'error': {'code': 'PURCHASE_VERIFICATION_FAILED', 'message': 'bad signature'},
      }, status: 422);
      final future = sdk.purchase(product);
      await Future<void>.delayed(Duration.zero);
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'bad',
          needsCompletion: true,
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.verificationFailed,
          ),
        ),
      );
      expect(store.completed, isEmpty);
    });

    test('a pending purchase resolves as pending', () async {
      final sdk = await configure();
      final product = (await sdk.getProducts()).first;
      final future = sdk.purchase(product);
      await Future<void>.delayed(Duration.zero);
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.pending,
          serverVerificationData: '',
        ),
      );
      expect((await future).isPending, isTrue);
    });

    test('a purchase delivered with no caller waiting is still recorded', () async {
      final sdk = await configure();
      transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(),
      });
      final emitted = sdk.customerInfoStream.first;
      store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'eyJ.late',
          needsCompletion: true,
        ),
      );
      expect((await emitted).hasEntitlement('pro'), isTrue);
      expect(store.completed, hasLength(1));
    });

    test('a product the store does not sell cannot be bought', () async {
      final sdk = await configure();
      final tshirt = (await sdk.getProducts()).last;
      expect(
        () => sdk.purchase(tshirt),
        throwsA(
          isA<GemicoreException>().having(
            (e) => e.code,
            'code',
            GemicoreErrorCode.productNotAvailable,
          ),
        ),
      );
    });
  });

  group('test store', () {
    test('a test key with no store available buys through the test store', () async {
      store.available = false;
      transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(store: 'test_store'),
      });
      final sdk = await configure(apiKey: testKey);
      final product = (await sdk.getProducts()).first;
      final result = await sdk.purchase(product);
      expect(result.isCompleted, isTrue);
      expect(transport.calls('POST', '/v1/purchases').single.json, {
        'store': 'test_store',
        'productId': 'pro_monthly',
      });
      expect(store.buys, isEmpty);
    });

    test('a live key never uses the test store', () async {
      store.available = false;
      final sdk = await configure(useTestStore: true);
      final product = (await sdk.getProducts()).first;
      expect(() => sdk.purchase(product), throwsA(isA<GemicoreException>()));
    });
  });

  group('restore', () {
    test('collects restored transactions and posts them in one call', () async {
      final sdk = await configure();
      store.restoreEmits = const [
        StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-a',
          needsCompletion: true,
        ),
        StorePurchaseUpdate(
          productId: 'com.example.unlock',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-b',
          needsCompletion: true,
        ),
      ];
      transport.json('POST', '/v1/purchases/restore', {'customer': customerJson(pro: true)});
      final info = await sdk.restorePurchases();
      expect(info.hasEntitlement('pro'), isTrue);
      expect(store.restores.single, customerId);
      expect(transport.calls('POST', '/v1/purchases/restore').single.json, {
        'appStore': {
          'signedTransactions': ['jws-a', 'jws-b'],
        },
      });
      expect(transport.calls('POST', '/v1/purchases'), isEmpty);
      expect(store.completed, hasLength(2));
    });

    test('nothing to restore refreshes the customer instead', () async {
      final sdk = await configure();
      transport.requests.clear();
      await sdk.restorePurchases();
      expect(transport.calls('POST', '/v1/purchases/restore'), isEmpty);
      expect(transport.calls('GET', '/v1/purchases/customer'), hasLength(1));
    });

    test('Play restores post tokens with product ids', () async {
      store = FakeStore(platform: 'android');
      store.restoreEmits = const [
        StorePurchaseUpdate(
          productId: 'com.example.pro',
          state: StorePurchaseState.restored,
          serverVerificationData: 'tok-a',
        ),
      ];
      transport.json('POST', '/v1/purchases/restore', {'customer': customerJson()});
      final sdk = await configure();
      await sdk.restorePurchases();
      expect(transport.calls('POST', '/v1/purchases/restore').single.json, {
        'playStore': {
          'purchases': [
            {'purchaseToken': 'tok-a', 'productId': 'com.example.pro'},
          ],
        },
      });
    });
  });

  group('payWithCard', () {
    test('opens the hosted checkout and polls until the payment settles', () async {
      final sdk = await configure();
      final tshirt = (await sdk.getProducts()).last;
      final pending = purchaseJson(
        id: 'card1',
        status: 'pending',
        isActive: false,
        store: 'card',
        productType: 'non_consumable',
        productIdentifier: 'tshirt',
      );
      transport.json('POST', '/v1/purchases/checkout', {
        'paymentId': 'pay_1',
        'url': 'https://checkout.stripe.com/c/pay_1',
        'purchase': pending,
      });
      var polls = 0;
      transport.on('GET', '/v1/purchases/customer', (_) {
        polls++;
        final p = polls < 2 ? pending : {...pending, 'status': 'active', 'isActive': true};
        return TransportResponse(200, jsonEncode(customerJson(purchases: [p])));
      });
      final result = await sdk.payWithCard(
        tshirt,
        email: 'buyer@example.com',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(result.isCompleted, isTrue);
      expect(result.purchase!.id, 'card1');
      expect(opener.opened.single.toString(), 'https://checkout.stripe.com/c/pay_1');
      expect(transport.calls('POST', '/v1/purchases/checkout').single.json, {
        'productId': 'tshirt',
        'email': 'buyer@example.com',
      });
    });

    test('a failed payment is a payment error, not a cancelled result', () async {
      final sdk = await configure();
      final tshirt = (await sdk.getProducts()).last;
      final pending = purchaseJson(id: 'card1', status: 'pending', isActive: false, store: 'card');
      transport.json('POST', '/v1/purchases/checkout', {
        'paymentId': 'p',
        'url': 'https://x.test/c',
        'purchase': pending,
      });
      transport.json(
        'GET',
        '/v1/purchases/customer',
        customerJson(
          purchases: [
            {...pending, 'status': 'failed'},
          ],
        ),
      );
      await expectLater(
        sdk.payWithCard(
          tshirt,
          email: 'b@example.com',
          pollInterval: const Duration(milliseconds: 5),
        ),
        throwsA(
          isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.paymentFailed),
        ),
      );
    });

    test('a timeout returns pending, not an error', () async {
      final sdk = await configure();
      final tshirt = (await sdk.getProducts()).last;
      final pending = purchaseJson(id: 'card1', status: 'pending', isActive: false, store: 'card');
      transport.json('POST', '/v1/purchases/checkout', {
        'paymentId': 'p',
        'url': 'https://x.test/c',
        'purchase': pending,
      });
      transport.json('GET', '/v1/purchases/customer', customerJson(purchases: [pending]));
      final result = await sdk.payWithCard(
        tshirt,
        email: 'b@example.com',
        timeout: const Duration(milliseconds: 30),
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(result.isPending, isTrue);
    });

    test('a product without a card price is refused locally', () async {
      final sdk = await configure();
      final pro = (await sdk.getProducts()).first;
      expect(
        () => sdk.payWithCard(pro, email: 'b@example.com'),
        throwsA(
          isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.notForCard),
        ),
      );
    });
  });

  group('card sale declaration', () {
    test('the hosted checkout maps the missing declaration to the typed error', () async {
      final sdk = await configure();
      final tshirt = (await sdk.getProducts()).firstWhere((p) => p.identifier == 'tshirt');
      transport.json('POST', '/v1/purchases/checkout', {
        'error': {
          'code': 'PURCHASE_NOT_FOR_CARD',
          'message': 'no',
          'details': {'productId': 'tshirt', 'reason': 'card_sale_kind_missing'},
        },
      }, status: 422);
      await expectLater(
        sdk.payWithCard(tshirt, email: 'b@example.com'),
        throwsA(
          isA<GemicoreException>()
              .having((e) => e.code, 'code', GemicoreErrorCode.cardSaleNotDeclared)
              .having((e) => e.message, 'message', contains('dashboard')),
        ),
      );
    });
  });

  group('customer info', () {
    test('answers from the cache inside five minutes and refreshes on demand', () async {
      final sdk = await configure();
      transport.requests.clear();
      await sdk.getCustomerInfo();
      expect(transport.requests, isEmpty);
      await sdk.getCustomerInfo(forceRefresh: true);
      expect(transport.calls('GET', '/v1/purchases/customer'), hasLength(1));
    });

    test('hasEntitlement reads the customer info', () async {
      transport.json(
        'POST',
        '/v1/purchases/customers',
        session(customer: customerJson(pro: true)),
        status: 201,
      );
      final sdk = await configure();
      expect(await sdk.hasEntitlement('pro'), isTrue);
      expect(await sdk.hasEntitlement('team'), isFalse);
    });
  });
}
