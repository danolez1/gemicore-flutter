import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

/// A placement answer whose chosen offering is a copy of the default one with a different name.
Map<String, Object?> spring() {
  final base = offeringsJson();
  final first = ((base['offerings'] as List).first as Map).cast<String, Object?>();
  final config = samplePaywallConfig();
  final strings = (config['strings'] as Map).cast<String, Object?>();
  final en = {...(strings['en'] as Map).cast<String, Object?>(), 'title': 'Spring sale'};
  final paywall = {
    'offeringIdentifier': 'spring',
    'revision': 1,
    'config': {
      ...config,
      'strings': {...strings, 'en': en},
    },
  };
  return {
    'current': 'spring',
    'offerings': [
      {...first, 'isCurrent': false},
      {...first, 'identifier': 'spring', 'isCurrent': true, 'paywall': paywall},
    ],
    'placement': {
      'identifier': 'onboarding',
      'source': 'experiment',
      'experiment': {'identifier': 'price_test', 'variant': 'b'},
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness();
    h.transport.on('GET', '/v1/purchases/offerings', (request) {
      final placement = request.url.queryParameters['placement'];
      return TransportResponse(
        200,
        jsonEncode(placement == 'onboarding' ? spring() : offeringsJson()),
      );
    });
    h.store.catalog.addAll([
      storeDetail('com.example.pro.monthly', period: monthly),
      storeDetail('com.example.pro.annual', price: '\$39.99', rawPrice: 39.99, period: annual),
    ]);
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Widget app(Future<Object?> Function(BuildContext) onTap) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(onPressed: () => onTap(context), child: const Text('open')),
      ),
    ),
  );

  testWidgets('presentPaywall(placement:) shows the paywall the placement resolves to', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sdk = await h.configure();
    await tester.pumpWidget(
      app(
        (context) =>
            presentPaywall(context, placement: 'onboarding', sdk: sdk, locale: const Locale('en')),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Spring sale'), findsOneWidget);
    expect(find.text('Go Pro'), findsNothing);
    final request = h.transport.calls('GET', '/v1/purchases/offerings').single;
    expect(request.url.queryParameters, {'placement': 'onboarding'});
  });

  testWidgets('without a placement it shows the current offering as before', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sdk = await h.configure();
    await tester.pumpWidget(
      app((context) => presentPaywall(context, sdk: sdk, locale: const Locale('en'))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Go Pro'), findsOneWidget);
    expect(h.transport.calls('GET', '/v1/purchases/offerings').single.url.hasQuery, isFalse);
  });

  testWidgets('an unknown placement falls back to the current offering silently', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sdk = await h.configure();
    await tester.pumpWidget(
      app(
        (context) => presentPaywall(
          context,
          placement: 'nobody_knows',
          sdk: sdk,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Go Pro'), findsOneWidget);
  });

  testWidgets('an explicit offering wins and no offerings call is made for it', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sdk = await h.configure();
    final explicit = (await sdk.getOfferings()).current!;
    h.transport.requests.clear();
    await tester.pumpWidget(
      app(
        (context) => presentPaywall(
          context,
          placement: 'onboarding',
          offering: explicit,
          sdk: sdk,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Go Pro'), findsOneWidget);
    expect(h.transport.calls('GET', '/v1/purchases/offerings'), isEmpty);
  });
}
