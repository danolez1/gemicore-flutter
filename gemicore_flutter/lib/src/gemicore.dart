import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api_client.dart';
import 'customer_center_config.dart';
import 'errors.dart';
import 'models.dart';
import 'native_pay.dart';
import 'offerings.dart';
import 'storage.dart';
import 'store_bridge.dart';
import 'url_opener.dart';

enum GemicoreLogLevel { none, error, info, debug }

/// Returns the signed in app user's Gemicore access token, or null when there is none. Needed only
/// when the app's identity mode is "verified" in the dashboard, where linking a customer to an app
/// user id has to be proven. The SDK calls it just before a request that names a user.
typedef UserTokenProvider = Future<String?> Function();

/// Returns the host app's version name, for example "2.3.1". The SDK sends it so placements can
/// target by app version. By default it is read with package_info_plus.
typedef AppVersionProvider = Future<String?> Function();

// The server keeps versions of one to four dotted numbers; a suffix such as -beta.3 is dropped.
final _versionNumber = RegExp(r'^\d{1,9}(\.\d{1,9}){0,3}');

Future<String?> _defaultAppVersion() async => (await PackageInfo.fromPlatform()).version;

// Field of a saved offerings answer that names the customer it was resolved for.
const _offeringsOwner = 'gemicoreCustomerId';

// Placements are plain names; the key is encoded so no character reaches the storage key unchanged.
String _placementKey(String? placement) => placement == null ? '' : Uri.encodeComponent(placement);

class _OfferingsEntry {
  _OfferingsEntry(this.offerings, this.fetchedAt);

  final Offerings offerings;

  /// Null for a copy read from the device, so the next call asks the network again.
  final DateTime? fetchedAt;
}

/// The Gemicore purchases SDK. Configure once with the app's publishable key; the dashboard holds
/// the store credentials and the product catalog, so nothing else is set in code.
class Gemicore with WidgetsBindingObserver {
  Gemicore._({
    required GemicoreApiClient api,
    required GemicoreStorage storage,
    required StoreBridge store,
    required CheckoutOpener checkoutOpener,
    required NativePaySheet? nativePaySheet,
    required bool? useTestStore,
    required GemicoreLogLevel logLevel,
    required Duration restoreQuietPeriod,
    required Duration restoreTimeout,
    required Duration cacheMaxAge,
    required UserTokenProvider? userTokenProvider,
    required Duration recordRetryDelay,
  }) : _api = api,
       _storage = storage,
       _store = store,
       _checkoutOpener = checkoutOpener,
       _nativePaySheet = nativePaySheet,
       _useTestStoreSetting = useTestStore,
       _logLevel = logLevel,
       _restoreQuietPeriod = restoreQuietPeriod,
       _restoreTimeout = restoreTimeout,
       _cacheMaxAge = cacheMaxAge,
       _userTokenProvider = userTokenProvider,
       _recordRetryDelay = recordRetryDelay;

  static const defaultBaseUrl = 'https://api.gemicore.com';
  static const sdkVersion = '0.3.0';

  static Gemicore? _instance;

  /// The configured SDK. Throws until [configure] has finished.
  static Gemicore get instance {
    final configured = _instance;
    if (configured == null) {
      throw const GemicoreException(
        GemicoreErrorCode.notConfigured,
        'Call Gemicore.configure(apiKey: ...) before using the SDK',
      );
    }
    return configured;
  }

  static bool get isConfigured => _instance != null;

  /// Sets the SDK up. [apiKey] is the app's publishable key from the Gemicore dashboard and is the
  /// only required value: test keys (pk_test_) talk to store sandboxes and the test store, live keys
  /// to production. [appUserId] logs the customer in at once when the app already knows who it is.
  ///
  /// [nativePaySheet] is optional and only needed for [payWithSheet]: pass the sheet from the
  /// gemicore_flutter_stripe package to take Apple Pay and Google Pay inside the app.
  ///
  /// [userTokenProvider] is only for apps that turned on verified identity in the dashboard: it
  /// returns the signed in user's Gemicore access token, which the SDK sends when it links the
  /// customer to [appUserId] or to a [logIn] id. Leave it out otherwise.
  ///
  /// The other parameters exist for self hosting and tests. [appVersionProvider] replaces the
  /// package_info_plus lookup of the app version, which is sent as x-gemicore-app-version; when it
  /// fails the header is left out. Without it the lookup runs in the background, so the first
  /// requests of a launch can go out without the header.
  static Future<Gemicore> configure({
    required String apiKey,
    String? baseUrl,
    String? appUserId,
    GemicoreLogLevel logLevel = GemicoreLogLevel.error,
    bool? useTestStore,
    GemicoreTransport? transport,
    GemicoreStorage? storage,
    StoreBridge? store,
    CheckoutOpener? checkoutOpener,
    NativePaySheet? nativePaySheet,
    UserTokenProvider? userTokenProvider,
    AppVersionProvider? appVersionProvider,
    bool observeAppLifecycle = true,
    Duration restoreQuietPeriod = const Duration(milliseconds: 1500),
    Duration restoreTimeout = const Duration(seconds: 20),
    Duration cacheMaxAge = const Duration(minutes: 5),
    Duration recordRetryDelay = const Duration(seconds: 30),
  }) async {
    if (!apiKey.startsWith('pk_')) {
      // A secret key in an app binary can read and change every customer, so it is refused here.
      throw const GemicoreException(
        GemicoreErrorCode.notConfigured,
        'Use the publishable key (pk_test_ or pk_live_) in an app, never the secret key',
      );
    }
    await _instance?.close();
    final bridge = store ?? InAppPurchaseStoreBridge(platform: Platform.isIOS ? 'ios' : 'android');
    // A provider the app passed is awaited (bounded), so every request carries its answer. The
    // package_info_plus lookup runs in the background instead: it is an optional header, and a
    // platform channel that is slow, or missing in a host app's widget test, must not hold configure.
    final appVersion = appVersionProvider == null
        ? null
        : await _resolveAppVersion(appVersionProvider);
    final sdk = Gemicore._(
      api: GemicoreApiClient(
        apiKey: apiKey,
        baseUrl: Uri.parse(baseUrl ?? defaultBaseUrl),
        platform: bridge.platform,
        transport: transport ?? HttpTransport(),
        sdkVersion: sdkVersion,
        appVersion: appVersion,
        countryCode: _deviceCountry,
      ),
      storage: storage ?? SecureGemicoreStorage(),
      store: bridge,
      checkoutOpener: checkoutOpener ?? const InAppBrowserCheckoutOpener(),
      nativePaySheet: nativePaySheet,
      useTestStore: useTestStore,
      logLevel: logLevel,
      restoreQuietPeriod: restoreQuietPeriod,
      restoreTimeout: restoreTimeout,
      cacheMaxAge: cacheMaxAge,
      userTokenProvider: userTokenProvider,
      recordRetryDelay: recordRetryDelay,
    );
    if (appVersionProvider == null) {
      unawaited(
        _resolveVersion(_defaultAppVersion).then((version) => sdk._api.appVersion ??= version),
      );
    }
    // Listening starts before anything else so purchases interrupted in an earlier launch are recorded.
    sdk._purchaseSubscription = bridge.purchaseUpdates.listen(
      sdk._onPurchaseUpdates,
      onError: (Object error) => sdk._log(GemicoreLogLevel.error, 'Store stream error: $error'),
    );
    try {
      await sdk._start(appUserId);
    } catch (_) {
      // Nothing holds this instance, so without closing it the listener would outlive the failure
      // and record every store update a second time next to the instance of a retried configure.
      await sdk.close();
      rethrow;
    }
    sdk._started.complete(true);
    if (observeAppLifecycle) {
      WidgetsBinding.instance.addObserver(sdk);
      sdk._observingLifecycle = true;
    }
    _instance = sdk;
    return sdk;
  }

  static Future<String?> _resolveAppVersion(AppVersionProvider provider) =>
      // The limit only keeps a provider that never answers from holding configure.
      _resolveVersion(() => provider().timeout(const Duration(seconds: 3)));

  static Future<String?> _resolveVersion(AppVersionProvider provider) async {
    try {
      final version = await provider();
      return version == null ? null : _versionNumber.firstMatch(version.trim())?.group(0);
    } on Object {
      return null;
    }
  }

  static String? _deviceCountry() {
    PlatformDispatcher dispatcher;
    try {
      dispatcher = WidgetsBinding.instance.platformDispatcher;
    } on Object {
      dispatcher = PlatformDispatcher.instance;
    }
    return dispatcher.locale.countryCode;
  }

  final GemicoreApiClient _api;
  final GemicoreStorage _storage;
  final StoreBridge _store;
  final CheckoutOpener _checkoutOpener;
  final NativePaySheet? _nativePaySheet;
  final bool? _useTestStoreSetting;
  final GemicoreLogLevel _logLevel;
  final Duration _restoreQuietPeriod;
  final Duration _restoreTimeout;
  final Duration _cacheMaxAge;
  final UserTokenProvider? _userTokenProvider;
  final Duration _recordRetryDelay;

  /// Completes true when [configure] has the customer token, false if the SDK closed first. Store
  /// updates wait for it: one sent earlier would reach the server without the token.
  final _started = Completer<bool>();
  final Map<String, StorePurchaseUpdate> _unrecorded = {};
  Timer? _retryTimer;
  bool _retryingRecords = false;
  bool _closed = false;
  String? _customerSignature;
  Future<CustomerInfo>? _restoring;

  StreamSubscription<List<StorePurchaseUpdate>>? _purchaseSubscription;
  final _customerController = StreamController<CustomerInfo>.broadcast();
  final Map<String, Completer<PurchaseResult>> _pendingPurchases = {};
  List<StorePurchaseUpdate>? _restoreCollector;
  Timer? _restoreQuietTimer;
  Completer<void>? _restoreQuiet;
  bool _observingLifecycle = false;
  bool _storeAvailable = false;

  CustomerInfo? _customer;
  DateTime? _customerFetchedAt;
  // One entry per placement; the empty key is the call with no placement.
  final Map<String, _OfferingsEntry> _offeringsCache = {};

  /// Emits the customer info after every change the SDK sees: purchases, restores, log in and out,
  /// refreshes, and the refresh that runs when the app comes back to the foreground.
  Stream<CustomerInfo> get customerInfoStream => _customerController.stream;

  /// The last known customer info, without a network call. Null only before the first answer.
  CustomerInfo? get cachedCustomerInfo => _customer;

  String get _tokenKey => storageKey(_api.apiKey, 'customer_token');
  String get _cacheKey => storageKey(_api.apiKey, 'customer_info');
  // [key] is a _placementKey: empty for the call with no placement.
  String _offeringsKeyFor(String key) {
    final base = storageKey(_api.apiKey, 'offerings');
    return key.isEmpty ? base : '$base.placement.$key';
  }

  bool get _isTestKey => _api.apiKey.startsWith('pk_test_');

  Future<void> _start(String? appUserId) async {
    final cached = await _storage.read(_cacheKey);
    if (cached != null) {
      try {
        _customer = CustomerInfo.fromJson(asJsonMap(jsonDecode(cached)));
      } on FormatException {
        await _storage.delete(_cacheKey);
      }
    }
    final token = await _storage.read(_tokenKey);
    if (token == null) {
      await _createCustomer(appUserId);
      return;
    }
    _api.customerToken = token;
    if (appUserId != null && _customer?.externalId != appUserId) {
      await logIn(appUserId);
      return;
    }
    try {
      await getCustomerInfo(forceRefresh: true);
    } on GemicoreException catch (error) {
      if (error.code == GemicoreErrorCode.customerTokenInvalid) {
        // The customer was deleted on the server (or the app was reset); start a fresh anonymous one.
        await _createCustomer(appUserId);
      } else if (_customer == null && !error.isRetryable) {
        rethrow;
      } else {
        _log(GemicoreLogLevel.info, 'Starting offline from the cached customer: ${error.code}');
      }
    }
  }

  Future<void> _createCustomer(String? appUserId) async {
    final body = await _api.post(PurchaseRoute.createCustomer, {
      'externalId': ?appUserId,
    }, appUserId == null ? null : await _userToken());
    await _applySession(CustomerSession.fromJson(body));
  }

  Future<String?> _userToken() async {
    final provider = _userTokenProvider;
    if (provider == null) return null;
    try {
      return await provider();
    } on Object catch (error) {
      throw GemicoreException(
        GemicoreErrorCode.identityUnverified,
        'The user token for the app user could not be fetched: ${error.runtimeType}',
      );
    }
  }

  Future<void> _applySession(CustomerSession session) async {
    // The server resolves placements per customer, so a copy read for the old one must not outlive it.
    if (_customer?.id != session.customer.id) _offeringsCache.clear();
    _api.customerToken = session.token;
    await _storage.write(_tokenKey, session.token);
    await _setCustomer(session.customer);
  }

  Future<CustomerInfo> _setCustomer(CustomerInfo incoming) async {
    var customer = incoming;
    final known = _customer;
    if (customer.consumptionConsent == null &&
        known != null &&
        known.id == customer.id &&
        known.consumptionConsent != null) {
      // The customer routes do not return the refund review answer, so the one stored here is kept.
      customer = CustomerInfo.fromJson({
        ...customer.raw,
        'consumptionConsent': known.consumptionConsent!.toJson(),
      });
    }
    _customer = customer;
    _customerFetchedAt = DateTime.now();
    // The server stamps every answer, so the stamp is left out: polling an unchanged customer
    // must not rewrite the Keychain or wake every listener.
    final signature = jsonEncode({...customer.raw}..remove('requestedAt'));
    if (signature == _customerSignature) return customer;
    _customerSignature = signature;
    try {
      await _storage.write(_cacheKey, jsonEncode(customer.raw));
    } catch (error) {
      // The cache only serves an offline start; the server already has the data.
      _log(GemicoreLogLevel.info, 'Saving the customer failed: $error');
    }
    if (!_customerController.isClosed) _customerController.add(customer);
    return customer;
  }

  /// The customer's entitlements and purchases. Answers from the cache when it is younger than five
  /// minutes unless [forceRefresh] is set, and from an older cache when the network is down.
  Future<CustomerInfo> getCustomerInfo({bool forceRefresh = false}) async {
    final cached = _customer;
    final fetchedAt = _customerFetchedAt;
    if (!forceRefresh &&
        cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _cacheMaxAge) {
      return cached;
    }
    try {
      final body = await _api.get(PurchaseRoute.customer);
      return await _setCustomer(CustomerInfo.fromJson(body));
    } on GemicoreException catch (error) {
      if (cached != null && error.isRetryable) return cached;
      rethrow;
    }
  }

  /// Whether the customer currently has [entitlement], for example "pro".
  Future<bool> hasEntitlement(String entitlement) async =>
      (await getCustomerInfo()).hasEntitlement(entitlement);

  /// Links this device's customer to the app's own user id. Purchases made while anonymous move to
  /// that user. Call it after the app's own sign in.
  Future<CustomerInfo> logIn(String appUserId) async {
    if (appUserId.trim().isEmpty) {
      throw const GemicoreException(
        GemicoreErrorCode.invalidResponse,
        'appUserId must not be empty',
      );
    }
    final body = await _api.post(PurchaseRoute.login, {
      'externalId': appUserId,
    }, await _userToken());
    final session = CustomerSession.fromJson(body);
    await _applySession(session);
    // A new token may be what an unrecorded purchase was waiting for.
    unawaited(_retryUnrecorded());
    return session.customer;
  }

  /// Starts a new anonymous customer on this device, for the app's own sign out.
  Future<CustomerInfo> logOut() async {
    final body = await _api.post(PurchaseRoute.logout);
    final session = CustomerSession.fromJson(body);
    await _applySession(session);
    return session.customer;
  }

  bool _usesTestStore(bool storeAvailable) {
    if (!_isTestKey) return false;
    final setting = _useTestStoreSetting;
    if (setting != null) return setting;
    return !storeAvailable;
  }

  Future<bool> _isStoreAvailable() async => await _probeStore() ?? false;

  /// True or false as the store answers, null when asking failed. Only a yes is remembered: Play
  /// Billing can be unreachable at app start and fine a moment later.
  Future<bool?> _probeStore() async {
    if (_storeAvailable) return true;
    try {
      final available = await _store.isAvailable();
      if (available) _storeAvailable = true;
      return available;
    } catch (error) {
      _log(GemicoreLogLevel.info, 'Store unavailable: $error');
      return null;
    }
  }

  /// The products configured in the dashboard, with this device's store prices merged in.
  Future<List<GemicoreProduct>> getProducts() async {
    final body = await _api.get(PurchaseRoute.products);
    final views = (body['products'] is List ? body['products'] as List : const [])
        .map((p) => ProductView.fromJson(asJsonMap(p)))
        .toList(growable: false);
    final details = await _storeDetailsFor(views);
    return views.map((view) => _merge(view, details)).toList(growable: false);
  }

  Future<List<StoreProductDetails>> _storeDetailsFor(Iterable<ProductView> views) async {
    if (!await _isStoreAvailable()) return const [];
    final ids = {
      for (final view in views)
        if (view.storeProductId != null) view.storeProductId!,
    };
    try {
      return await _store.queryProducts(ids);
    } catch (error) {
      _log(GemicoreLogLevel.error, 'Store product query failed: $error');
      return const [];
    }
  }

  GemicoreProduct _merge(ProductView view, List<StoreProductDetails> details) {
    final candidates = details.where((d) => d.id == view.storeProductId).toList();
    // Play lists the base plan and each of its offers as separate entries; the plain base plan is
    // what a purchase buys unless the app asks for an offer.
    final plain = candidates.where((d) => d.offerId == null).toList();
    StoreProductDetails? match;
    if (view.googleBasePlanId != null) {
      for (final candidate in plain) {
        if (candidate.basePlanId == view.googleBasePlanId) match = candidate;
      }
    }
    match ??= plain.isNotEmpty ? plain.first : (candidates.isEmpty ? null : candidates.first);
    // Play lists only the offers this customer is eligible for, so finding the default offer here
    // is what makes it safe to buy; when it is missing the plain base plan is bought as before.
    StoreProductDetails? defaultOffer;
    final defaultOfferId = view.defaultGoogleOfferId;
    if (_store.platform == 'android' && defaultOfferId != null) {
      for (final candidate in candidates) {
        if (candidate.offerId == defaultOfferId &&
            (view.googleBasePlanId == null || candidate.basePlanId == view.googleBasePlanId)) {
          defaultOffer = candidate;
          break;
        }
      }
    }
    return GemicoreProduct(
      identifier: view.identifier,
      type: view.type,
      title: view.displayName.isNotEmpty ? view.displayName : (match?.title ?? view.identifier),
      description: view.description,
      storeProductId: view.storeProductId,
      googleBasePlanId: view.googleBasePlanId,
      defaultGoogleOfferId: view.defaultGoogleOfferId,
      entitlements: view.entitlements,
      card: view.card,
      // The regular price: an offer entry's first phase is usually the trial, priced "Free".
      priceString: match?.price,
      rawPrice: match?.rawPrice,
      currencyCode: match?.currencyCode,
      storeDetails: match,
      defaultOfferDetails: defaultOffer,
      storeVariants: candidates,
    );
  }

  /// The offerings configured in the dashboard, each with its packages priced by this device's store.
  /// Answers from memory for five minutes (unless [forceRefresh] is set), and from the copy kept on
  /// disk when the network is down, so a paywall can still show on an offline start.
  ///
  /// [placement] asks the server which offering that placement shows this customer (targeting rules
  /// and experiments are set in the dashboard); [Offerings.current] is then that offering and
  /// [Offerings.placement] says why. A placement the server does not know is answered like no
  /// placement. Each placement has its own memory and disk copy. Reading a placement that runs an
  /// experiment enrolls the customer on the server; there is nothing else to call.
  Future<Offerings> getOfferings({bool forceRefresh = false, String? placement}) async {
    final name = placement == null || placement.isEmpty ? null : placement;
    final key = _placementKey(name);
    final cached = _offeringsCache[key];
    final fetchedAt = cached?.fetchedAt;
    if (!forceRefresh &&
        cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _cacheMaxAge) {
      return cached.offerings;
    }
    final Map<String, Object?> body;
    try {
      body = await _fetchOfferings(name);
    } on GemicoreException catch (error) {
      if (!error.isRetryable) rethrow;
      if (cached != null) return cached.offerings;
      // Offline with no copy for this placement: the app's own offerings beat an error, since
      // targeting must never stand between a customer and the paywall.
      final persisted =
          await _readPersistedOfferings(key) ??
          (name == null ? null : await _readPersistedOfferings(_placementKey(null)));
      if (persisted == null) rethrow;
      _log(GemicoreLogLevel.info, 'Showing the offerings saved on this device: ${error.code}');
      // No fetch time, so the next call tries the network again.
      final offerings = await _buildOfferings(persisted);
      _offeringsCache[key] = _OfferingsEntry(offerings, null);
      return offerings;
    }
    final view = _parseOfferings(body);
    final built = await _buildOfferings(view);
    _offeringsCache[key] = _OfferingsEntry(built, DateTime.now());
    try {
      // The copy names its customer, so another customer never reads it as theirs.
      await _storage.write(
        _offeringsKeyFor(key),
        jsonEncode({...body, _offeringsOwner: _customer?.id}),
      );
    } catch (error) {
      _log(GemicoreLogLevel.info, 'Saving the offerings failed: $error');
    }
    return built;
  }

  // Targeting must never stand between a customer and the paywall, so a placement the server
  // refuses (a name it rejects) is dropped and the app's own offerings are read instead.
  Future<Map<String, Object?>> _fetchOfferings(String? placement) async {
    try {
      return await _api.get(
        PurchaseRoute.offerings,
        query: placement == null ? null : {'placement': placement},
      );
    } on GemicoreException catch (error) {
      final refused = const {400, 404, 422}.contains(error.statusCode);
      if (placement == null || !refused) rethrow;
      _log(GemicoreLogLevel.info, 'The server did not accept the placement: ${error.code}');
      return _api.get(PurchaseRoute.offerings);
    }
  }

  /// The current offering from the last [getOfferings] call without a placement, without a network
  /// call. Null until [getOfferings] has run, or when the dashboard has no current offering.
  Offering? get currentOffering => _offeringsCache[_placementKey(null)]?.offerings.current;

  OfferingsView _parseOfferings(Map<String, Object?> body) {
    try {
      return OfferingsView.fromJson(body);
    } on FormatException catch (error) {
      throw GemicoreException(
        GemicoreErrorCode.invalidResponse,
        'The offerings answer was not readable: ${error.message}',
      );
    }
  }

  Future<OfferingsView?> _readPersistedOfferings(String key) async {
    try {
      final saved = await _storage.read(_offeringsKeyFor(key));
      if (saved == null) return null;
      final json = asJsonMap(jsonDecode(saved));
      final owner = _customer?.id;
      if (owner == null || json[_offeringsOwner] != owner) return null;
      return OfferingsView.fromJson(json);
    } on Object {
      // A copy that no longer parses is worth nothing; the next successful fetch replaces it.
      return null;
    }
  }

  Future<Offerings> _buildOfferings(OfferingsView view) async {
    final details = await _storeDetailsFor([
      for (final offering in view.offerings)
        for (final package in offering.packages) package.product,
    ]);
    final all = <String, Offering>{
      for (final offering in view.offerings)
        offering.identifier: Offering(
          identifier: offering.identifier,
          displayName: offering.displayName,
          description: offering.description,
          metadata: offering.metadata,
          isCurrent: offering.isCurrent,
          paywall: offering.paywall,
          packages: [
            for (final package in offering.packages)
              Package(
                identifier: package.identifier,
                packageType: package.packageType,
                displayName: package.displayName,
                product: _merge(package.product, details),
              ),
          ],
        ),
    };
    final current = view.current;
    return Offerings(
      all: all,
      current: current == null ? null : all[current],
      placement: view.placement,
    );
  }

  /// Buys [product] through the App Store or Google Play and records it with Gemicore before the
  /// store transaction is finished, so a purchase is never lost if the app dies in between.
  /// A user who closes the sheet gets [PurchaseResult.cancelled], not an exception.
  ///
  /// [offer] applies a discount from [getEligibleOffers]. On the App Store a promotional offer is
  /// signed by Gemicore first and a win-back offer is checked by the store; on Google Play the base
  /// plan offer whose id the catalog names is bought. Offers do not apply in the test store, and an
  /// offer code is redeemed in the store itself, so passing one throws.
  ///
  /// [useServerIntroEligibility] makes Gemicore decide introductory offer eligibility from its own
  /// purchase records instead of Apple. It is off because Apple's own answer is authoritative on the
  /// device and Gemicore's records can be incomplete (purchases made before the SDK, for example).
  Future<PurchaseResult> purchase(
    GemicoreProduct product, {
    ProductOffer? offer,
    bool useServerIntroEligibility = false,
  }) async {
    final customer = _customer ?? await getCustomerInfo();
    final probe = await _probeStore();
    final available = probe ?? false;
    if (probe == null && _isTestKey && _useTestStoreSetting == null) {
      // A failed check says nothing about the store, so it must not send a real tap to the test store.
      throw GemicoreException(
        GemicoreErrorCode.productNotAvailable,
        'The store on this device could not be reached; try again',
      );
    }
    if (_usesTestStore(available)) return _purchaseInTestStore(product);
    final listed = product.storeDetails;
    if (!available || listed is! StoreProductDetails) {
      throw GemicoreException(
        GemicoreErrorCode.productNotAvailable,
        'The store on this device does not sell ${product.identifier}',
      );
    }
    final storeId = listed.id;
    if (_pendingPurchases.containsKey(storeId)) {
      throw GemicoreException(
        GemicoreErrorCode.purchaseInProgress,
        'A purchase of ${product.identifier} is already in progress',
      );
    }
    final completer = Completer<PurchaseResult>();
    _pendingPurchases[storeId] = completer;
    try {
      final selection = await _selectOffer(product, listed, offer, useServerIntroEligibility);
      await _store.buy(
        selection.details,
        consumable: product.type == ProductType.consumable,
        accountId: customer.id,
        offer: selection.offer,
      );
    } on GemicoreException {
      _pendingPurchases.remove(storeId);
      rethrow;
    } catch (error) {
      _pendingPurchases.remove(storeId);
      throw GemicoreException(
        GemicoreErrorCode.storeError,
        'The store refused the purchase: $error',
      );
    }
    return completer.future;
  }

  /// Buys the product of [package]; see [purchase] for [offer] and [useServerIntroEligibility].
  Future<PurchaseResult> purchasePackage(
    Package package, {
    ProductOffer? offer,
    bool useServerIntroEligibility = false,
  }) =>
      purchase(package.product, offer: offer, useServerIntroEligibility: useServerIntroEligibility);

  /// The discounts [product] has for this customer, already filtered by Gemicore from the customer's
  /// own purchase history and this device's platform. Pass one to [purchase] to apply it.
  Future<List<ProductOffer>> getEligibleOffers(GemicoreProduct product) async {
    final body = await _api.get(PurchaseRoute.offers, query: {'productId': product.identifier});
    return [
      for (final offer in body['offers'] is List ? body['offers'] as List : const [])
        ProductOffer.fromJson(asJsonMap(offer)),
    ];
  }

  GemicoreException _offerNotSupported(String message) =>
      GemicoreException(GemicoreErrorCode.offerNotSupported, message);

  Future<({StoreProductDetails details, StorePurchaseOffer? offer})> _selectOffer(
    GemicoreProduct product,
    StoreProductDetails details,
    ProductOffer? offer,
    bool useServerIntroEligibility,
  ) async {
    if (_store.platform == 'ios') {
      if (offer == null || offer.kind == OfferKind.intro) {
        if (!useServerIntroEligibility) return (details: details, offer: null);
        final body = await _api.post(PurchaseRoute.appleIntroEligibility, {
          'productId': product.identifier,
        });
        final eligibility = IntroEligibilityView.fromJson(body);
        return (
          details: details,
          offer: StorePurchaseOffer(introductoryEligibilityJws: eligibility.signature),
        );
      }
      switch (offer.kind) {
        case OfferKind.winBack:
          final id = offer.appleOfferIdentifier;
          if (id == null) {
            throw _offerNotSupported('The offer ${offer.identifier} has no App Store offer id');
          }
          return (details: details, offer: StorePurchaseOffer(winBackOfferId: id));
        case OfferKind.promotional:
          final body = await _api.post(PurchaseRoute.applePromotionalOffer, {
            'productId': product.identifier,
            'offerId': offer.identifier,
          });
          final signed = PromotionalOfferSignature.fromJson(body);
          final legacy = signed.legacy;
          if (legacy == null) {
            // The StoreKit plugin takes the key id, nonce, timestamp and signature, not the StoreKit 2 JWS.
            throw _offerNotSupported(
              'The server did not return the signature fields the StoreKit plugin needs',
            );
          }
          return (
            details: details,
            offer: StorePurchaseOffer(
              promotional: StorePromotionalOffer(
                offerId: signed.offerIdentifier,
                keyId: legacy.keyIdentifier,
                nonce: legacy.nonce,
                timestamp: legacy.timestamp,
                signature: legacy.signature,
              ),
            ),
          );
        case OfferKind.offerCode:
        case OfferKind.intro:
        case OfferKind.unknown:
          throw _offerNotSupported(
            'The offer ${offer.identifier} cannot be applied by purchase(); '
            'offer codes are redeemed in the App Store',
          );
      }
    }
    if (offer == null) {
      // No offer asked for: the product's default offer when Play lists it, else the base plan.
      final defaultOffer = product.defaultOfferDetails;
      return (details: defaultOffer is StoreProductDetails ? defaultOffer : details, offer: null);
    }
    final googleOfferId = offer.googleOfferId;
    if (googleOfferId == null || offer.kind == OfferKind.offerCode) {
      throw _offerNotSupported('The offer ${offer.identifier} has no Google Play offer to buy');
    }
    final variants = product.storeVariants.whereType<StoreProductDetails>().where(
      (d) =>
          d.offerId == googleOfferId &&
          (product.googleBasePlanId == null || d.basePlanId == product.googleBasePlanId),
    );
    if (variants.isEmpty) {
      throw GemicoreException(
        GemicoreErrorCode.productNotAvailable,
        'Google Play does not list the offer ${offer.identifier} on ${product.identifier} for this customer',
      );
    }
    return (details: variants.first, offer: null);
  }

  /// Stores whether the customer lets the app share usage data with Apple when a refund is asked for.
  /// Ask the customer in your own UI first; Gemicore only sends that data after a recorded "yes", and
  /// only when refund reviews are turned on in the dashboard. The answer is also kept in
  /// [CustomerInfo.consumptionConsent].
  Future<ConsumptionConsent> setConsumptionConsent(bool consented) async {
    final body = await _api.put(PurchaseRoute.consumptionConsent, {'consented': consented});
    final consent = ConsumptionConsent.fromJson(body);
    final customer = _customer;
    if (customer != null) {
      await _setCustomer(
        CustomerInfo.fromJson({...customer.raw, 'consumptionConsent': consent.toJson()}),
      );
    }
    return consent;
  }

  /// Saves attributes on this customer, which placements and experiments can target by. A null value
  /// deletes the key; keys not named stay as they are. Returns every attribute the server holds.
  ///
  /// Keys match `^[A-Za-z$][A-Za-z0-9_.$-]{0,39}$`, values are at most 256 characters, one call
  /// carries at most 50 keys, and a key starting with `$` must be one of `$email`, `$displayName`,
  /// `$phoneNumber`, `$pushToken`, `$campaign` and `$mediaSource`. Anything else throws
  /// [GemicoreErrorCode.invalidAttributes] before a request is made (the server also refuses a
  /// customer that would hold more than 50 keys in all). Values are customer data: the SDK never
  /// logs them and no error carries one.
  Future<Map<String, String>> setAttributes(Map<String, String?> attributes) async {
    _checkAttributes(attributes);
    final body = await _api.put(PurchaseRoute.customerAttributes, {'attributes': attributes});
    // A rule may match now, so what was resolved for the old attributes is dropped, in memory and on
    // the device (the device copy only serves an offline start).
    final keys = _offeringsCache.keys.toList();
    _offeringsCache.clear();
    for (final key in keys) {
      try {
        await _storage.delete(_offeringsKeyFor(key));
      } catch (error) {
        _log(GemicoreLogLevel.info, 'Dropping the saved offerings failed: $error');
      }
    }
    final stored = body['attributes'];
    return stored is Map
        ? {
            for (final entry in stored.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          }
        : const {};
  }

  /// Saves the customer's email as the `$email` attribute; null deletes it.
  Future<Map<String, String>> setEmail(String? email) => setAttributes({r'$email': email});

  /// Saves the customer's display name as `$displayName`; null deletes it.
  Future<Map<String, String>> setDisplayName(String? name) =>
      setAttributes({r'$displayName': name});

  /// Saves the customer's phone number as `$phoneNumber`; null deletes it.
  Future<Map<String, String>> setPhoneNumber(String? phoneNumber) =>
      setAttributes({r'$phoneNumber': phoneNumber});

  static final _attributeKey = RegExp(r'^[A-Za-z$][A-Za-z0-9_.$-]{0,39}$');
  static const _reservedAttributeKeys = {
    r'$email',
    r'$displayName',
    r'$phoneNumber',
    r'$pushToken',
    r'$campaign',
    r'$mediaSource',
  };

  // The limits of packages/contracts CUSTOMER_ATTRIBUTE_LIMITS, checked here so a mistake fails at
  // the call site. The message names a key only when it is a valid one, like the server, and never a value.
  void _checkAttributes(Map<String, String?> attributes) {
    GemicoreException refuse(String reason, String message, [String? key]) => GemicoreException(
      GemicoreErrorCode.invalidAttributes,
      message,
      details: {'reason': reason, 'field': key == null ? 'attributes' : 'attributes.$key'},
    );
    if (attributes.length > 50) {
      throw refuse('too_many', 'Attributes take at most 50 keys per call');
    }
    for (final entry in attributes.entries) {
      final key = entry.key;
      if (!_attributeKey.hasMatch(key)) {
        throw refuse(
          'key_invalid',
          'An attribute key must start with a letter or \$ and use at most 40 letters, digits, '
              'dot, dash, underscore or \$',
        );
      }
      if (key.startsWith(r'$') && !_reservedAttributeKeys.contains(key)) {
        throw refuse('key_reserved', 'The key $key is not a reserved attribute name', key);
      }
      final value = entry.value;
      if (value != null && value.length > 256) {
        throw refuse('value_invalid', 'The value of $key is longer than 256 characters', key);
      }
    }
  }

  /// The Customer Center the dashboard configured, with the store pages that manage this customer's
  /// subscriptions and the retention offers they are eligible for. [CustomerCenterView.enabled] is
  /// false until the dashboard switches it on. [presentCustomerCenter] and [GemicoreCustomerCenter]
  /// show it.
  Future<CustomerCenterView> getCustomerCenter() async {
    final body = await _api.get(PurchaseRoute.customerCenter);
    return CustomerCenterView.fromJson(body);
  }

  /// Records the answer to the cancel survey of the Customer Center. [reasonKey] is a configured
  /// option key, or `other` when the survey allows it. Throws on failure; the Customer Center
  /// itself ignores that, because a lost answer must never keep a customer from the store.
  Future<void> sendCancelFeedback({
    required String reasonKey,
    String? reasonText,
    String? purchaseId,
    String? offerShown,
    bool offerAccepted = false,
  }) async {
    await _api.post(PurchaseRoute.customerCenterFeedback, {
      'reasonKey': reasonKey,
      if (reasonText != null && reasonText.trim().isNotEmpty) 'reasonText': reasonText.trim(),
      'purchaseId': ?purchaseId,
      'offerShown': ?offerShown,
      'offerAccepted': offerAccepted,
    });
  }

  /// ios or android: the store this device sells through.
  String get platform => _store.platform;

  /// Opens [url] the way the SDK opens hosted pages: in an in-app browser unless a test or the app
  /// passed another opener to [configure].
  Future<bool> openUrl(Uri url) => _checkoutOpener.open(url);

  /// Opens [url] outside the app (the system browser, the store app, the mail app) when the opener
  /// can; store pages and mailto links need that, an in-app browser does not handle them.
  ///
  /// [opener] replaces the SDK's own for this call.
  Future<bool> openExternalUrl(Uri url, {CheckoutOpener? opener}) {
    final used = opener ?? _checkoutOpener;
    // CheckoutOpener and ExternalUrlOpener are unrelated interfaces, so the type test cannot promote.
    return used is ExternalUrlOpener
        ? (used as ExternalUrlOpener).openExternal(url)
        : used.open(url);
  }

  Future<PurchaseResult> _purchaseInTestStore(GemicoreProduct product) async {
    final body = await _api.post(PurchaseRoute.record, {
      'store': 'test_store',
      'productId': product.identifier,
    });
    return _recordedResult(body);
  }

  Future<PurchaseResult> _recordedResult(Map<String, Object?> body) async {
    final customer = await _setCustomer(CustomerInfo.fromJson(asJsonMap(body['customer'])));
    final purchase = body['purchase'] is Map
        ? PurchaseInfo.fromJson(asJsonMap(body['purchase']))
        : null;
    if (purchase != null && purchase.isPending) return PurchaseResult.pending(customer, purchase);
    return PurchaseResult.completed(customer, purchase);
  }

  Map<String, Object?> _recordBody(StorePurchaseUpdate update) => _store.platform == 'ios'
      ? {'store': 'app_store', 'signedTransaction': update.serverVerificationData}
      : {
          'store': 'play_store',
          'purchaseToken': update.serverVerificationData,
          'productId': update.productId,
        };

  Future<void> _onPurchaseUpdates(List<StorePurchaseUpdate> updates) async {
    // The store replays unfinished transactions as soon as the listener exists, before configure
    // has the customer token; they are held here instead of being sent without it.
    if (!await _started.future) return;
    for (final update in updates) {
      final collector = _restoreCollector;
      if (collector != null && update.state == StorePurchaseState.restored) {
        collector.add(update);
        _restoreQuietTimer?.cancel();
        _restoreQuietTimer = Timer(_restoreQuietPeriod, () {
          final quiet = _restoreQuiet;
          if (quiet != null && !quiet.isCompleted) quiet.complete();
        });
        continue;
      }
      await _handleUpdate(update);
    }
  }

  Future<void> _handleUpdate(StorePurchaseUpdate update) async {
    final completer = _pendingPurchases[update.productId];
    switch (update.state) {
      case StorePurchaseState.pending:
        _pendingPurchases.remove(update.productId);
        completer?.complete(PurchaseResult.pending(_customer, null));
      case StorePurchaseState.canceled:
        _pendingPurchases.remove(update.productId);
        await _completeQuietly(update);
        completer?.complete(PurchaseResult.cancelled(_customer));
      case StorePurchaseState.error:
        _pendingPurchases.remove(update.productId);
        await _completeQuietly(update);
        completer?.completeError(
          GemicoreException(
            GemicoreErrorCode.storeError,
            update.errorMessage ?? 'The store reported an error',
          ),
        );
      case StorePurchaseState.purchased:
      case StorePurchaseState.restored:
        try {
          final result = await _recordUpdate(update);
          _unrecorded.remove(update.serverVerificationData);
          _pendingPurchases.remove(update.productId);
          completer?.complete(result);
        } catch (error) {
          _pendingPurchases.remove(update.productId);
          _log(
            GemicoreLogLevel.error,
            'Recording a purchase failed; it is tried again and the store delivers it next launch: $error',
          );
          if (error is GemicoreException && error.isRetryable && !_closed) {
            _unrecorded[update.serverVerificationData] = update;
            _scheduleRecordRetry();
          }
          if (completer != null && !completer.isCompleted) {
            completer.completeError(
              error is GemicoreException
                  ? error
                  : GemicoreException(
                      GemicoreErrorCode.storeError,
                      'Recording the purchase failed: $error',
                    ),
            );
          }
        }
    }
  }

  Future<PurchaseResult> _recordUpdate(StorePurchaseUpdate update) async {
    final body = await _api.post(PurchaseRoute.record, _recordBody(update));
    // Finished only after the server has it: an unfinished transaction is delivered again next launch.
    await _store.complete(update);
    return _recordedResult(body);
  }

  void _scheduleRecordRetry() {
    if (_retryTimer != null || _closed || _unrecorded.isEmpty) return;
    _retryTimer = Timer(_recordRetryDelay, () {
      _retryTimer = null;
      unawaited(_retryUnrecorded());
    });
  }

  /// Sends again the store updates the server could not take (offline, 5xx). Runs on a timer, when
  /// the app resumes and after a log in, so a paid purchase does not wait for the next launch.
  Future<void> _retryUnrecorded() async {
    if (_retryingRecords || _closed || _unrecorded.isEmpty || !_started.isCompleted) return;
    _retryingRecords = true;
    try {
      for (final entry in _unrecorded.entries.toList()) {
        if (_closed) return;
        try {
          await _recordUpdate(entry.value);
          _unrecorded.remove(entry.key);
        } on GemicoreException catch (error) {
          if (error.isRetryable) break;
          _unrecorded.remove(entry.key);
          _log(GemicoreLogLevel.error, 'A purchase could not be recorded: ${error.code}');
        } catch (error) {
          _unrecorded.remove(entry.key);
          _log(GemicoreLogLevel.error, 'A purchase could not be recorded: $error');
        }
      }
    } finally {
      _retryingRecords = false;
      _scheduleRecordRetry();
    }
  }

  Future<void> _completeQuietly(StorePurchaseUpdate update) async {
    if (!update.needsCompletion) return;
    try {
      await _store.complete(update);
    } catch (error) {
      _log(GemicoreLogLevel.info, 'Finishing a failed transaction failed: $error');
    }
  }

  /// Asks the store for everything this store account bought and attaches it to the current customer.
  /// Apps must offer this behind a Restore button (App Store Review Guideline 3.1.1).
  ///
  /// A second call while one runs gets the same answer instead of starting another.
  Future<CustomerInfo> restorePurchases() =>
      _restoring ??= _restorePurchases().whenComplete(() => _restoring = null);

  Future<CustomerInfo> _restorePurchases() async {
    final customer = _customer ?? await getCustomerInfo();
    if (!await _isStoreAvailable()) return getCustomerInfo(forceRefresh: true);
    final collected = <StorePurchaseUpdate>[];
    _restoreCollector = collected;
    _restoreQuiet = Completer<void>();
    try {
      await _store.restore(accountId: customer.id);
      // The store reports restored items as a stream with no end marker, so the SDK waits for a pause.
      _restoreQuietTimer = Timer(_restoreQuietPeriod, () {
        final quiet = _restoreQuiet;
        if (quiet != null && !quiet.isCompleted) quiet.complete();
      });
      await _restoreQuiet!.future.timeout(_restoreTimeout, onTimeout: () {});
    } finally {
      _restoreQuietTimer?.cancel();
      _restoreCollector = null;
      _restoreQuiet = null;
    }
    if (collected.isEmpty) return getCustomerInfo(forceRefresh: true);
    final body = _store.platform == 'ios'
        ? {
            'appStore': {
              'signedTransactions': collected.map((u) => u.serverVerificationData).toList(),
            },
          }
        : {
            'playStore': {
              'purchases': collected
                  .map((u) => {'purchaseToken': u.serverVerificationData, 'productId': u.productId})
                  .toList(),
            },
          };
    final response = await _api.post(PurchaseRoute.restore, body);
    for (final update in collected) {
      await _completeQuietly(update);
    }
    return _setCustomer(CustomerInfo.fromJson(asJsonMap(response['customer'])));
  }

  /// Pays for a one-time [product] by card, Apple Pay or Google Pay on the app gateway's hosted page,
  /// opened in an in-app browser. Only for physical goods and real-world services: App Store Review
  /// Guideline 3.1.1 and the Google Play payments policy require digital goods to go through
  /// [purchase]. [email] receives the receipt.
  ///
  /// The page is polled until the payment settles. When [timeout] passes first the result is
  /// [PurchaseResult.pending]: the payment can still complete, and [customerInfoStream] will show it.
  /// Complete [cancel] (for example when the buyer closes the browser) to stop waiting at once; the
  /// result is then [PurchaseResult.cancelled], although a payment already made still lands.
  /// A payment that failed, expired or was refunded throws a [GemicoreErrorCode.paymentFailed] error.
  Future<PurchaseResult> payWithCard(
    GemicoreProduct product, {
    required String email,
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 3),
    Future<void>? cancel,
  }) async {
    if (product.card == null) {
      throw GemicoreException(
        GemicoreErrorCode.notForCard,
        '${product.identifier} has no card price; set one in the dashboard or use purchase()',
      );
    }
    final body = await _api.post(PurchaseRoute.checkout, {
      'productId': product.identifier,
      'email': email,
    });
    final start = CheckoutStart.fromJson(body);
    final opened = await _checkoutOpener.open(Uri.parse(start.url));
    if (!opened) {
      throw const GemicoreException(
        GemicoreErrorCode.storeError,
        'Could not open the checkout page',
      );
    }
    return _awaitCardPurchase(
      start.purchase,
      timeout: timeout,
      pollInterval: pollInterval,
      cancel: cancel,
    );
  }

  /// Polls the customer until the card purchase leaves pending. The payment settles on the server
  /// through the gateway's webhook, so the device only watches for it.
  Future<PurchaseResult> _awaitCardPurchase(
    PurchaseInfo started, {
    required Duration timeout,
    required Duration pollInterval,
    Future<void>? cancel,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var cancelled = false;
    final cancelSignal = cancel?.then<void>(
      (_) => cancelled = true,
      onError: (Object _) => cancelled = true,
    );
    while (!cancelled && DateTime.now().isBefore(deadline)) {
      await Future.any<void>([Future<void>.delayed(pollInterval), ?cancelSignal]);
      if (cancelled) break;
      final CustomerInfo customer;
      try {
        customer = await getCustomerInfo(forceRefresh: true);
      } on GemicoreException catch (error) {
        if (error.isRetryable) continue;
        rethrow;
      }
      final purchase = customer.purchaseById(started.id);
      if (purchase == null || purchase.isPending) continue;
      if (purchase.isActive) return PurchaseResult.completed(customer, purchase);
      throw GemicoreException(
        GemicoreErrorCode.paymentFailed,
        'The payment did not go through (${purchase.status})',
      );
    }
    if (cancelled) return PurchaseResult.cancelled(_customer);
    return PurchaseResult.pending(_customer, started);
  }

  /// Pays for a one-time [product] with the Apple Pay or Google Pay sheet inside the app, through the
  /// [NativePaySheet] passed to [configure] (the gemicore_flutter_stripe package provides one). Same
  /// rules as [payWithCard]: only for physical goods and real-world services, and the price is the
  /// catalog's card price. [email] receives the receipt.
  ///
  /// A closed sheet is [PurchaseResult.cancelled]. After the sheet reports success the customer is
  /// polled until the payment settles; when [timeout] passes first the result is
  /// [PurchaseResult.pending] and [customerInfoStream] shows the payment when it lands. [cancel] and
  /// failed payments behave as in [payWithCard].
  Future<PurchaseResult> payWithSheet(
    GemicoreProduct product, {
    required String email,
    Duration timeout = const Duration(minutes: 2),
    Duration pollInterval = const Duration(seconds: 2),
    Future<void>? cancel,
  }) async {
    final sheet = _nativePaySheet;
    if (sheet == null) {
      throw const GemicoreException(
        GemicoreErrorCode.nativePayNotConfigured,
        'No payment sheet is set up. Add the gemicore_flutter_stripe package and pass its sheet as '
        'nativePaySheet to Gemicore.configure, or use payWithCard for the hosted checkout.',
      );
    }
    final card = product.card;
    if (card == null) {
      throw GemicoreException(
        GemicoreErrorCode.notForCard,
        '${product.identifier} has no card price; set one in the dashboard or use purchase()',
      );
    }
    final body = await _api.post(PurchaseRoute.checkoutIntent, {
      'productId': product.identifier,
      'email': email,
    });
    final intent = CardIntentView.fromJson(body);
    final NativePayResult result;
    try {
      result = await sheet.present(
        NativePayRequest(
          clientSecret: intent.clientSecret,
          publishableKey: intent.publishableKey,
          merchantCountryCode: intent.merchantCountryCode,
          applePayMerchantId: intent.applePayMerchantId,
          // The server's price for the pending purchase; the sheet only shows it, the charge is the intent's.
          currencyCode: intent.purchase.priceCurrency ?? card.currency,
          amount: intent.purchase.priceAmount ?? card.amount,
          productName: product.title,
          merchantDisplayName: intent.merchantDisplayName,
          testEnvironment: _isTestKey,
        ),
      );
    } on GemicoreException {
      rethrow;
    } catch (error) {
      throw GemicoreException(
        GemicoreErrorCode.nativePayFailed,
        'The payment sheet failed: ${error.runtimeType}',
      );
    }
    switch (result.outcome) {
      case NativePayOutcome.canceled:
        return PurchaseResult.cancelled(_customer);
      case NativePayOutcome.failed:
        throw GemicoreException(
          GemicoreErrorCode.nativePayFailed,
          result.message ?? 'The payment sheet reported a failure',
        );
      case NativePayOutcome.completed:
        return _awaitCardPurchase(
          intent.purchase,
          timeout: timeout,
          pollInterval: pollInterval,
          cancel: cancel,
        );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_retryUnrecorded());
    // Renewals, refunds and purchases made on another device show up without the app asking.
    unawaited(
      getCustomerInfo(forceRefresh: true).then<void>(
        (_) {},
        onError: (Object error) => _log(GemicoreLogLevel.info, 'Refresh on resume failed: $error'),
      ),
    );
  }

  /// Stops listening to the store and the app lifecycle. A later [configure] calls this itself.
  Future<void> close() async {
    _closed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_started.isCompleted) _started.complete(false);
    await _purchaseSubscription?.cancel();
    _purchaseSubscription = null;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    for (final completer in _pendingPurchases.values) {
      if (!completer.isCompleted) completer.complete(PurchaseResult.cancelled(_customer));
    }
    _pendingPurchases.clear();
    await _customerController.close();
    if (identical(_instance, this)) _instance = null;
  }

  void _log(GemicoreLogLevel level, String message) {
    if (_logLevel == GemicoreLogLevel.none || level.index > _logLevel.index) return;
    debugPrint('[Gemicore] $message');
  }
}
