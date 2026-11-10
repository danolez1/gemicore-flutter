import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness();
    h.transport.json('GET', '/v1/purchases/offerings', offeringsJson());
  });

  tearDown(() async {
    binding.platformDispatcher.clearLocaleTestValue();
    binding.platformDispatcher.clearLocalesTestValue();
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  test('every request carries the app version, the country and the platform', () async {
    binding.platformDispatcher.localeTestValue = const Locale('en', 'us');
    final sdk = await h.configure(appVersionProvider: () async => '2.3.4');
    await sdk.getOfferings();
    expect(h.transport.requests.length, greaterThanOrEqualTo(2));
    for (final request in h.transport.requests) {
      expect(request.headers['x-gemicore-app-version'], '2.3.4', reason: request.url.path);
      expect(request.headers['x-gemicore-country'], 'US', reason: request.url.path);
      expect(request.headers['x-gemicore-platform'], 'ios', reason: request.url.path);
    }
  });

  test('a version provider that fails leaves the header out and configure still works', () async {
    binding.platformDispatcher.localeTestValue = const Locale('de', 'DE');
    final sdk = await h.configure(appVersionProvider: () async => throw StateError('no channel'));
    await sdk.getOfferings();
    for (final request in h.transport.requests) {
      expect(request.headers.containsKey('x-gemicore-app-version'), isFalse);
      expect(request.headers['x-gemicore-country'], 'DE');
    }
  });

  test('without the plugin (no platform channel) the header is left out', () async {
    final sdk = await Gemicore.configure(
      apiKey: liveKey,
      baseUrl: 'https://api.test',
      transport: h.transport,
      storage: h.storage,
      store: h.store,
      observeAppLifecycle: false,
      logLevel: GemicoreLogLevel.none,
    );
    await sdk.getOfferings();
    expect(
      h.transport.requests.every((r) => !r.headers.containsKey('x-gemicore-app-version')),
      isTrue,
    );
  });

  test(
    'a version with a suffix sends its numeric part, one that is no version sends nothing',
    () async {
      var sdk = await h.configure(appVersionProvider: () async => '1.4.2-beta.3');
      await sdk.getOfferings();
      expect(h.transport.requests.last.headers['x-gemicore-app-version'], '1.4.2');
      h.transport.requests.clear();
      sdk = await h.configure(appVersionProvider: () async => 'nightly');
      await sdk.getOfferings(forceRefresh: true);
      expect(h.transport.requests.last.headers.containsKey('x-gemicore-app-version'), isFalse);
    },
  );

  test(
    'a locale with no country omits the header, and the country follows a language change',
    () async {
      binding.platformDispatcher.localeTestValue = const Locale('fr');
      final sdk = await h.configure();
      await sdk.getOfferings();
      expect(h.transport.requests.last.headers.containsKey('x-gemicore-country'), isFalse);
      binding.platformDispatcher.localeTestValue = const Locale('pt', 'br');
      await sdk.getOfferings(forceRefresh: true);
      expect(h.transport.requests.last.headers['x-gemicore-country'], 'BR');
      // A region that is not a two letter country (es-419) is not sent.
      binding.platformDispatcher.localeTestValue = const Locale('es', '419');
      await sdk.getOfferings(forceRefresh: true);
      expect(h.transport.requests.last.headers.containsKey('x-gemicore-country'), isFalse);
    },
  );

  test('the key stays the only required setting', () async {
    final sdk = await Gemicore.configure(
      apiKey: liveKey,
      baseUrl: 'https://api.test',
      transport: h.transport,
      storage: h.storage,
      store: h.store,
      observeAppLifecycle: false,
    );
    expect(sdk, isNotNull);
    expect(h.transport.requests.first.headers['x-gemicore-sdk'], 'flutter/0.3.0');
  });
}
