import 'models.dart';
import 'paywall_config.dart';

// Offerings, offers and the native pay intent, mirroring packages/contracts/src/purchases.ts.

Map<String, Object?> _map(Object? value) => asJsonMap(value);

String? _string(Object? value) => value is String ? value : null;

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('Expected a string at "$key"');
}

List<Object?> _list(Object? value) => value is List ? value : const [];

enum PackageType {
  monthly,
  annual,
  weekly,
  twoMonth,
  threeMonth,
  sixMonth,
  lifetime,
  custom;

  static PackageType parse(Object? value) => switch (value) {
    'monthly' => PackageType.monthly,
    'annual' => PackageType.annual,
    'weekly' => PackageType.weekly,
    'two_month' => PackageType.twoMonth,
    'three_month' => PackageType.threeMonth,
    'six_month' => PackageType.sixMonth,
    'lifetime' => PackageType.lifetime,
    _ => PackageType.custom,
  };

  String get wireName => switch (this) {
    PackageType.twoMonth => 'two_month',
    PackageType.threeMonth => 'three_month',
    PackageType.sixMonth => 'six_month',
    _ => name,
  };
}

/// One thing an offering sells: a catalog product with a label and a type such as monthly.
class Package {
  const Package({
    required this.identifier,
    required this.packageType,
    required this.product,
    this.displayName,
  });

  final String identifier;
  final PackageType packageType;
  final String? displayName;

  /// The catalog product with this device's store price merged in, like [Gemicore.getProducts] returns.
  final GemicoreProduct product;
}

/// The published paywall of an offering. [config] is null when the server sent one this SDK cannot show.
class PaywallView {
  const PaywallView({required this.offeringIdentifier, required this.revision, this.config});

  factory PaywallView.fromJson(Map<String, Object?> json) => PaywallView(
    offeringIdentifier: _requiredString(json, 'offeringIdentifier'),
    revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
    config: PaywallConfig.tryParse(json['config']),
  );

  final String offeringIdentifier;
  final int revision;
  final PaywallConfig? config;
}

/// A set of packages to show together, for example the default paywall or a promotion.
class Offering {
  const Offering({
    required this.identifier,
    required this.displayName,
    required this.isCurrent,
    required this.packages,
    this.description,
    this.metadata = const {},
    this.paywall,
  });

  final String identifier;
  final String displayName;
  final String? description;
  final Map<String, Object?> metadata;
  final bool isCurrent;
  final List<Package> packages;

  /// The published paywall, or null when the offering has none.
  final PaywallView? paywall;

  Package? package(String identifier) {
    for (final candidate in packages) {
      if (candidate.identifier == identifier) return candidate;
    }
    return null;
  }

  Package? packageOfType(PackageType type) {
    for (final candidate in packages) {
      if (candidate.packageType == type) return candidate;
    }
    return null;
  }

  Package? get monthly => packageOfType(PackageType.monthly);
  Package? get annual => packageOfType(PackageType.annual);
  Package? get weekly => packageOfType(PackageType.weekly);
  Package? get lifetime => packageOfType(PackageType.lifetime);
}

class Offerings {
  const Offerings({required this.all, this.current, this.placement});

  /// The offering the dashboard marks as current, or null when none is set.
  final Offering? current;

  /// Every active offering by identifier.
  final Map<String, Offering> all;

  /// How a requested placement was resolved, or null when none was asked for or the server did not
  /// know it (an unknown placement is answered like no placement, and [current] is then the app's).
  /// When set, [current] is the offering the placement chose.
  final PlacementResolution? placement;

  Offering? operator [](String identifier) => all[identifier];
}

// The wire shapes, before store prices are merged in.

class PackageView {
  const PackageView({
    required this.identifier,
    required this.packageType,
    required this.product,
    this.displayName,
  });

  factory PackageView.fromJson(Map<String, Object?> json) => PackageView(
    identifier: _requiredString(json, 'identifier'),
    packageType: PackageType.parse(json['packageType']),
    displayName: _string(json['displayName']),
    product: ProductView.fromJson(_map(json['product'])),
  );

  final String identifier;
  final PackageType packageType;
  final String? displayName;
  final ProductView product;
}

class OfferingView {
  const OfferingView({
    required this.identifier,
    required this.displayName,
    required this.isCurrent,
    required this.packages,
    this.description,
    this.metadata = const {},
    this.paywall,
  });

  factory OfferingView.fromJson(Map<String, Object?> json) => OfferingView(
    identifier: _requiredString(json, 'identifier'),
    displayName: _string(json['displayName']) ?? '',
    description: _string(json['description']),
    metadata: _map(json['metadata']),
    isCurrent: json['isCurrent'] == true,
    packages: [for (final p in _list(json['packages'])) PackageView.fromJson(_map(p))],
    paywall: json['paywall'] is Map ? PaywallView.fromJson(_map(json['paywall'])) : null,
  );

  final String identifier;
  final String displayName;
  final String? description;
  final Map<String, Object?> metadata;
  final bool isCurrent;
  final List<PackageView> packages;
  final PaywallView? paywall;
}

class OfferingsView {
  const OfferingsView({required this.offerings, this.current, this.placement});

  factory OfferingsView.fromJson(Map<String, Object?> json) => OfferingsView(
    current: _string(json['current']),
    offerings: [for (final o in _list(json['offerings'])) OfferingView.fromJson(_map(o))],
    placement: json['placement'] is Map
        ? PlacementResolution.fromJson(_map(json['placement']))
        : null,
  );

  final String? current;
  final List<OfferingView> offerings;
  final PlacementResolution? placement;
}

// Placements

enum PlacementSource {
  experiment,
  rule,
  defaultOffering,
  current,
  unknown;

  static PlacementSource parse(Object? value) => switch (value) {
    'experiment' => PlacementSource.experiment,
    'rule' => PlacementSource.rule,
    'default' => PlacementSource.defaultOffering,
    'current' => PlacementSource.current,
    _ => PlacementSource.unknown,
  };
}

/// The experiment a customer is enrolled in for a placement, and the variant they were given.
class ExperimentAssignment {
  const ExperimentAssignment({required this.identifier, required this.variant});

  factory ExperimentAssignment.fromJson(Map<String, Object?> json) => ExperimentAssignment(
    identifier: _requiredString(json, 'identifier'),
    variant: _requiredString(json, 'variant'),
  );

  final String identifier;
  final String variant;
}

/// Why a placement answered with the offering it did: a running experiment, a targeting rule, the
/// placement's default offering, or the app's current offering.
class PlacementResolution {
  const PlacementResolution({required this.identifier, required this.source, this.experiment});

  factory PlacementResolution.fromJson(Map<String, Object?> json) => PlacementResolution(
    identifier: _requiredString(json, 'identifier'),
    source: PlacementSource.parse(json['source']),
    experiment: json['experiment'] is Map
        ? ExperimentAssignment.fromJson(_map(json['experiment']))
        : null,
  );

  final String identifier;
  final PlacementSource source;

  /// Set when [source] is [PlacementSource.experiment].
  final ExperimentAssignment? experiment;
}

// Offers

enum OfferKind {
  promotional,
  winBack,
  offerCode,
  intro,
  unknown;

  static OfferKind parse(Object? value) => switch (value) {
    'promotional' => OfferKind.promotional,
    'win_back' => OfferKind.winBack,
    'offer_code' => OfferKind.offerCode,
    'intro' => OfferKind.intro,
    _ => OfferKind.unknown,
  };
}

enum OfferEligibility {
  anyone,
  existingSubscriber,
  lapsedSubscriber;

  static OfferEligibility parse(Object? value) => switch (value) {
    'existing_subscriber' => OfferEligibility.existingSubscriber,
    'lapsed_subscriber' => OfferEligibility.lapsedSubscriber,
    _ => OfferEligibility.anyone,
  };
}

/// A discount the customer can use on one product, from [Gemicore.getEligibleOffers]. Pass it to
/// [Gemicore.purchase] to apply it.
class ProductOffer {
  const ProductOffer({
    required this.identifier,
    required this.kind,
    required this.displayName,
    required this.eligibility,
    this.appleOfferIdentifier,
    this.googleOfferId,
    this.isDefault = false,
  });

  factory ProductOffer.fromJson(Map<String, Object?> json) => ProductOffer(
    identifier: _requiredString(json, 'identifier'),
    kind: OfferKind.parse(json['kind']),
    displayName: _string(json['displayName']) ?? '',
    appleOfferIdentifier: _string(json['appleOfferIdentifier']),
    googleOfferId: _string(json['googleOfferId']),
    eligibility: OfferEligibility.parse(json['eligibility']),
    isDefault: json['isDefault'] == true,
  );

  /// The catalog identifier, the same on every platform.
  final String identifier;
  final OfferKind kind;
  final String displayName;
  final String? appleOfferIdentifier;
  final String? googleOfferId;
  final OfferEligibility eligibility;

  /// True for the one offer of its product that the SDK buys by default on Google Play.
  final bool isDefault;
}

/// What the server answers for a promotional offer signature. [legacy] carries the key id, nonce,
/// timestamp and signature that the StoreKit plugin takes; [signature] is the StoreKit 2 JWS.
class PromotionalOfferSignature {
  const PromotionalOfferSignature({
    required this.productId,
    required this.offerIdentifier,
    required this.signature,
    this.legacy,
  });

  factory PromotionalOfferSignature.fromJson(Map<String, Object?> json) {
    final legacy = json['legacy'] is Map ? _map(json['legacy']) : null;
    return PromotionalOfferSignature(
      productId: _requiredString(json, 'productId'),
      offerIdentifier: _requiredString(json, 'offerIdentifier'),
      signature: _requiredString(json, 'signature'),
      legacy: legacy == null
          ? null
          : LegacyOfferSignature(
              keyIdentifier: _requiredString(legacy, 'keyIdentifier'),
              nonce: _requiredString(legacy, 'nonce'),
              timestamp: legacy['timestamp'] is num ? (legacy['timestamp'] as num).toInt() : 0,
              signature: _requiredString(legacy, 'signature'),
            ),
    );
  }

  final String productId;
  final String offerIdentifier;
  final String signature;
  final LegacyOfferSignature? legacy;
}

class LegacyOfferSignature {
  const LegacyOfferSignature({
    required this.keyIdentifier,
    required this.nonce,
    required this.timestamp,
    required this.signature,
  });

  final String keyIdentifier;
  final String nonce;
  final int timestamp;
  final String signature;
}

class IntroEligibilityView {
  const IntroEligibilityView({
    required this.productId,
    required this.allowIntroductoryOffer,
    required this.signature,
  });

  factory IntroEligibilityView.fromJson(Map<String, Object?> json) => IntroEligibilityView(
    productId: _requiredString(json, 'productId'),
    allowIntroductoryOffer: json['allowIntroductoryOffer'] == true,
    signature: _requiredString(json, 'signature'),
  );

  final String productId;
  final bool allowIntroductoryOffer;
  final String signature;
}

/// What the server answers when a native pay intent starts.
class CardIntentView {
  const CardIntentView({
    required this.paymentId,
    required this.clientSecret,
    required this.publishableKey,
    required this.merchantCountryCode,
    required this.purchase,
    this.applePayMerchantId,
    this.merchantDisplayName = '',
  });

  factory CardIntentView.fromJson(Map<String, Object?> json) => CardIntentView(
    paymentId: _requiredString(json, 'paymentId'),
    clientSecret: _requiredString(json, 'clientSecret'),
    publishableKey: _requiredString(json, 'publishableKey'),
    merchantCountryCode: _requiredString(json, 'merchantCountryCode'),
    applePayMerchantId: _string(json['applePayMerchantId']),
    merchantDisplayName: _string(json['merchantDisplayName']) ?? '',
    purchase: PurchaseInfo.fromJson(_map(json['purchase'])),
  );

  final String paymentId;
  final String clientSecret;
  final String publishableKey;
  final String merchantCountryCode;
  final String? applePayMerchantId;

  /// The app's name for the payment sheet; empty from a server that does not send it yet.
  final String merchantDisplayName;
  final PurchaseInfo purchase;
}
