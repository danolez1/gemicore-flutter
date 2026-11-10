// Models mirror the purchases wire contract in packages/contracts/src/purchases.ts field for field.

/// The kind of product, as configured in the Gemicore dashboard.
enum ProductType {
  subscription,
  consumable,
  nonConsumable,
  nonRenewing,
  unknown;

  static ProductType parse(Object? value) => switch (value) {
    'subscription' => ProductType.subscription,
    'consumable' => ProductType.consumable,
    'non_consumable' => ProductType.nonConsumable,
    'non_renewing' => ProductType.nonRenewing,
    _ => ProductType.unknown,
  };

  String get wireName => switch (this) {
    ProductType.subscription => 'subscription',
    ProductType.consumable => 'consumable',
    ProductType.nonConsumable => 'non_consumable',
    ProductType.nonRenewing => 'non_renewing',
    ProductType.unknown => 'unknown',
  };
}

/// Where a purchase was made.
enum PurchaseStore {
  appStore,
  playStore,
  card,
  testStore,
  unknown;

  static PurchaseStore parse(Object? value) => switch (value) {
    'app_store' => PurchaseStore.appStore,
    'play_store' => PurchaseStore.playStore,
    'card' => PurchaseStore.card,
    'test_store' => PurchaseStore.testStore,
    _ => PurchaseStore.unknown,
  };

  String get wireName => switch (this) {
    PurchaseStore.appStore => 'app_store',
    PurchaseStore.playStore => 'play_store',
    PurchaseStore.card => 'card',
    PurchaseStore.testStore => 'test_store',
    PurchaseStore.unknown => 'unknown',
  };
}

enum PeriodType {
  normal,
  trial,
  intro,
  promotional;

  static PeriodType parse(Object? value) => switch (value) {
    'trial' => PeriodType.trial,
    'intro' => PeriodType.intro,
    'promotional' => PeriodType.promotional,
    _ => PeriodType.normal,
  };
}

enum Ownership {
  purchased,
  familyShared;

  static Ownership parse(Object? value) =>
      value == 'family_shared' ? Ownership.familyShared : Ownership.purchased;
}

enum EntitlementSource {
  purchase,
  granted;

  static EntitlementSource parse(Object? value) =>
      value == 'granted' ? EntitlementSource.granted : EntitlementSource.purchase;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};

String? _string(Object? value) => value is String ? value : null;

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('Expected a string at "$key"');
}

bool _bool(Object? value) => value == true;

int? _int(Object? value) => value is num ? value.toInt() : null;

DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList(growable: false) : const <String>[];

/// A price for paying by card, Apple Pay or Google Pay, in minor units (cents).
class CardPrice {
  const CardPrice({required this.amount, required this.currency});

  factory CardPrice.fromJson(Map<String, Object?> json) =>
      CardPrice(amount: _int(json['amount']) ?? 0, currency: _requiredString(json, 'currency'));

  final int amount;
  final String currency;

  Map<String, Object?> toJson() => {'amount': amount, 'currency': currency};
}

/// A product as the server describes it, before store prices are merged in.
class ProductView {
  const ProductView({
    required this.identifier,
    required this.type,
    required this.displayName,
    this.description,
    this.storeProductId,
    this.googleBasePlanId,
    this.defaultGoogleOfferId,
    this.entitlements = const [],
    this.card,
  });

  factory ProductView.fromJson(Map<String, Object?> json) => ProductView(
    identifier: _requiredString(json, 'identifier'),
    type: ProductType.parse(json['type']),
    displayName: _string(json['displayName']) ?? '',
    description: _string(json['description']),
    storeProductId: _string(json['storeProductId']),
    googleBasePlanId: _string(json['googleBasePlanId']),
    defaultGoogleOfferId: _string(json['defaultGoogleOfferId']),
    entitlements: _strings(json['entitlements']),
    card: json['card'] is Map ? CardPrice.fromJson(_map(json['card'])) : null,
  );

  final String identifier;
  final ProductType type;
  final String displayName;
  final String? description;
  final String? storeProductId;
  final String? googleBasePlanId;

  /// Google Play offer id the server names as this product's default; null elsewhere.
  final String? defaultGoogleOfferId;
  final List<String> entitlements;
  final CardPrice? card;
}

/// A product ready to show and sell: the server catalog entry merged with the store's localized price.
class GemicoreProduct {
  const GemicoreProduct({
    required this.identifier,
    required this.type,
    required this.title,
    this.description,
    this.storeProductId,
    this.googleBasePlanId,
    this.defaultGoogleOfferId,
    this.entitlements = const [],
    this.card,
    this.priceString,
    this.rawPrice,
    this.currencyCode,
    this.storeDetails,
    this.defaultOfferDetails,
    this.storeVariants = const [],
  });

  /// The id configured in the dashboard, the same on every platform.
  final String identifier;
  final ProductType type;
  final String title;
  final String? description;

  /// The App Store or Google Play product id for this device's platform.
  final String? storeProductId;
  final String? googleBasePlanId;

  /// Google Play offer id the dashboard marks as this product's default (a free trial, usually).
  final String? defaultGoogleOfferId;
  final List<String> entitlements;

  /// Set when the product can be paid by card, Apple Pay or Google Pay through [Gemicore.payWithCard].
  final CardPrice? card;

  /// The store's localized price, for example "\$4.99". Null when the store does not sell it here.
  final String? priceString;
  final double? rawPrice;
  final String? currencyCode;

  /// Whether the store on this device can sell this product.
  bool get availableInStore => storeDetails != null;

  /// The plugin's product details, kept so a purchase can be started without another store query.
  final Object? storeDetails;

  /// Google Play only: the store entry of [defaultGoogleOfferId], set when Play lists that offer for
  /// this customer (Play lists only the offers the customer is eligible for). A purchase with no
  /// explicit offer buys this entry, and `{{package.trial}}` reads its trial.
  final Object? defaultOfferDetails;

  /// Every store entry for this product id. Google Play lists one per base plan and per offer, and a
  /// purchase with an offer picks the entry whose offer id the catalog names.
  final List<Object> storeVariants;
}

/// One purchase on the customer's record.
class PurchaseInfo {
  const PurchaseInfo({
    required this.id,
    required this.productIdentifier,
    required this.storeProductId,
    required this.store,
    required this.productType,
    required this.status,
    required this.isActive,
    required this.isSandbox,
    required this.willRenew,
    required this.periodType,
    required this.purchasedAt,
    required this.originalPurchasedAt,
    this.expiresAt,
    this.gracePeriodExpiresAt,
    this.billingIssueDetectedAt,
    this.unsubscribeDetectedAt,
    this.refundedAt,
    this.ownership = Ownership.purchased,
    this.priceAmount,
    this.priceCurrency,
    this.managementUrl,
  });

  factory PurchaseInfo.fromJson(Map<String, Object?> json) => PurchaseInfo(
    id: _requiredString(json, 'id'),
    productIdentifier: _string(json['productIdentifier']),
    storeProductId: _string(json['storeProductId']) ?? '',
    store: PurchaseStore.parse(json['store']),
    productType: ProductType.parse(json['productType']),
    status: _string(json['status']) ?? 'unknown',
    isActive: _bool(json['isActive']),
    isSandbox: _bool(json['isSandbox']),
    willRenew: _bool(json['willRenew']),
    periodType: PeriodType.parse(json['periodType']),
    purchasedAt: _date(json['purchasedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    originalPurchasedAt:
        _date(json['originalPurchasedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    expiresAt: _date(json['expiresAt']),
    gracePeriodExpiresAt: _date(json['gracePeriodExpiresAt']),
    billingIssueDetectedAt: _date(json['billingIssueDetectedAt']),
    unsubscribeDetectedAt: _date(json['unsubscribeDetectedAt']),
    refundedAt: _date(json['refundedAt']),
    ownership: Ownership.parse(json['ownership']),
    priceAmount: _int(json['priceAmount']),
    priceCurrency: _string(json['priceCurrency']),
    managementUrl: _string(json['managementUrl']),
  );

  final String id;
  final String? productIdentifier;
  final String storeProductId;
  final PurchaseStore store;
  final ProductType productType;

  /// The server's status word, for example active, in_grace_period, expired, refunded or pending.
  final String status;
  final bool isActive;
  final bool isSandbox;
  final bool willRenew;
  final PeriodType periodType;
  final DateTime purchasedAt;
  final DateTime originalPurchasedAt;
  final DateTime? expiresAt;
  final DateTime? gracePeriodExpiresAt;
  final DateTime? billingIssueDetectedAt;
  final DateTime? unsubscribeDetectedAt;
  final DateTime? refundedAt;
  final Ownership ownership;
  final int? priceAmount;
  final String? priceCurrency;
  final String? managementUrl;

  bool get isPending => status == 'pending';
}

/// Access to one entitlement, and what grants it.
class EntitlementInfo {
  const EntitlementInfo({
    required this.identifier,
    required this.isActive,
    required this.source,
    this.productIdentifier,
    this.store,
    this.willRenew = false,
    this.periodType = PeriodType.normal,
    this.purchasedAt,
    this.expiresAt,
    this.isSandbox = false,
    this.billingIssueDetectedAt,
    this.unsubscribeDetectedAt,
    this.ownership = Ownership.purchased,
    this.managementUrl,
  });

  factory EntitlementInfo.fromJson(Map<String, Object?> json) => EntitlementInfo(
    identifier: _requiredString(json, 'identifier'),
    isActive: _bool(json['isActive']),
    source: EntitlementSource.parse(json['source']),
    productIdentifier: _string(json['productIdentifier']),
    store: json['store'] == null ? null : PurchaseStore.parse(json['store']),
    willRenew: _bool(json['willRenew']),
    periodType: PeriodType.parse(json['periodType']),
    purchasedAt: _date(json['purchasedAt']),
    expiresAt: _date(json['expiresAt']),
    isSandbox: _bool(json['isSandbox']),
    billingIssueDetectedAt: _date(json['billingIssueDetectedAt']),
    unsubscribeDetectedAt: _date(json['unsubscribeDetectedAt']),
    ownership: Ownership.parse(json['ownership']),
    managementUrl: _string(json['managementUrl']),
  );

  final String identifier;
  final bool isActive;
  final EntitlementSource source;
  final String? productIdentifier;
  final PurchaseStore? store;
  final bool willRenew;
  final PeriodType periodType;
  final DateTime? purchasedAt;
  final DateTime? expiresAt;
  final bool isSandbox;
  final DateTime? billingIssueDetectedAt;
  final DateTime? unsubscribeDetectedAt;
  final Ownership ownership;
  final String? managementUrl;
}

/// Everything the app needs to decide what the current customer may use.
class CustomerInfo {
  const CustomerInfo({
    required this.id,
    this.externalId,
    this.activeEntitlements = const {},
    this.allEntitlements = const {},
    this.activeSubscriptions = const [],
    this.purchases = const [],
    required this.requestedAt,
    this.consumptionConsent,
    this.raw = const {},
  });

  factory CustomerInfo.fromJson(Map<String, Object?> json) {
    final entitlements = _map(json['entitlements']);
    Map<String, EntitlementInfo> parseSet(Object? value) =>
        _map(value).map((key, entry) => MapEntry(key, EntitlementInfo.fromJson(_map(entry))));
    return CustomerInfo(
      id: _requiredString(json, 'id'),
      externalId: _string(json['externalId']),
      activeEntitlements: parseSet(entitlements['active']),
      allEntitlements: parseSet(entitlements['all']),
      activeSubscriptions: _strings(json['activeSubscriptions']),
      purchases: (json['purchases'] is List ? json['purchases'] as List : const [])
          .map((p) => PurchaseInfo.fromJson(_map(p)))
          .toList(growable: false),
      requestedAt: _date(json['requestedAt']) ?? DateTime.now().toUtc(),
      consumptionConsent: json['consumptionConsent'] is Map
          ? ConsumptionConsent.fromJson(_map(json['consumptionConsent']))
          : null,
      raw: json,
    );
  }

  /// The Gemicore customer id. It is also the App Store appAccountToken and the Google Play
  /// obfuscated account id of every purchase this SDK starts.
  final String id;

  /// The id the app logged in with, or null while the customer is anonymous.
  final String? externalId;
  final Map<String, EntitlementInfo> activeEntitlements;
  final Map<String, EntitlementInfo> allEntitlements;
  final List<String> activeSubscriptions;
  final List<PurchaseInfo> purchases;
  final DateTime requestedAt;

  /// The refund review answer last stored with [Gemicore.setConsumptionConsent]. Null until the app
  /// has asked once on this device, or when the server did not return it.
  final ConsumptionConsent? consumptionConsent;

  /// The JSON this was parsed from, kept so the cache can store it unchanged.
  final Map<String, Object?> raw;

  bool get isAnonymous => externalId == null;

  /// Whether [identifier] is active now. The server's flag is a snapshot, and the snapshot can be
  /// days old when it comes from the offline cache, so an expiry that has passed ends the
  /// entitlement unless a purchase for the same product is still inside its grace period.
  bool hasEntitlement(String identifier) {
    final entitlement = activeEntitlements[identifier];
    if (entitlement == null) return false;
    final expiresAt = entitlement.expiresAt;
    final now = DateTime.now();
    if (expiresAt == null || expiresAt.isAfter(now)) return true;
    return purchases.any(
      (p) =>
          p.productIdentifier == entitlement.productIdentifier &&
          (p.gracePeriodExpiresAt?.isAfter(now) ?? false),
    );
  }

  PurchaseInfo? purchaseById(String id) {
    for (final purchase in purchases) {
      if (purchase.id == id) return purchase;
    }
    return null;
  }
}

/// Whether the customer lets the app share usage data with Apple when a refund is requested.
class ConsumptionConsent {
  const ConsumptionConsent({required this.consented, this.at});

  factory ConsumptionConsent.fromJson(Map<String, Object?> json) =>
      ConsumptionConsent(consented: _bool(json['consented']), at: _date(json['at']));

  final bool consented;

  /// When the answer was recorded, or null if the server did not say.
  final DateTime? at;

  Map<String, Object?> toJson() => {'consented': consented, 'at': at?.toUtc().toIso8601String()};
}

/// The outcome of [Gemicore.purchase] or [Gemicore.payWithCard].
class PurchaseResult {
  const PurchaseResult._(this.status, this.customerInfo, this.purchase);

  const PurchaseResult.completed(CustomerInfo customerInfo, PurchaseInfo? purchase)
    : this._(PurchaseResultStatus.completed, customerInfo, purchase);

  const PurchaseResult.cancelled(CustomerInfo? customerInfo)
    : this._(PurchaseResultStatus.cancelled, customerInfo, null);

  /// Ask to Buy, a slow card or a Google pending payment. The result arrives later through
  /// [Gemicore.customerInfoStream].
  const PurchaseResult.pending(CustomerInfo? customerInfo, PurchaseInfo? purchase)
    : this._(PurchaseResultStatus.pending, customerInfo, purchase);

  final PurchaseResultStatus status;
  final CustomerInfo? customerInfo;
  final PurchaseInfo? purchase;

  bool get isCompleted => status == PurchaseResultStatus.completed;
  bool get isCancelled => status == PurchaseResultStatus.cancelled;
  bool get isPending => status == PurchaseResultStatus.pending;
}

enum PurchaseResultStatus { completed, cancelled, pending }

/// What the server answers for create, log in and log out.
class CustomerSession {
  const CustomerSession({required this.customer, required this.token});

  factory CustomerSession.fromJson(Map<String, Object?> json) => CustomerSession(
    customer: CustomerInfo.fromJson(_map(json['customer'])),
    token: _requiredString(json, 'token'),
  );

  final CustomerInfo customer;
  final String token;
}

/// What the server answers when a card checkout starts.
class CheckoutStart {
  const CheckoutStart({required this.paymentId, required this.url, required this.purchase});

  factory CheckoutStart.fromJson(Map<String, Object?> json) => CheckoutStart(
    paymentId: _requiredString(json, 'paymentId'),
    url: _requiredString(json, 'url'),
    purchase: PurchaseInfo.fromJson(_map(json['purchase'])),
  );

  final String paymentId;
  final String url;
  final PurchaseInfo purchase;
}

Map<String, Object?> asJsonMap(Object? value) => _map(value);
