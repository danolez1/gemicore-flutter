import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:in_app_purchase/in_app_purchase.dart' show PurchaseParam;
import 'package:in_app_purchase_android/billing_client_wrappers.dart' as play;
import 'package:in_app_purchase_android/in_app_purchase_android.dart' show GooglePlayProductDetails;
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart'
    show AppStorePurchaseParam, AppStoreProduct2Details, AppStoreProductDetails, Sk2PurchaseParam;
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

play.PricingPhaseWrapper phase(
  String period,
  int micros, {
  play.RecurrenceMode mode = play.RecurrenceMode.infiniteRecurring,
  int cycles = 0,
  String price = '\$4.99',
}) => play.PricingPhaseWrapper(
  billingCycleCount: cycles,
  billingPeriod: period,
  formattedPrice: price,
  priceAmountMicros: micros,
  priceCurrencyCode: 'USD',
  recurrenceMode: mode,
);

play.SubscriptionOfferDetailsWrapper offer(
  String basePlan,
  String? offerId,
  List<play.PricingPhaseWrapper> phases,
) => play.SubscriptionOfferDetailsWrapper(
  basePlanId: basePlan,
  offerId: offerId,
  offerTags: const [],
  offerIdToken: 'token-$basePlan-$offerId',
  pricingPhases: phases,
);

List<StoreProductDetails> playEntries(List<play.SubscriptionOfferDetailsWrapper> offers) =>
    GooglePlayProductDetails.fromProductDetails(
      play.ProductDetailsWrapper(
        description: 'd',
        name: 'Pro',
        productId: 'com.example.pro',
        productType: play.ProductType.subs,
        title: 'Pro (App)',
        subscriptionOfferDetails: offers,
      ),
    ).map(InAppPurchaseStoreBridge.toStoreProduct).toList();

SK2Product sk2Product({SK2SubscriptionPeriod? period}) => SK2Product(
  id: 'com.example.pro.monthly',
  displayName: 'Pro',
  displayPrice: '\$4.99',
  description: 'd',
  price: 4.99,
  type: SK2ProductType.autoRenewable,
  priceLocale: SK2PriceLocale(currencyCode: 'USD', currencySymbol: '\$'),
  subscription: period == null
      ? null
      : SK2SubscriptionInfo(
          subscriptionGroupID: 'g1',
          promotionalOffers: const [],
          subscriptionPeriod: period,
        ),
);

SKProductWrapper sk1Product({
  SKProductSubscriptionPeriodWrapper? period,
  SKProductDiscountWrapper? intro,
}) => SKProductWrapper(
  productIdentifier: 'com.example.pro.monthly',
  localizedTitle: 'Pro',
  localizedDescription: 'd',
  priceLocale: SKPriceLocaleWrapper(currencySymbol: '\$', currencyCode: 'USD', countryCode: 'US'),
  price: '4.99',
  subscriptionPeriod: period,
  introductoryPrice: intro,
);

SKProductDiscountWrapper discount(SKProductDiscountPaymentMode mode, int units, int periods) =>
    SKProductDiscountWrapper(
      price: '0.0',
      priceLocale: SKPriceLocaleWrapper(
        currencySymbol: '\$',
        currencyCode: 'USD',
        countryCode: 'US',
      ),
      numberOfPeriods: periods,
      paymentMode: mode,
      subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
        numberOfUnits: units,
        unit: SKSubscriptionPeriodUnit.day,
      ),
      identifier: null,
      type: SKProductDiscountType.introductory,
    );

void main() {
  group('Google Play entries', () {
    final entries = playEntries([
      offer('monthly', null, [phase('P1M', 4990000)]),
      offer('monthly', 'trial7', [
        phase('P1W', 0, mode: play.RecurrenceMode.finiteRecurring, cycles: 1, price: 'Free'),
        phase('P1M', 4990000),
      ]),
      offer('annual', null, [phase('P1Y', 39990000, price: '\$39.99')]),
      offer('annual', 'half', [
        phase(
          'P1M',
          1990000,
          mode: play.RecurrenceMode.finiteRecurring,
          cycles: 3,
          price: '\$1.99',
        ),
        phase('P1Y', 39990000, price: '\$39.99'),
      ]),
    ]);

    test('every entry keeps its base plan and offer id', () {
      expect(entries.map((e) => (e.basePlanId, e.offerId)), [
        ('monthly', null),
        ('monthly', 'trial7'),
        ('annual', null),
        ('annual', 'half'),
      ]);
    });

    test('the paid period is the recurring phase', () {
      expect(entries[0].subscriptionPeriod, monthlyPeriod);
      expect(entries[1].subscriptionPeriod, monthlyPeriod);
      expect(entries[2].subscriptionPeriod, const SubscriptionPeriod(1, PeriodUnit.year));
    });

    test('a free first phase is the trial, a paid discount is not', () {
      expect(entries[0].trialPeriod, isNull);
      expect(entries[1].trialPeriod, const SubscriptionPeriod(1, PeriodUnit.week));
      expect(entries[3].trialPeriod, isNull);
    });

    test('a free phase of several cycles counts them', () {
      final multi = playEntries([
        offer('monthly', 'free3', [
          phase('P1W', 0, mode: play.RecurrenceMode.finiteRecurring, cycles: 3),
          phase('P1M', 4990000),
        ]),
      ]);
      expect(multi.single.trialPeriod, const SubscriptionPeriod(3, PeriodUnit.week));
    });

    test('prices and ids come from the plugin details', () {
      expect(entries[2].price, '\$39.99');
      expect(entries[2].rawPrice, closeTo(39.99, 0.001));
      expect(entries[2].currencyCode, 'USD');
      expect(entries[2].id, 'com.example.pro');
    });
  });

  group('App Store products', () {
    test('a StoreKit 2 subscription has its period and no trial of its own', () {
      final details = InAppPurchaseStoreBridge.toStoreProduct(
        AppStoreProduct2Details.fromSK2Product(
          sk2Product(
            period: const SK2SubscriptionPeriod(value: 1, unit: SK2SubscriptionPeriodUnit.month),
          ),
        ),
      );
      expect(details.subscriptionPeriod, monthlyPeriod);
      expect(details.trialPeriod, isNull);
      expect(details.offerId, isNull);
      expect(details.basePlanId, isNull);
    });

    test('the trial found by a StoreKit 1 request is attached', () {
      final details = InAppPurchaseStoreBridge.toStoreProduct(
        AppStoreProduct2Details.fromSK2Product(
          sk2Product(
            period: const SK2SubscriptionPeriod(value: 1, unit: SK2SubscriptionPeriodUnit.year),
          ),
        ),
        introTrial: const SubscriptionPeriod(7, PeriodUnit.day),
      );
      expect(details.subscriptionPeriod, const SubscriptionPeriod(1, PeriodUnit.year));
      expect(details.trialPeriod, const SubscriptionPeriod(7, PeriodUnit.day));
    });

    test('a one time product has no period', () {
      final details = InAppPurchaseStoreBridge.toStoreProduct(
        AppStoreProduct2Details.fromSK2Product(sk2Product()),
      );
      expect(details.subscriptionPeriod, isNull);
    });

    test('a StoreKit 1 product reads its period and free trial itself', () {
      final details = InAppPurchaseStoreBridge.toStoreProduct(
        AppStoreProductDetails.fromSKProduct(
          sk1Product(
            period: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.month,
            ),
            intro: discount(SKProductDiscountPaymentMode.freeTrail, 7, 1),
          ),
        ),
      );
      expect(details.subscriptionPeriod, monthlyPeriod);
      expect(details.trialPeriod, const SubscriptionPeriod(7, PeriodUnit.day));
    });

    test('a paid introductory price is not a trial', () {
      final details = InAppPurchaseStoreBridge.toStoreProduct(
        AppStoreProductDetails.fromSKProduct(
          sk1Product(intro: discount(SKProductDiscountPaymentMode.payAsYouGo, 7, 1)),
        ),
      );
      expect(details.trialPeriod, isNull);
    });
  });

  group('purchase parameters', () {
    final native = AppStoreProduct2Details.fromSK2Product(sk2Product());

    test('no offer is the plain parameter with the account id', () {
      final param = InAppPurchaseStoreBridge.purchaseParamFor(native, 'acct', null);
      expect(param, isNot(isA<Sk2PurchaseParam>()));
      expect(param.applicationUserName, 'acct');
      expect(param.productDetails, same(native));
    });

    test('a promotional offer carries the signature fields', () {
      final param = InAppPurchaseStoreBridge.purchaseParamFor(
        native,
        'acct',
        const StorePurchaseOffer(
          promotional: StorePromotionalOffer(
            offerId: 'winter',
            keyId: 'KEY',
            nonce: 'n-1',
            timestamp: 99,
            signature: 'sig',
          ),
        ),
      );
      final sk2 = param as Sk2PurchaseParam;
      expect(sk2.applicationUserName, 'acct');
      expect(sk2.promotionalOffer!.offerId, 'winter');
      expect(sk2.promotionalOffer!.signature.keyID, 'KEY');
      expect(sk2.promotionalOffer!.signature.nonce, 'n-1');
      expect(sk2.promotionalOffer!.signature.timestamp, 99);
      expect(sk2.promotionalOffer!.signature.signature, 'sig');
      expect(sk2.winBackOfferId, isNull);
      expect(sk2.introductoryOfferEligibilityCompactJWS, isNull);
    });

    test('a win-back offer and the eligibility JWS reach the StoreKit 2 parameter', () {
      final sk2 = InAppPurchaseStoreBridge.purchaseParamFor(
        native,
        'acct',
        const StorePurchaseOffer(winBackOfferId: 'wb', introductoryEligibilityJws: 'a.b.c'),
      ) as Sk2PurchaseParam;
      expect(sk2.winBackOfferId, 'wb');
      expect(sk2.introductoryOfferEligibilityCompactJWS, 'a.b.c');
      expect(sk2.promotionalOffer, isNull);
    });

    test('StoreKit 1 takes a promotional offer as a payment discount', () {
      final sk1 = AppStoreProductDetails.fromSKProduct(sk1Product());
      final param = InAppPurchaseStoreBridge.purchaseParamFor(
        sk1,
        'acct',
        const StorePurchaseOffer(
          promotional: StorePromotionalOffer(
            offerId: 'winter',
            keyId: 'KEY',
            nonce: 'n-1',
            timestamp: 99,
            signature: 'sig',
          ),
        ),
      ) as AppStorePurchaseParam;
      expect(param.discount!.identifier, 'winter');
      expect(param.discount!.keyIdentifier, 'KEY');
      expect(param.discount!.nonce, 'n-1');
      expect(param.discount!.timestamp, 99);
      expect(param.discount!.signature, 'sig');
      expect(param.applicationUserName, 'acct');
    });

    test('an offer on a Google Play entry changes nothing: the entry is the offer', () {
      final entry = GooglePlayProductDetails.fromProductDetails(
        play.ProductDetailsWrapper(
          description: 'd',
          name: 'Pro',
          productId: 'com.example.pro',
          productType: play.ProductType.subs,
          title: 'Pro',
          subscriptionOfferDetails: [
            offer('monthly', 'trial7', [phase('P1M', 4990000)]),
          ],
        ),
      ).single;
      final PurchaseParam param = InAppPurchaseStoreBridge.purchaseParamFor(entry, 'acct', null);
      expect(param.productDetails, same(entry));
      expect((param.productDetails as GooglePlayProductDetails).offerToken, 'token-monthly-trial7');
    });
  });
}

const monthlyPeriod = SubscriptionPeriod(1, PeriodUnit.month);
