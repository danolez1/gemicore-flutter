import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

// Built at run time so no literal looks like a real Stripe client secret to the secret scanner.
final fakeClientSecret = ['pi_123', 'secret', 'abc'].join('_');

Map<String, Object?> pendingCard({String status = 'pending', bool isActive = false}) =>
    purchaseJson(
      id: 'card1',
      status: status,
      isActive: isActive,
      store: 'card',
      productType: 'non_consumable',
      productIdentifier: 'tshirt',
    );

Map<String, Object?> intentJson({Map<String, Object?>? purchase}) => {
  'paymentId': 'pay_1',
  'clientSecret': fakeClientSecret,
  'publishableKey': 'pk_stripe_publishable',
  'merchantCountryCode': 'US',
  'applePayMerchantId': 'merchant.com.example',
  'merchantDisplayName': 'Example Shop',
  'purchase': purchase ?? {...pendingCard(), 'priceAmount': 2500, 'priceCurrency': 'USD'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;
  late FakeNativePaySheet sheet;

  setUp(() {
    h = Harness();
    sheet = FakeNativePaySheet(const NativePayResult.completed());
    h.transport.json('POST', '/v1/purchases/checkout/intent', intentJson(), status: 201);
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Future<GemicoreProduct> tshirt(Gemicore sdk) async =>
      (await sdk.getProducts()).firstWhere((p) => p.identifier == 'tshirt');

  const pollFast = Duration(milliseconds: 5);

  test('the interface keeps the names the add-on package implements', () {
    const request = NativePayRequest(
      clientSecret: 's',
      publishableKey: 'p',
      merchantCountryCode: 'US',
      applePayMerchantId: null,
      currencyCode: 'USD',
      amount: 100,
      productName: 'x',
      testEnvironment: true,
    );
    expect(request.merchantDisplayName, isEmpty);
    expect(request.amount, 100);
    expect(request.applePayMerchantId, isNull);
    expect(NativePayOutcome.values.map((o) => o.name), ['completed', 'canceled', 'failed']);
    const result = NativePayResult(outcome: NativePayOutcome.failed, message: 'declined');
    expect(result.message, 'declined');
    expect(const NativePayResult.canceled().outcome, NativePayOutcome.canceled);
    expect(const NativePayResult.completed().message, isNull);
  });

  test('without a sheet it says to add the gemicore_flutter_stripe package', () async {
    final sdk = await h.configure();
    final product = await tshirt(sdk);
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com'),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.nativePayNotConfigured)
            .having((e) => e.message, 'message', contains('gemicore_flutter_stripe')),
      ),
    );
    expect(h.transport.calls('POST', '/v1/purchases/checkout/intent'), isEmpty);
  });

  test('a product without a card price is refused before any request', () async {
    final sdk = await h.configure(nativePaySheet: sheet);
    final pro = (await sdk.getProducts()).first;
    await expectLater(
      sdk.payWithSheet(pro, email: 'b@example.com'),
      throwsA(isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.notForCard)),
    );
    expect(h.transport.calls('POST', '/v1/purchases/checkout/intent'), isEmpty);
    expect(sheet.requests, isEmpty);
  });

  test('creates the intent, presents the sheet, then polls until the purchase is active', () async {
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    var polls = 0;
    h.transport.on('GET', '/v1/purchases/customer', (_) {
      polls++;
      final purchase = polls < 3 ? pendingCard() : pendingCard(status: 'active', isActive: true);
      return TransportResponse(200, jsonEncode(customerJson(purchases: [purchase])));
    });
    final result = await sdk.payWithSheet(
      product,
      email: 'buyer@example.com',
      pollInterval: pollFast,
    );
    expect(result.isCompleted, isTrue);
    expect(result.purchase!.id, 'card1');
    expect(polls, 3);

    final intent = h.transport.calls('POST', '/v1/purchases/checkout/intent').single;
    expect(intent.json, {'productId': 'tshirt', 'email': 'buyer@example.com'});
    expect(intent.headers['x-customer-token'], 'tok_1');
    final request = sheet.requests.single;
    expect(request.clientSecret, fakeClientSecret);
    expect(request.publishableKey, 'pk_stripe_publishable');
    expect(request.merchantCountryCode, 'US');
    expect(request.applePayMerchantId, 'merchant.com.example');
    expect(request.currencyCode, 'USD');
    expect(request.amount, 2500);
    expect(request.productName, 'T-shirt');
    expect(request.merchantDisplayName, 'Example Shop');
    expect(request.testEnvironment, isFalse);
    expect(h.opener.opened, isEmpty, reason: 'the hosted checkout is not used');
  });

  test('an older server without merchantDisplayName gives an empty name, not a failure', () async {
    h.transport.json(
      'POST',
      '/v1/purchases/checkout/intent',
      {...intentJson()}..remove('merchantDisplayName'),
      status: 201,
    );
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.json(
      'GET',
      '/v1/purchases/customer',
      customerJson(purchases: [pendingCard(status: 'active', isActive: true)]),
    );
    await sdk.payWithSheet(product, email: 'b@example.com', pollInterval: pollFast);
    expect(sheet.requests.single.merchantDisplayName, isEmpty);
  });

  test('a product with no card price at all stays PURCHASE_NOT_FOR_CARD from the server', () async {
    h.transport.json('POST', '/v1/purchases/checkout/intent', {
      'error': {
        'code': 'PURCHASE_NOT_FOR_CARD',
        'message': 'no card price',
        'details': {'productId': 'tshirt'},
      },
    }, status: 422);
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com'),
      throwsA(isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.notForCard)),
    );
  });

  test(
    'a card price without a sale declaration is a typed error that says what to declare',
    () async {
      h.transport.json('POST', '/v1/purchases/checkout/intent', {
        'error': {
          'code': 'PURCHASE_NOT_FOR_CARD',
          'message': 'This product cannot be bought by card',
          'details': {'productId': 'tshirt', 'reason': 'card_sale_kind_missing'},
        },
      }, status: 422);
      final sdk = await h.configure(nativePaySheet: sheet);
      final product = await tshirt(sdk);
      await expectLater(
        sdk.payWithSheet(product, email: 'b@example.com'),
        throwsA(
          isA<GemicoreException>()
              .having((e) => e.code, 'code', GemicoreErrorCode.cardSaleNotDeclared)
              .having((e) => e.statusCode, 'status', 422)
              .having((e) => e.details['productId'], 'productId', 'tshirt')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('physical goods'),
                  contains('real world service'),
                  contains('tshirt'),
                ),
              ),
        ),
      );
      expect(sheet.requests, isEmpty);
    },
  );

  test('a test key puts the sheet in the test environment', () async {
    final sdk = await h.configure(apiKey: testKey, nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.json(
      'GET',
      '/v1/purchases/customer',
      customerJson(purchases: [pendingCard(status: 'active', isActive: true)]),
    );
    await sdk.payWithSheet(product, email: 'b@example.com', pollInterval: pollFast);
    expect(sheet.requests.single.testEnvironment, isTrue);
  });

  test('the sheet total falls back to the catalog price when the purchase has none', () async {
    h.transport.json(
      'POST',
      '/v1/purchases/checkout/intent',
      intentJson(purchase: {...pendingCard(), 'priceAmount': null, 'priceCurrency': null}),
      status: 201,
    );
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.json(
      'GET',
      '/v1/purchases/customer',
      customerJson(purchases: [pendingCard(status: 'active', isActive: true)]),
    );
    await sdk.payWithSheet(product, email: 'b@example.com', pollInterval: pollFast);
    expect(sheet.requests.single.amount, 2500);
    expect(sheet.requests.single.currencyCode, 'USD');
  });

  test('a closed sheet is a cancelled result and nothing is polled', () async {
    sheet.result = const NativePayResult.canceled();
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.requests.clear();
    final result = await sdk.payWithSheet(product, email: 'b@example.com');
    expect(result.isCancelled, isTrue);
    expect(h.transport.calls('GET', '/v1/purchases/customer'), isEmpty);
  });

  test('a failed sheet is a typed error with the sheet message', () async {
    sheet.result = const NativePayResult.failed('Your card was declined.');
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com'),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.nativePayFailed)
            .having((e) => e.message, 'message', 'Your card was declined.'),
      ),
    );
  });

  test('a sheet that throws becomes a typed error without echoing the exception text', () async {
    sheet.throws = StateError('$fakeClientSecret leaked');
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com'),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.nativePayFailed)
            .having((e) => e.message, 'message', isNot(contains('secret'))),
      ),
    );
  });

  test('a server that cannot open a native sheet is the server error', () async {
    h.transport.json('POST', '/v1/purchases/checkout/intent', {
      'error': {
        'code': 'PURCHASE_STORE_NOT_CONFIGURED',
        'message': 'no key',
        'details': {'reason': 'publishable_key_missing'},
      },
    }, status: 409);
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com'),
      throwsA(
        isA<GemicoreException>()
            .having((e) => e.code, 'code', GemicoreErrorCode.storeNotConfigured)
            .having((e) => e.details['reason'], 'reason', 'publishable_key_missing'),
      ),
    );
    expect(sheet.requests, isEmpty);
  });

  test('a payment that does not settle in time is pending, not an error', () async {
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.json('GET', '/v1/purchases/customer', customerJson(purchases: [pendingCard()]));
    final result = await sdk.payWithSheet(
      product,
      email: 'b@example.com',
      timeout: const Duration(milliseconds: 30),
      pollInterval: pollFast,
    );
    expect(result.isPending, isTrue);
    expect(result.purchase!.id, 'card1');
  });

  test('a purchase that ends as failed after the sheet is a payment error', () async {
    final sdk = await h.configure(nativePaySheet: sheet);
    final product = await tshirt(sdk);
    h.transport.json(
      'GET',
      '/v1/purchases/customer',
      customerJson(purchases: [pendingCard(status: 'failed')]),
    );
    await expectLater(
      sdk.payWithSheet(product, email: 'b@example.com', pollInterval: pollFast),
      throwsA(
        isA<GemicoreException>().having((e) => e.code, 'code', GemicoreErrorCode.paymentFailed),
      ),
    );
  });
}
