import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter/src/models.dart' show CheckoutStart, CustomerSession, ProductView;

import 'fakes.dart';

void main() {
  test('CustomerInfo parses entitlements, subscriptions and purchases', () {
    final info = CustomerInfo.fromJson(
      customerJson(externalId: 'user-1', pro: true, purchases: [purchaseJson()]),
    );
    expect(info.id, customerId);
    expect(info.externalId, 'user-1');
    expect(info.isAnonymous, isFalse);
    expect(info.hasEntitlement('pro'), isTrue);
    expect(info.hasEntitlement('other'), isFalse);
    expect(info.activeSubscriptions, ['pro_monthly']);
    final pro = info.activeEntitlements['pro']!;
    expect(pro.source, EntitlementSource.purchase);
    expect(pro.store, PurchaseStore.appStore);
    expect(pro.periodType, PeriodType.trial);
    expect(pro.expiresAt, DateTime.parse('2026-12-01T10:00:00.000Z'));
    expect(info.requestedAt, DateTime.parse('2026-11-04T12:00:00.000Z'));
  });

  test('PurchaseInfo parses every field', () {
    final p = PurchaseInfo.fromJson(purchaseJson(status: 'in_grace_period'));
    expect(p.id, 'p1');
    expect(p.productIdentifier, 'pro_monthly');
    expect(p.storeProductId, 'com.example.pro.monthly');
    expect(p.store, PurchaseStore.appStore);
    expect(p.productType, ProductType.subscription);
    expect(p.status, 'in_grace_period');
    expect(p.isActive, isTrue);
    expect(p.isSandbox, isTrue);
    expect(p.willRenew, isTrue);
    expect(p.ownership, Ownership.familyShared);
    expect(p.priceAmount, 499);
    expect(p.priceCurrency, 'USD');
    expect(p.managementUrl, contains('apple.com'));
    expect(p.isPending, isFalse);
  });

  test('unknown enum values do not throw', () {
    final p = PurchaseInfo.fromJson({
      ...purchaseJson(),
      'store': 'amazon',
      'productType': 'bundle',
    });
    expect(p.store, PurchaseStore.unknown);
    expect(p.productType, ProductType.unknown);
  });

  test('ProductView parses a card price and store ids', () {
    final views = (productsJson['products']! as List)
        .map((p) => ProductView.fromJson((p as Map).cast<String, Object?>()))
        .toList();
    expect(views[0].type, ProductType.subscription);
    expect(views[0].entitlements, ['pro']);
    expect(views[1].type, ProductType.consumable);
    expect(views[2].type, ProductType.nonConsumable);
    expect(views[2].card!.amount, 2500);
    expect(views[2].card!.currency, 'USD');
    expect(views[2].storeProductId, isNull);
  });

  test('CustomerSession and CheckoutStart parse', () {
    final s = CustomerSession.fromJson(session(token: 'abc'));
    expect(s.token, 'abc');
    expect(s.customer.id, customerId);
    final c = CheckoutStart.fromJson({
      'paymentId': 'pay_1',
      'url': 'https://checkout.example/x',
      'purchase': purchaseJson(status: 'pending', isActive: false, store: 'card'),
    });
    expect(c.paymentId, 'pay_1');
    expect(c.purchase.isPending, isTrue);
    expect(c.purchase.store, PurchaseStore.card);
  });

  test('GemicoreException reads the API error body', () {
    final e = GemicoreException.fromResponse(422, {
      'error': {
        'code': 'PURCHASE_VERIFICATION_FAILED',
        'message': 'bad',
        'details': {'field': 'signedTransaction'},
      },
    });
    expect(e.code, GemicoreErrorCode.verificationFailed);
    expect(e.statusCode, 422);
    expect(e.details['field'], 'signedTransaction');
    expect(e.isRetryable, isFalse);
    expect(GemicoreException.fromResponse(503, null).isRetryable, isTrue);
    expect(GemicoreException.fromResponse(500, 'oops').code, GemicoreErrorCode.invalidResponse);
  });

  test('a missing required field is a FormatException', () {
    expect(() => CustomerInfo.fromJson({}), throwsFormatException);
  });
}
