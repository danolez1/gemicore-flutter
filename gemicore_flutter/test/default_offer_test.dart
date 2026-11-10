import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter/src/paywall_variables.dart';

import 'fakes.dart';

const weekTrial = SubscriptionPeriod(7, PeriodUnit.day);

Map<String, Object?> androidOfferings({String? defaultOfferId = 'trial7'}) {
  final base = offeringsJson();
  final offering = ((base['offerings'] as List).first as Map).cast<String, Object?>();
  return {
    ...base,
    'offerings': [
      {
        ...offering,
        'packages': [
          {
            'identifier': r'$rc_monthly',
            'packageType': 'monthly',
            'displayName': null,
            'product': productViewJson(
              'pro_monthly',
              storeProductId: 'com.example.pro',
              googleBasePlanId: 'monthly',
              defaultGoogleOfferId: defaultOfferId,
            ),
          },
        ],
      },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness(platform: 'android');
    h.transport.json('GET', '/v1/purchases/products', {
      'products': [
        productViewJson(
          'pro_monthly',
          storeProductId: 'com.example.pro',
          googleBasePlanId: 'monthly',
          defaultGoogleOfferId: 'trial7',
        ),
      ],
    });
    h.transport.json('GET', '/v1/purchases/offerings', androidOfferings());
    h.transport.json('POST', '/v1/purchases', {
      'customer': customerJson(pro: true),
      'purchase': purchaseJson(store: 'play_store'),
    });
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Future<PurchaseResult> buyAndComplete(Gemicore sdk, GemicoreProduct product) async {
    final future = sdk.purchase(product);
    await Future<void>.delayed(Duration.zero);
    h.store.emit(
      const StorePurchaseUpdate(
        productId: 'com.example.pro',
        state: StorePurchaseState.purchased,
        serverVerificationData: 'token-1',
        needsCompletion: true,
      ),
    );
    return future;
  }

  void listBoth({bool offer = true}) => h.store.catalog.addAll([
    storeDetail('com.example.pro', basePlanId: 'monthly', period: monthly),
    storeDetail('com.example.pro', basePlanId: 'yearly', price: '\$39.99', period: annual),
    if (offer)
      storeDetail(
        'com.example.pro',
        basePlanId: 'monthly',
        offerId: 'trial7',
        price: 'Free',
        rawPrice: 0,
        period: monthly,
        trial: weekTrial,
      ),
    storeDetail(
      'com.example.pro',
      basePlanId: 'yearly',
      offerId: 'trial7',
      price: 'Free',
      rawPrice: 0,
      period: annual,
      trial: const SubscriptionPeriod(30, PeriodUnit.day),
    ),
  ]);

  test('buys the default offer when Play lists it for the base plan of the product', () async {
    listBoth();
    final sdk = await h.configure();
    final product = (await sdk.getProducts()).single;
    expect(product.defaultGoogleOfferId, 'trial7');
    await buyAndComplete(sdk, product);
    final bought = h.store.buys.single.details;
    expect(bought.offerId, 'trial7');
    // The offer of the product's own base plan, not the yearly one with the same offer id.
    expect(bought.basePlanId, 'monthly');
    expect(bought.trialPeriod!.value, 7);
  });

  test('buys the plain base plan when Play does not list the offer (not eligible)', () async {
    listBoth(offer: false);
    h.store.catalog.removeWhere((d) => d.basePlanId == 'yearly' && d.offerId != null);
    final sdk = await h.configure();
    final product = (await sdk.getProducts()).single;
    expect(product.defaultOfferDetails, isNull);
    await buyAndComplete(sdk, product);
    expect(h.store.buys.single.details.offerId, isNull);
    expect(h.store.buys.single.details.basePlanId, 'monthly');
  });

  test('buys the plain base plan when the catalog names no default offer', () async {
    h.transport.json('GET', '/v1/purchases/products', {
      'products': [
        productViewJson(
          'pro_monthly',
          storeProductId: 'com.example.pro',
          googleBasePlanId: 'monthly',
        ),
      ],
    });
    listBoth();
    final sdk = await h.configure();
    final product = (await sdk.getProducts()).single;
    await buyAndComplete(sdk, product);
    expect(h.store.buys.single.details.offerId, isNull);
  });

  test('an explicit offer wins over the default', () async {
    listBoth();
    h.store.catalog.add(
      storeDetail(
        'com.example.pro',
        basePlanId: 'monthly',
        offerId: 'winback',
        price: '\$1.99',
        period: monthly,
      ),
    );
    final sdk = await h.configure();
    final product = (await sdk.getProducts()).single;
    final future = sdk.purchase(
      product,
      offer: const ProductOffer(
        identifier: 'winback_offer',
        kind: OfferKind.promotional,
        displayName: 'Winback',
        eligibility: OfferEligibility.anyone,
        googleOfferId: 'winback',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(h.store.buys.single.details.offerId, 'winback');
    h.store.emit(
      const StorePurchaseUpdate(
        productId: 'com.example.pro',
        state: StorePurchaseState.canceled,
        serverVerificationData: '',
      ),
    );
    await future;
  });

  test(
    'the displayed price stays the regular price, the trial is the default offer trial',
    () async {
      listBoth();
      final sdk = await h.configure();
      final product = (await sdk.getProducts()).single;
      expect(product.priceString, '\$4.99');
      expect(product.rawPrice, 4.99);
      expect((product.defaultOfferDetails! as StoreProductDetails).offerId, 'trial7');
    },
  );

  test(
    '{{package.trial}} reflects the offer that will be bought, and is empty without one',
    () async {
      listBoth();
      final sdk = await h.configure();
      final package = (await sdk.getOfferings()).current!.monthly!;
      final variables = PackageVariables.of(
        package,
        stringsLocale: const Locale('en'),
        numberLocale: const Locale('en'),
      );
      expect(variables.trial, '7 days');
      expect(variables.price, '\$4.99');
    },
  );

  test('no trial text when the offer is not listed for this customer', () async {
    listBoth(offer: false);
    h.store.catalog.removeWhere((d) => d.basePlanId == 'yearly' && d.offerId != null);
    final sdk = await h.configure();
    final package = (await sdk.getOfferings()).current!.monthly!;
    final variables = PackageVariables.of(
      package,
      stringsLocale: const Locale('en'),
      numberLocale: const Locale('en'),
    );
    expect(variables.trial, isNull);
  });

  test('the default offer is not applied on iOS even if the server named one', () async {
    final ios = Harness();
    ios.transport.json('GET', '/v1/purchases/products', {
      'products': [
        productViewJson(
          'pro_monthly',
          storeProductId: 'com.example.pro',
          defaultGoogleOfferId: 'trial7',
        ),
      ],
    });
    ios.store.catalog.addAll([
      storeDetail('com.example.pro', period: monthly),
      storeDetail(
        'com.example.pro',
        offerId: 'trial7',
        price: 'Free',
        rawPrice: 0,
        trial: weekTrial,
      ),
    ]);
    final sdk = await ios.configure();
    final product = (await sdk.getProducts()).single;
    expect(product.defaultOfferDetails, isNull);
  });

  test('with no store details at all the product is simply not available', () async {
    final sdk = await h.configure();
    final product = (await sdk.getProducts()).single;
    expect(product.defaultOfferDetails, isNull);
    expect(product.availableInStore, isFalse);
  });
}
