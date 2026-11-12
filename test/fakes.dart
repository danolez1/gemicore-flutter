import 'dart:async';
import 'dart:convert';

import 'package:gemicore_flutter/gemicore_flutter.dart';

class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  Map<String, Object?> get json =>
      body == null ? const {} : (jsonDecode(body!) as Map).cast<String, Object?>();
}

typedef Handler = FutureOr<TransportResponse> Function(RecordedRequest request);

class FakeTransport implements GemicoreTransport {
  final List<RecordedRequest> requests = [];
  final Map<String, Handler> routes = {};

  void on(String method, String path, Handler handler) => routes['$method $path'] = handler;

  void json(String method, String path, Object body, {int status = 200}) =>
      on(method, path, (_) => TransportResponse(status, jsonEncode(body)));

  List<RecordedRequest> calls(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = RecordedRequest(method, url, headers, body);
    requests.add(request);
    final handler = routes['$method ${url.path}'];
    if (handler == null) {
      return TransportResponse(
        404,
        jsonEncode({
          'error': {'code': 'NOT_FOUND', 'message': 'no fake for $method ${url.path}'},
        }),
      );
    }
    return handler(request);
  }
}

class FakeStore implements StoreBridge {
  FakeStore({this.platform = 'ios', this.available = true});

  @override
  final String platform;
  bool available;

  /// When set, isAvailable throws it, like Play Billing that is not connected yet.
  Object? availabilityError;
  final controller = StreamController<List<StorePurchaseUpdate>>.broadcast();
  final List<StoreProductDetails> catalog = [];
  final List<
    ({
      String productId,
      bool consumable,
      String accountId,
      StoreProductDetails details,
      StorePurchaseOffer? offer,
    })
  >
  buys = [];
  final List<StorePurchaseUpdate> completed = [];
  final List<Set<String>> queries = [];
  final List<String> restores = [];
  List<StorePurchaseUpdate> restoreEmits = [];

  @override
  Future<bool> isAvailable() async {
    final error = availabilityError;
    if (error != null) throw error;
    return available;
  }

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => controller.stream;

  @override
  Future<List<StoreProductDetails>> queryProducts(Set<String> ids) async {
    queries.add(ids);
    return catalog.where((p) => ids.contains(p.id)).toList();
  }

  @override
  Future<void> buy(
    StoreProductDetails product, {
    required bool consumable,
    required String accountId,
    StorePurchaseOffer? offer,
  }) async {
    buys.add((
      productId: product.id,
      consumable: consumable,
      accountId: accountId,
      details: product,
      offer: offer,
    ));
  }

  @override
  Future<void> complete(StorePurchaseUpdate update) async => completed.add(update);

  @override
  Future<void> restore({required String accountId}) async {
    restores.add(accountId);
    if (restoreEmits.isNotEmpty) {
      scheduleMicrotask(() => controller.add(restoreEmits));
    }
  }

  void emit(StorePurchaseUpdate update) => controller.add([update]);
}

/// Storage whose writes can be made to fail, like a locked Keychain.
class FlakyStorage extends MemoryGemicoreStorage {
  bool failWrites = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('keychain locked');
    await super.write(key, value);
  }
}

class FakeOpener implements CheckoutOpener {
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

const customerId = '0b9c5f4e-6a1f-4c8e-9a52-2b7e1d3f4a10';

Map<String, Object?> purchaseJson({
  String id = 'p1',
  String status = 'active',
  bool isActive = true,
  String store = 'app_store',
  String productType = 'subscription',
  String? productIdentifier = 'pro_monthly',
}) => {
  'id': id,
  'productIdentifier': productIdentifier,
  'storeProductId': 'com.example.pro.monthly',
  'store': store,
  'productType': productType,
  'status': status,
  'isActive': isActive,
  'isSandbox': true,
  'willRenew': true,
  'periodType': 'trial',
  'purchasedAt': '2026-11-01T10:00:00.000Z',
  'originalPurchasedAt': '2026-11-01T10:00:00.000Z',
  'expiresAt': '2026-12-01T10:00:00.000Z',
  'gracePeriodExpiresAt': null,
  'billingIssueDetectedAt': null,
  'unsubscribeDetectedAt': null,
  'refundedAt': null,
  'ownership': 'family_shared',
  'priceAmount': 499,
  'priceCurrency': 'USD',
  'managementUrl': 'https://apps.apple.com/account/subscriptions',
};

Map<String, Object?> customerJson({
  String id = customerId,
  String? externalId,
  bool pro = false,
  List<Map<String, Object?>> purchases = const [],
}) {
  final entitlement = {
    'identifier': 'pro',
    'isActive': pro,
    'source': 'purchase',
    'productIdentifier': 'pro_monthly',
    'store': 'app_store',
    'willRenew': true,
    'periodType': 'trial',
    'purchasedAt': '2026-11-01T10:00:00.000Z',
    'expiresAt': '2026-12-01T10:00:00.000Z',
    'isSandbox': true,
    'billingIssueDetectedAt': null,
    'unsubscribeDetectedAt': null,
    'ownership': 'purchased',
    'managementUrl': 'https://apps.apple.com/account/subscriptions',
  };
  return {
    'id': id,
    'externalId': externalId,
    'entitlements': {
      'active': pro ? {'pro': entitlement} : <String, Object?>{},
      'all': pro ? {'pro': entitlement} : <String, Object?>{},
    },
    'activeSubscriptions': pro ? ['pro_monthly'] : <String>[],
    'purchases': purchases,
    'requestedAt': '2026-11-04T12:00:00.000Z',
  };
}

Map<String, Object?> session({String token = 'tok_1', Map<String, Object?>? customer}) => {
  'customer': customer ?? customerJson(),
  'token': token,
};

const productsJson = {
  'products': [
    {
      'identifier': 'pro_monthly',
      'type': 'subscription',
      'displayName': 'Pro monthly',
      'description': 'Everything',
      'storeProductId': 'com.example.pro.monthly',
      'googleBasePlanId': null,
      'entitlements': ['pro'],
      'card': null,
    },
    {
      'identifier': 'coins_100',
      'type': 'consumable',
      'displayName': '100 coins',
      'description': null,
      'storeProductId': 'com.example.coins100',
      'googleBasePlanId': null,
      'entitlements': <String>[],
      'card': null,
    },
    {
      'identifier': 'tshirt',
      'type': 'non_consumable',
      'displayName': 'T-shirt',
      'description': null,
      'storeProductId': null,
      'googleBasePlanId': null,
      'entitlements': <String>[],
      'card': {'amount': 2500, 'currency': 'USD'},
    },
  ],
};

const liveKey = 'pk_live_abcdefghijklmnopqrstuvwxyz012345';
const testKey = 'pk_test_abcdefghijklmnopqrstuvwxyz012345';

StoreProductDetails storeDetail(
  String id, {
  String price = '\$4.99',
  double rawPrice = 4.99,
  String? basePlanId,
  String? offerId,
  SubscriptionPeriod? period,
  SubscriptionPeriod? trial,
}) => StoreProductDetails(
  id: id,
  title: id,
  price: price,
  rawPrice: rawPrice,
  currencyCode: 'USD',
  basePlanId: basePlanId,
  offerId: offerId,
  subscriptionPeriod: period,
  trialPeriod: trial,
);

class FakeNativePaySheet implements NativePaySheet {
  FakeNativePaySheet(this.result);

  NativePayResult result;
  Object? throws;
  final List<NativePayRequest> requests = [];

  @override
  Future<NativePayResult> present(NativePayRequest request) async {
    requests.add(request);
    final error = throws;
    if (error != null) throw error;
    return result;
  }
}

/// The SDK wired to fakes, the way gemicore_test.dart wires it.
class Harness {
  Harness({String platform = 'ios'}) : store = FakeStore(platform: platform) {
    transport.json('POST', '/v1/purchases/customers', session(), status: 201);
    transport.json('GET', '/v1/purchases/customer', customerJson());
    transport.json('GET', '/v1/purchases/products', productsJson);
  }

  final transport = FakeTransport();
  final FakeStore store;
  final storage = MemoryGemicoreStorage();
  final opener = FakeOpener();

  Future<Gemicore> configure({
    String apiKey = liveKey,
    bool? useTestStore,
    NativePaySheet? nativePaySheet,
    Duration cacheMaxAge = const Duration(minutes: 5),
    GemicoreStorage? storage,
    String? appUserId,
    UserTokenProvider? userTokenProvider,
    Duration recordRetryDelay = const Duration(seconds: 30),
    AppVersionProvider? appVersionProvider,
  }) => Gemicore.configure(
    apiKey: apiKey,
    baseUrl: 'https://api.test',
    appUserId: appUserId,
    userTokenProvider: userTokenProvider,
    recordRetryDelay: recordRetryDelay,
    // No platform channel in tests: the version comes from here, like the real one from package_info_plus.
    appVersionProvider: appVersionProvider ?? () async => '1.4.2',
    useTestStore: useTestStore,
    transport: transport,
    storage: storage ?? this.storage,
    store: store,
    checkoutOpener: opener,
    nativePaySheet: nativePaySheet,
    observeAppLifecycle: false,
    restoreQuietPeriod: const Duration(milliseconds: 50),
    restoreTimeout: const Duration(seconds: 2),
    cacheMaxAge: cacheMaxAge,
    logLevel: GemicoreLogLevel.none,
  );
}

/// The canonical paywall of services/api/src/stores/offerings/sample-paywall.ts.
Map<String, Object?> samplePaywallConfig() => {
  'version': 1,
  'defaultLocale': 'en',
  'theme': {
    'background': '#ffffff',
    'foreground': '#111827',
    'accent': '#4f46e5',
    'accentForeground': '#ffffff',
    'cornerRadius': 12,
    'fontScale': 1,
  },
  'strings': {
    'en': {
      'title': 'Go Pro',
      'subtitle': 'Full access to every feature, and you can cancel any time.',
      'price_line': '{{package.price}} per {{package.period}}',
      'trial_line': 'Start with {{package.trial}} free',
      'savings': 'Only {{package.pricePerMonth}} a month',
      'cta': 'Continue',
      'restore': 'Restore purchases',
    },
    'de': {
      'title': 'Pro werden',
      'subtitle': 'Voller Zugriff auf alle Funktionen, jederzeit kuendbar.',
      'price_line': '{{package.price}} pro {{package.period}}',
      'trial_line': '{{package.trial}} kostenlos testen',
      'savings': 'Nur {{package.pricePerMonth}} im Monat',
      'cta': 'Weiter',
      'restore': 'Kaeufe wiederherstellen',
    },
  },
  'root': {
    'type': 'stack',
    'direction': 'column',
    'spacing': 16,
    'padding': 24,
    'align': 'stretch',
    'children': [
      {
        'type': 'image',
        'url': 'https://example.com/paywall-hero.png',
        'aspect': 1.6,
        'fit': 'cover',
      },
      {'type': 'text', 'stringKey': 'title', 'style': 'title', 'align': 'center'},
      {'type': 'text', 'stringKey': 'subtitle', 'style': 'body', 'align': 'center'},
      {'type': 'package_list', 'layout': 'vertical', 'selected': null},
      {'type': 'text', 'stringKey': 'price_line', 'style': 'caption', 'align': 'center'},
      {'type': 'text', 'stringKey': 'trial_line', 'style': 'caption', 'align': 'center'},
      {'type': 'text', 'stringKey': 'savings', 'style': 'caption', 'align': 'center'},
      {'type': 'purchase_button', 'stringKey': 'cta'},
      {'type': 'restore_button', 'stringKey': 'restore'},
      {'type': 'divider'},
      {'type': 'spacer', 'size': 8},
      {
        'type': 'legal_links',
        'termsUrl': 'https://example.com/terms',
        'privacyUrl': 'https://example.com/privacy',
      },
    ],
  },
};

Map<String, Object?> productViewJson(
  String identifier, {
  String type = 'subscription',
  String? storeProductId,
  String? googleBasePlanId,
  String? defaultGoogleOfferId,
  Map<String, Object?>? card,
}) => {
  'identifier': identifier,
  'type': type,
  'displayName': identifier == 'pro_monthly'
      ? 'Pro monthly'
      : identifier == 'pro_annual'
      ? 'Pro annual'
      : identifier,
  'description': null,
  'storeProductId': storeProductId,
  'googleBasePlanId': googleBasePlanId,
  'defaultGoogleOfferId': defaultGoogleOfferId,
  'entitlements': ['pro'],
  'card': card,
};

/// One current offering with a monthly and an annual package and the sample paywall.
Map<String, Object?> offeringsJson({
  Object? paywallConfig = const SamplePaywall(),
  bool current = true,
  String platform = 'ios',
}) {
  final config = paywallConfig is SamplePaywall ? samplePaywallConfig() : paywallConfig;
  return {
    'current': current ? 'default' : null,
    'offerings': [
      {
        'identifier': 'default',
        'displayName': 'Default',
        'description': null,
        'metadata': {'campaign': 'launch'},
        'isCurrent': current,
        'packages': [
          {
            'identifier': r'$rc_monthly',
            'packageType': 'monthly',
            'displayName': null,
            'product': productViewJson('pro_monthly', storeProductId: 'com.example.pro.monthly'),
          },
          {
            'identifier': r'$rc_annual',
            'packageType': 'annual',
            'displayName': 'Pro annual',
            'product': productViewJson('pro_annual', storeProductId: 'com.example.pro.annual'),
          },
        ],
        'paywall': config == null
            ? null
            : {'offeringIdentifier': 'default', 'revision': 3, 'config': config},
      },
    ],
  };
}

/// Stands for "the canonical sample paywall" in [offeringsJson]; null means no paywall.
class SamplePaywall {
  const SamplePaywall();
}

const monthly = SubscriptionPeriod(1, PeriodUnit.month);
const annual = SubscriptionPeriod(1, PeriodUnit.year);
