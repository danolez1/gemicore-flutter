import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart' show RecurrenceMode;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

import 'subscription_period.dart';

/// A store product as the SDK needs it, independent of the plugin types so tests can fake the store.
class StoreProductDetails {
  const StoreProductDetails({
    required this.id,
    required this.title,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    this.basePlanId,
    this.offerId,
    this.subscriptionPeriod,
    this.trialPeriod,
    this.native,
  });

  final String id;
  final String title;
  final String price;
  final double rawPrice;
  final String currencyCode;

  /// Google Play only: the base plan these details describe.
  final String? basePlanId;

  /// Google Play only: the offer these details describe. Null for the plain base plan, which is the
  /// default a purchase buys; an offer is bought only when the app asks for it.
  final String? offerId;

  /// How long one paid period lasts, for subscriptions.
  final SubscriptionPeriod? subscriptionPeriod;

  /// The free trial the store product carries, if the plugin can read it. Whether this customer gets
  /// it is the store's decision at purchase time.
  final SubscriptionPeriod? trialPeriod;
  final Object? native;
}

/// A signed App Store promotional offer, in the fields StoreKit takes.
class StorePromotionalOffer {
  const StorePromotionalOffer({
    required this.offerId,
    required this.keyId,
    required this.nonce,
    required this.timestamp,
    required this.signature,
  });

  final String offerId;
  final String keyId;
  final String nonce;
  final int timestamp;
  final String signature;
}

/// What to attach to an App Store purchase. On Google Play an offer is chosen by passing the product
/// details of that offer to [StoreBridge.buy], so none of this applies there.
class StorePurchaseOffer {
  const StorePurchaseOffer({
    this.winBackOfferId,
    this.promotional,
    this.introductoryEligibilityJws,
  });

  /// A win-back offer id; StoreKit checks the customer's eligibility itself.
  final String? winBackOfferId;
  final StorePromotionalOffer? promotional;

  /// A JWS signed by Gemicore that overrides Apple's introductory offer eligibility.
  final String? introductoryEligibilityJws;
}

enum StorePurchaseState { pending, purchased, restored, canceled, error }

/// One event from the store's purchase stream.
class StorePurchaseUpdate {
  const StorePurchaseUpdate({
    required this.productId,
    required this.state,
    required this.serverVerificationData,
    this.errorMessage,
    this.needsCompletion = false,
    this.native,
  });

  final String productId;
  final StorePurchaseState state;

  /// App Store: the StoreKit 2 transaction JWS. Google Play: the purchase token.
  final String serverVerificationData;
  final String? errorMessage;
  final bool needsCompletion;
  final Object? native;
}

/// The App Store or Google Play, behind a small surface.
abstract interface class StoreBridge {
  /// ios or android; sent to the server so it answers with this platform's product ids.
  String get platform;

  Future<bool> isAvailable();

  Stream<List<StorePurchaseUpdate>> get purchaseUpdates;

  Future<List<StoreProductDetails>> queryProducts(Set<String> ids);

  /// Starts the store sheet. [accountId] becomes appAccountToken on iOS and obfuscatedAccountId on Android.
  /// [offer] is an App Store offer to apply; for a Google Play offer pass that offer's [product] instead.
  Future<void> buy(
    StoreProductDetails product, {
    required bool consumable,
    required String accountId,
    StorePurchaseOffer? offer,
  });

  /// Finishes the transaction (iOS) or acknowledges it (Android). Called only after the server recorded it.
  Future<void> complete(StorePurchaseUpdate update);

  Future<void> restore({required String accountId});
}

/// The real store, through the official in_app_purchase plugin.
class InAppPurchaseStoreBridge implements StoreBridge {
  InAppPurchaseStoreBridge({InAppPurchase? plugin, required this.platform})
    : _plugin = plugin ?? InAppPurchase.instance;

  final InAppPurchase _plugin;

  @override
  final String platform;

  @override
  Future<bool> isAvailable() => _plugin.isAvailable();

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates =>
      _plugin.purchaseStream.map((list) => list.map(_toUpdate).toList(growable: false));

  StorePurchaseUpdate _toUpdate(PurchaseDetails details) => StorePurchaseUpdate(
    productId: details.productID,
    state: switch (details.status) {
      PurchaseStatus.pending => StorePurchaseState.pending,
      PurchaseStatus.purchased => StorePurchaseState.purchased,
      PurchaseStatus.restored => StorePurchaseState.restored,
      PurchaseStatus.canceled => StorePurchaseState.canceled,
      PurchaseStatus.error => StorePurchaseState.error,
    },
    serverVerificationData: details.verificationData.serverVerificationData,
    errorMessage: details.error?.message,
    needsCompletion: details.pendingCompletePurchase,
    native: details,
  );

  @override
  Future<List<StoreProductDetails>> queryProducts(Set<String> ids) async {
    if (ids.isEmpty) return const [];
    final response = await _plugin.queryProductDetails(ids);
    final trials = platform == 'ios' ? await _introTrials(response.productDetails) : const {};
    return response.productDetails
        .map((details) => toStoreProduct(details, introTrial: trials[details.id]))
        .toList(growable: false);
  }

  // StoreKit 2 products in the plugin do not carry the introductory offer, StoreKit 1 products do, so
  // the free trials are read through a StoreKit 1 product request. Failing here only hides trial text.
  Future<Map<String, SubscriptionPeriod>> _introTrials(List<ProductDetails> products) async {
    final ids = [
      for (final p in products)
        if (p is AppStoreProduct2Details && p.sk2Product.subscription != null) p.id,
    ];
    if (ids.isEmpty) return const {};
    try {
      final response = await SKRequestMaker().startProductRequest(ids);
      return {
        for (final product in response.products)
          product.productIdentifier: ?_freeTrial(product.introductoryPrice),
      };
    } catch (_) {
      return const {};
    }
  }

  static SubscriptionPeriod? _freeTrial(SKProductDiscountWrapper? discount) {
    if (discount == null || discount.paymentMode != SKProductDiscountPaymentMode.freeTrail) {
      return null;
    }
    final period = _fromSk1(discount.subscriptionPeriod);
    if (period == null) return null;
    return SubscriptionPeriod(
      period.value * (discount.numberOfPeriods < 1 ? 1 : discount.numberOfPeriods),
      period.unit,
    );
  }

  static SubscriptionPeriod? _fromSk1(SKProductSubscriptionPeriodWrapper? period) {
    if (period == null || period.numberOfUnits < 1) return null;
    return SubscriptionPeriod(period.numberOfUnits, switch (period.unit) {
      SKSubscriptionPeriodUnit.day => PeriodUnit.day,
      SKSubscriptionPeriodUnit.week => PeriodUnit.week,
      SKSubscriptionPeriodUnit.month => PeriodUnit.month,
      SKSubscriptionPeriodUnit.year => PeriodUnit.year,
    });
  }

  static SubscriptionPeriod? _fromSk2(SK2SubscriptionPeriod? period) {
    if (period == null || period.value < 1) return null;
    return SubscriptionPeriod(period.value, switch (period.unit) {
      SK2SubscriptionPeriodUnit.day => PeriodUnit.day,
      SK2SubscriptionPeriodUnit.week => PeriodUnit.week,
      SK2SubscriptionPeriodUnit.month => PeriodUnit.month,
      SK2SubscriptionPeriodUnit.year => PeriodUnit.year,
    });
  }

  /// Reads the plugin's product details into the SDK's own type. [introTrial] is the free trial found
  /// by a StoreKit 1 request for a StoreKit 2 product.
  @visibleForTesting
  static StoreProductDetails toStoreProduct(
    ProductDetails details, {
    SubscriptionPeriod? introTrial,
  }) {
    String? basePlanId;
    String? offerId;
    SubscriptionPeriod? period;
    SubscriptionPeriod? trial = introTrial;
    if (details is GooglePlayProductDetails) {
      final index = details.subscriptionIndex;
      final offers = details.productDetails.subscriptionOfferDetails;
      if (index != null && offers != null && index < offers.length) {
        final entry = offers[index];
        basePlanId = entry.basePlanId;
        offerId = entry.offerId;
        for (final phase in entry.pricingPhases) {
          final phasePeriod = SubscriptionPeriod.fromIso8601(phase.billingPeriod);
          if (phasePeriod == null) continue;
          if (phase.recurrenceMode == RecurrenceMode.infiniteRecurring) {
            period = phasePeriod;
          } else if (trial == null &&
              phase.priceAmountMicros == 0 &&
              phase.recurrenceMode == RecurrenceMode.finiteRecurring) {
            final cycles = phase.billingCycleCount < 1 ? 1 : phase.billingCycleCount;
            trial = SubscriptionPeriod(phasePeriod.value * cycles, phasePeriod.unit);
          }
        }
      }
    } else if (details is AppStoreProduct2Details) {
      period = _fromSk2(details.sk2Product.subscription?.subscriptionPeriod);
    } else if (details is AppStoreProductDetails) {
      period = _fromSk1(details.skProduct.subscriptionPeriod);
      trial ??= _freeTrial(details.skProduct.introductoryPrice);
    }
    return StoreProductDetails(
      id: details.id,
      title: details.title,
      price: details.price,
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      basePlanId: basePlanId,
      offerId: offerId,
      subscriptionPeriod: period,
      trialPeriod: trial,
      native: details,
    );
  }

  @override
  Future<void> buy(
    StoreProductDetails product, {
    required bool consumable,
    required String accountId,
    StorePurchaseOffer? offer,
  }) async {
    final native = product.native;
    if (native is! ProductDetails) {
      throw StateError('Product ${product.id} has no store details');
    }
    // applicationUserName maps to the StoreKit 2 appAccountToken and to Play's obfuscatedAccountId
    // (in_app_purchase_storekit buyNonConsumable, in_app_purchase_android launchBillingFlow accountId).
    final param = purchaseParamFor(native, accountId, offer);
    if (consumable) {
      // The server consumes Play consumables after it has recorded them, so the client must not.
      await _plugin.buyConsumable(purchaseParam: param, autoConsume: false);
    } else {
      await _plugin.buyNonConsumable(purchaseParam: param);
    }
  }

  /// The plugin's purchase parameters for [native], with [offer] attached on the App Store.
  @visibleForTesting
  static PurchaseParam purchaseParamFor(
    ProductDetails native,
    String accountId,
    StorePurchaseOffer? offer,
  ) {
    final promotional = offer?.promotional;
    if (offer != null && native is AppStoreProduct2Details) {
      // The legacy signature block is what the plugin's StoreKit 2 promotional offer takes.
      return Sk2PurchaseParam(
        productDetails: native,
        applicationUserName: accountId,
        winBackOfferId: offer.winBackOfferId,
        introductoryOfferEligibilityCompactJWS: offer.introductoryEligibilityJws,
        promotionalOffer: promotional == null
            ? null
            : SK2PromotionalOffer(
                offerId: promotional.offerId,
                signature: SK2SubscriptionOfferSignature(
                  keyID: promotional.keyId,
                  nonce: promotional.nonce,
                  timestamp: promotional.timestamp,
                  signature: promotional.signature,
                ),
              ),
      );
    }
    if (promotional != null && native is AppStoreProductDetails) {
      return AppStorePurchaseParam(
        productDetails: native,
        applicationUserName: accountId,
        discount: SKPaymentDiscountWrapper(
          identifier: promotional.offerId,
          keyIdentifier: promotional.keyId,
          nonce: promotional.nonce,
          signature: promotional.signature,
          timestamp: promotional.timestamp,
        ),
      );
    }
    return PurchaseParam(productDetails: native, applicationUserName: accountId);
  }

  @override
  Future<void> complete(StorePurchaseUpdate update) async {
    final native = update.native;
    if (native is PurchaseDetails && native.pendingCompletePurchase) {
      await _plugin.completePurchase(native);
    }
  }

  @override
  Future<void> restore({required String accountId}) =>
      _plugin.restorePurchases(applicationUserName: accountId);
}
