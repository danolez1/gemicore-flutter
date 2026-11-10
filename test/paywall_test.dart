import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

class Setup {
  Setup(this.h, this.sdk, this.offering);

  final Harness h;
  final Gemicore sdk;
  final Offering offering;
}

Future<Setup> setup({
  Object? paywallConfig = const SamplePaywall(),
  bool trialOnMonthly = true,
}) async {
  final h = Harness();
  h.transport.json('GET', '/v1/purchases/offerings', offeringsJson(paywallConfig: paywallConfig));
  h.store.catalog.addAll([
    storeDetail(
      'com.example.pro.monthly',
      period: monthly,
      trial: trialOnMonthly ? const SubscriptionPeriod(7, PeriodUnit.day) : null,
    ),
    storeDetail('com.example.pro.annual', price: '\$39.99', rawPrice: 39.99, period: annual),
  ]);
  final sdk = await h.configure();
  return Setup(h, sdk, (await sdk.getOfferings()).current!);
}

Widget host(Widget child, {TextDirection direction = TextDirection.ltr, double textScale = 1}) =>
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      ),
    );

Map<String, Object?> configWithChildren(List<Object?> children) => {
  ...samplePaywallConfig(),
  'root': {
    'type': 'stack',
    'direction': 'column',
    'spacing': 8,
    'padding': 16,
    'align': 'stretch',
    'children': children,
  },
};

// The sample paywall is taller than the default 800x600 test screen, and a tap off screen misses.
void useView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Future<void> pumpPaywall(
    WidgetTester tester,
    Setup s, {
    PaywallConfig? config,
    Locale? locale = const Locale('en'),
    ValueChanged<PurchaseResult>? onPurchase,
    ValueChanged<CustomerInfo>? onRestore,
    ValueChanged<GemicoreException>? onError,
    TextDirection direction = TextDirection.ltr,
    double textScale = 1,
    CheckoutOpener? urlOpener,
    Size size = const Size(600, 2400),
  }) {
    useView(tester, size);
    return tester.pumpWidget(
      host(
        GemicorePaywall(
          offering: s.offering,
          config: config,
          sdk: s.sdk,
          locale: locale,
          onPurchase: onPurchase,
          onRestore: onRestore,
          onError: onError,
          urlOpener: urlOpener,
        ),
        direction: direction,
        textScale: textScale,
      ),
    );
  }

  testWidgets('renders every node type of the sample paywall', (tester) async {
    final s = await setup();
    await pumpPaywall(tester, s);
    // text
    expect(find.text('Go Pro'), findsOneWidget);
    expect(find.text('Unlock everything. Cancel any time.'), findsOneWidget);
    // package_list: the monthly package has no display name, so it shows the product title
    expect(find.text('Pro monthly'), findsOneWidget);
    expect(find.text('Pro annual'), findsOneWidget);
    expect(find.text('\$4.99'), findsOneWidget);
    expect(find.text('\$39.99'), findsOneWidget);
    // purchase_button, restore_button
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore purchases'), findsOneWidget);
    // image
    expect(find.byType(Image), findsOneWidget);
    // divider, spacer (an 8 high box inside the stack)
    expect(find.byType(Divider), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 8 && w.width == 0),
      findsOneWidget,
    );
    // legal_links
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row stack lays its children out side by side', (tester) async {
    final s = await setup(
      paywallConfig: configWithChildren([
        {
          'type': 'stack',
          'direction': 'row',
          'spacing': 8,
          'padding': 0,
          'align': 'center',
          'children': [
            {'type': 'text', 'stringKey': 'title', 'style': 'title', 'align': 'start'},
            {'type': 'spacer', 'size': 24},
            {'type': 'divider'},
            {'type': 'text', 'stringKey': 'subtitle', 'style': 'body', 'align': 'start'},
          ],
        },
      ]),
    );
    await pumpPaywall(tester, s);
    final title = tester.getTopLeft(find.text('Go Pro'));
    final subtitle = tester.getTopLeft(find.text('Unlock everything. Cancel any time.'));
    expect(subtitle.dx, greaterThan(title.dx));
    final centers = (
      tester.getCenter(find.text('Go Pro')).dy,
      tester.getCenter(find.text('Unlock everything. Cancel any time.')).dy,
    );
    expect((centers.$1 - centers.$2).abs(), lessThan(2), reason: 'a row centers its children');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a horizontal package list shows every package', (tester) async {
    final s = await setup(
      paywallConfig: configWithChildren([
        {'type': 'package_list', 'layout': 'horizontal', 'selected': null},
      ]),
    );
    await pumpPaywall(tester, s);
    expect(find.text('Pro monthly'), findsOneWidget);
    expect(find.text('Pro annual'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme colors, corner radius and font scale are applied', (tester) async {
    final config = samplePaywallConfig();
    config['theme'] = {
      'background': '#202020',
      'foreground': '#f0f0f0',
      'accent': '#ff8800',
      'accentForeground': '#000000',
      'cornerRadius': 30,
      'fontScale': 1.5,
    };
    final s = await setup(paywallConfig: config);
    await pumpPaywall(tester, s);
    final title = tester.widget<Text>(find.text('Go Pro'));
    expect(title.style!.color, const Color(0xFFF0F0F0));
    expect(title.style!.fontSize, 28 * 1.5);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final style = button.style!;
    expect(style.backgroundColor!.resolve({}), const Color(0xFFFF8800));
    expect(style.foregroundColor!.resolve({}), const Color(0xFF000000));
    expect(
      (style.shape!.resolve({}) as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(30),
    );
    final material = tester.widget<Material>(
      find.descendant(of: find.byType(GemicorePaywall), matching: find.byType(Material)).first,
    );
    expect(material.color, const Color(0xFF202020));
  });

  group('variables come from the selected package', () {
    testWidgets('the first package is selected at first', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      expect(find.text('\$4.99 per month'), findsOneWidget);
      expect(find.text('Start with 7 days free'), findsOneWidget);
      expect(find.text('Only \$4.99 a month'), findsOneWidget);
    });

    testWidgets('choosing another package rewrites the lines and drops the trial it lacks', (
      tester,
    ) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      await tester.tap(find.text('Pro annual'));
      await tester.pump();
      expect(find.text('\$39.99 per year'), findsOneWidget);
      expect(find.text('Only \$3.33 a month'), findsOneWidget);
      expect(find.textContaining('Start with'), findsNothing);
      expect(find.textContaining('per month'), findsNothing);
    });

    testWidgets('a line whose variable the store cannot supply is left out, the rest stays', (
      tester,
    ) async {
      final s = await setup(trialOnMonthly: false);
      await pumpPaywall(tester, s);
      expect(find.textContaining('Start with'), findsNothing);
      expect(find.text('\$4.99 per month'), findsOneWidget);
    });

    testWidgets('with no store prices the price lines vanish and the layout survives', (
      tester,
    ) async {
      final h = Harness();
      h.store.available = false;
      h.transport.json('GET', '/v1/purchases/offerings', offeringsJson());
      final sdk = await h.configure(apiKey: testKey);
      final s = Setup(h, sdk, (await sdk.getOfferings()).current!);
      await pumpPaywall(tester, s);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.textContaining('per month'), findsNothing);
      expect(find.text('Pro monthly'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the config can start with another package selected', (tester) async {
      final config = configWithChildren([
        {'type': 'package_list', 'layout': 'vertical', 'selected': r'$rc_annual'},
        {'type': 'text', 'stringKey': 'price_line', 'style': 'body', 'align': 'start'},
      ]);
      final s = await setup(paywallConfig: config);
      await pumpPaywall(tester, s);
      expect(find.text('\$39.99 per year'), findsOneWidget);
    });

    testWidgets('a selection naming a package the offering lacks falls back to the first', (
      tester,
    ) async {
      final config = configWithChildren([
        {'type': 'package_list', 'layout': 'vertical', 'selected': 'ghost'},
        {'type': 'text', 'stringKey': 'price_line', 'style': 'body', 'align': 'start'},
      ]);
      final s = await setup(paywallConfig: config);
      await pumpPaywall(tester, s);
      expect(find.text('\$4.99 per month'), findsOneWidget);
    });
  });

  group('strings follow the device locale', () {
    testWidgets('a matching language uses its table, with its own period words', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, locale: const Locale('de'));
      expect(find.text('Pro werden'), findsOneWidget);
      expect(find.text('\$4.99 pro Monat'), findsOneWidget);
      expect(find.text('7 Tage kostenlos testen'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Weiter'), findsOneWidget);
      expect(find.text('Nutzungsbedingungen'), findsOneWidget);
    });

    testWidgets('a region of a known language matches the language', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, locale: const Locale('de', 'AT'));
      expect(find.text('Pro werden'), findsOneWidget);
    });

    testWidgets('an unknown language falls back to the default locale', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, locale: const Locale('ja'));
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    });

    testWidgets('a key missing from the language table comes from the default table', (
      tester,
    ) async {
      final config = samplePaywallConfig();
      (config['strings']! as Map)['de'] = {'title': 'Pro werden'};
      final s = await setup(paywallConfig: config);
      await pumpPaywall(tester, s, locale: const Locale('de'));
      expect(find.text('Pro werden'), findsOneWidget);
      expect(find.text('Unlock everything. Cancel any time.'), findsOneWidget);
    });

    testWidgets('a key no table has renders nothing for that node', (tester) async {
      final s = await setup(
        paywallConfig: configWithChildren([
          {'type': 'text', 'stringKey': 'nowhere', 'style': 'body', 'align': 'start'},
          {'type': 'text', 'stringKey': 'title', 'style': 'title', 'align': 'start'},
        ]),
      );
      await pumpPaywall(tester, s);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.text('nowhere'), findsNothing);
    });

    testWidgets('with no locale given the device locales decide, in their order', (tester) async {
      final s = await setup();
      tester.platformDispatcher.localesTestValue = const [Locale('xx'), Locale('de', 'DE')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pumpPaywall(tester, s, locale: null);
      expect(find.text('Pro werden'), findsOneWidget);
    });

    testWidgets('a locale change on the device updates the strings', (tester) async {
      final s = await setup();
      tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pumpPaywall(tester, s, locale: null);
      expect(find.text('Go Pro'), findsOneWidget);
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
      await tester.pump();
      expect(find.text('Pro werden'), findsOneWidget);
    });

    testWidgets('the paywall strings may define the legal link labels', (tester) async {
      final config = samplePaywallConfig();
      final strings = config['strings']! as Map<String, Map<String, String>>;
      strings['en'] = {...strings['en']!, 'terms': 'Terms', 'privacy': 'Privacy'};
      final s = await setup(paywallConfig: config);
      await pumpPaywall(tester, s);
      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
    });
  });

  group('selection and wiring', () {
    testWidgets('tapping a package selects it, and the purchase buys that package', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      await tester.tap(find.text('Pro annual'));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(s.h.store.buys.single.productId, 'com.example.pro.annual');
      expect(s.h.store.buys.single.accountId, customerId);
    });

    testWidgets('the selected card is exposed as selected to accessibility', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await setup();
      await pumpPaywall(tester, s);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Pro monthly, ')).first),
        isSemantics(isSelected: true, isButton: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Pro annual, ')).first),
        isSemantics(isSelected: false, isButton: true),
      );
      await tester.tap(find.text('Pro annual'));
      await tester.pump();
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Pro annual, ')).first),
        isSemantics(isSelected: true),
      );
      handle.dispose();
    });

    testWidgets('purchase reports a completed result and shows progress meanwhile', (tester) async {
      final s = await setup();
      s.h.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(),
      });
      final results = <PurchaseResult>[];
      await pumpPaywall(tester, s, onPurchase: results.add);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'jws',
          needsCompletion: true,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(results.single.isCompleted, isTrue);
      expect(results.single.customerInfo!.hasEntitlement('pro'), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    });

    testWidgets('a closed store sheet is reported as cancelled and the paywall stays usable', (
      tester,
    ) async {
      final s = await setup();
      final results = <PurchaseResult>[];
      await pumpPaywall(tester, s, onPurchase: results.add);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.canceled,
          serverVerificationData: '',
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(results.single.isCancelled, isTrue);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    });

    testWidgets('a purchase error goes to onError, never out of the widget', (tester) async {
      final s = await setup();
      s.h.transport.json('POST', '/v1/purchases', {
        'error': {'code': 'PURCHASE_VERIFICATION_FAILED', 'message': 'bad'},
      }, status: 422);
      final errors = <GemicoreException>[];
      await pumpPaywall(tester, s, onError: errors.add);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'bad',
          needsCompletion: true,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(errors.single.code, GemicoreErrorCode.verificationFailed);
      expect(tester.takeException(), isNull);
    });

    testWidgets('restore calls the SDK and reports the customer', (tester) async {
      final s = await setup();
      s.h.store.restoreEmits = const [
        StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-a',
          needsCompletion: true,
        ),
      ];
      s.h.transport.json('POST', '/v1/purchases/restore', {'customer': customerJson(pro: true)});
      final restored = <CustomerInfo>[];
      await pumpPaywall(tester, s, onRestore: restored.add);
      await tester.tap(find.text('Restore purchases'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The SDK waits for a pause in the restore stream with a timer; the test clock runs it.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(restored.single.hasEntitlement('pro'), isTrue);
      expect(s.h.store.restores.single, customerId);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a restore error goes to onError', (tester) async {
      final s = await setup();
      s.h.store.restoreEmits = const [
        StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-a',
        ),
      ];
      s.h.transport.json('POST', '/v1/purchases/restore', {
        'error': {'code': 'PURCHASE_VERIFICATION_FAILED', 'message': 'bad'},
      }, status: 422);
      final errors = <GemicoreException>[];
      await pumpPaywall(tester, s, onError: errors.add);
      await tester.tap(find.text('Restore purchases'));
      // The SDK waits for a pause in the restore stream with a timer; the test clock runs it.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(errors.single.code, GemicoreErrorCode.verificationFailed);
    });

    testWidgets('an offering with no packages has no package list and a disabled purchase', (
      tester,
    ) async {
      final s = await setup();
      final empty = Offering(
        identifier: 'empty',
        displayName: 'Empty',
        isCurrent: false,
        packages: const [],
        paywall: s.offering.paywall,
      );
      await tester.pumpWidget(
        host(GemicorePaywall(offering: empty, sdk: s.sdk, locale: const Locale('en'))),
      );
      expect(find.text('Pro monthly'), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('legal links', () {
    testWidgets('open through the injected opener', (tester) async {
      final s = await setup();
      final opener = FakeOpener();
      await pumpPaywall(tester, s, urlOpener: opener);
      await tester.tap(find.text('Terms of Use'));
      await tester.tap(find.text('Privacy Policy'));
      await tester.pump();
      expect(opener.opened.map((u) => u.toString()), [
        'https://example.com/terms',
        'https://example.com/privacy',
      ]);
      expect(s.h.opener.opened, isEmpty);
    });

    testWidgets('use the SDK opener when none is given', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      await tester.tap(find.text('Terms of Use'));
      await tester.pump();
      expect(s.h.opener.opened.single.toString(), 'https://example.com/terms');
    });

    testWidgets('a link that is not https is not shown', (tester) async {
      final s = await setup(
        paywallConfig: configWithChildren([
          {
            'type': 'legal_links',
            'termsUrl': 'http://example.com/terms',
            'privacyUrl': 'https://example.com/privacy',
          },
        ]),
      );
      await pumpPaywall(tester, s);
      expect(find.text('Terms of Use'), findsNothing);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('an opener that fails is reported, not thrown', (tester) async {
      final s = await setup();
      final errors = <GemicoreException>[];
      await pumpPaywall(tester, s, urlOpener: _ThrowingOpener(), onError: errors.add);
      await tester.tap(find.text('Terms of Use'));
      await tester.pump();
      expect(errors, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('images', () {
    testWidgets('a hero image is decoded at the width it is drawn, not at full size', (
      tester,
    ) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<ResizeImage>());
      expect((image.image as ResizeImage).width, greaterThan(0));
      expect((image.image as ResizeImage).width, lessThanOrEqualTo(600));
    });

    testWidgets('an https image that fails to load shows the placeholder', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.byKey(const ValueKey('gemicore-paywall-image-placeholder')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an image that is not https is never requested and shows the placeholder', (
      tester,
    ) async {
      final s = await setup(
        paywallConfig: configWithChildren([
          {'type': 'image', 'url': 'http://example.com/a.png', 'aspect': 2, 'fit': 'contain'},
        ]),
      );
      await pumpPaywall(tester, s);
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const ValueKey('gemicore-paywall-image-placeholder')), findsOneWidget);
    });
  });

  group('configs that are broken', () {
    testWidgets('an unknown node type renders nothing and its neighbours still render', (
      tester,
    ) async {
      final s = await setup(
        paywallConfig: configWithChildren([
          {'type': 'carousel', 'slides': []},
          {'type': 'text', 'stringKey': 'title', 'style': 'title', 'align': 'center'},
          {'type': 'text'},
          'not even a node',
          {'type': 'purchase_button'},
        ]),
      );
      await pumpPaywall(tester, s);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a config that cannot be read renders nothing', (tester) async {
      final s = await setup(paywallConfig: {'version': 1, 'root': 'broken'});
      expect(s.offering.paywall!.config, isNull);
      await pumpPaywall(tester, s);
      expect(find.byType(GemicorePaywall), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(
        find.descendant(of: find.byType(GemicorePaywall), matching: find.byType(Material)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an offering with no paywall renders nothing', (tester) async {
      final s = await setup(paywallConfig: null);
      expect(s.offering.paywall, isNull);
      await pumpPaywall(tester, s);
      expect(find.byType(Text), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stack with only unusable children renders nothing at all', (tester) async {
      final s = await setup(
        paywallConfig: configWithChildren([
          {'type': 'mystery'},
          {'type': 'text', 'stringKey': 'missing_everywhere', 'style': 'body', 'align': 'start'},
        ]),
      );
      await pumpPaywall(tester, s);
      expect(find.byType(Text), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hostile tree of 5000 nested stacks is cut and does not crash', (tester) async {
      Object? node = {'type': 'text', 'stringKey': 'title', 'style': 'body', 'align': 'start'};
      for (var i = 0; i < 5000; i++) {
        node = {
          'type': 'stack',
          'direction': 'column',
          'spacing': 0,
          'padding': 0,
          'align': 'start',
          'children': [node],
        };
      }
      final s = await setup(paywallConfig: {...samplePaywallConfig(), 'root': node});
      await pumpPaywall(tester, s);
      expect(find.text('Go Pro'), findsNothing, reason: 'the leaf is below the depth cap');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a config passed to the widget replaces the one of the offering', (tester) async {
      final s = await setup();
      final other = PaywallConfig.tryParse(
        configWithChildren([
          {'type': 'text', 'stringKey': 'subtitle', 'style': 'body', 'align': 'start'},
        ]),
      );
      await pumpPaywall(tester, s, config: other);
      expect(find.text('Go Pro'), findsNothing);
      expect(find.text('Unlock everything. Cancel any time.'), findsOneWidget);
    });
  });

  group('accessibility and layout', () {
    testWidgets('right to left puts the radio icon at the right and keeps text start aligned', (
      tester,
    ) async {
      final s = await setup();
      await pumpPaywall(tester, s, direction: TextDirection.rtl);
      final icon = tester.getCenter(find.byIcon(Icons.radio_button_checked));
      final title = tester.getCenter(find.text('Pro monthly'));
      expect(icon.dx, greaterThan(title.dx));
      final price = tester.getCenter(find.text('\$4.99').first);
      expect(price.dx, lessThan(title.dx));
      expect(tester.takeException(), isNull);
    });

    testWidgets('left to right is the mirror image', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s);
      expect(
        tester.getCenter(find.byIcon(Icons.radio_button_checked)).dx,
        lessThan(tester.getCenter(find.text('Pro monthly')).dx),
      );
    });

    testWidgets('start aligned text sits at the start edge in both directions', (tester) async {
      final config = configWithChildren([
        {'type': 'text', 'stringKey': 'subtitle', 'style': 'body', 'align': 'start'},
      ]);
      final s = await setup(paywallConfig: config);
      await pumpPaywall(tester, s);
      final ltr = tester.getTopLeft(find.text('Unlock everything. Cancel any time.')).dx;
      await pumpPaywall(tester, s, direction: TextDirection.rtl);
      final rtlRight = tester.getTopRight(find.text('Unlock everything. Cancel any time.')).dx;
      final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(ltr, lessThan(40));
      expect(rtlRight, greaterThan(screen - 40));
    });

    testWidgets('double text size on a narrow screen does not overflow', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, textScale: 2, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('text scale reaches the text, which the SDK does not override', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, textScale: 1.5);
      final scaled = tester.getSize(find.text('Go Pro')).height;
      await pumpPaywall(tester, s);
      final plain = tester.getSize(find.text('Go Pro')).height;
      expect(scaled, greaterThan(plain));
    });

    testWidgets('the buttons and the title carry semantics', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await setup();
      await pumpPaywall(tester, s);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Continue')),
        isSemantics(isButton: true, isEnabled: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Restore purchases')),
        isSemantics(isButton: true),
      );
      expect(tester.getSemantics(find.bySemanticsLabel('Go Pro')), isSemantics(isHeader: true));
      expect(tester.getSemantics(find.bySemanticsLabel('Terms of Use')), isSemantics(isLink: true));
      handle.dispose();
    });

    testWidgets('a wide screen keeps the paywall in a column', (tester) async {
      final s = await setup();
      await pumpPaywall(tester, s, size: const Size(1600, 2400));
      expect(tester.getSize(find.byType(FilledButton)).width, lessThanOrEqualTo(640));
    });
  });

  group('presentPaywall', () {
    Future<PaywallResult?> open(
      WidgetTester tester,
      Setup s, {
      Offering? offering,
      void Function(PaywallResult)? onResult,
      bool useStaticSdk = false,
    }) async {
      PaywallResult? result;
      late BuildContext captured;
      useView(tester, const Size(600, 2400));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const Scaffold(body: Text('home'));
            },
          ),
        ),
      );
      final future = presentPaywall(
        captured,
        offering: offering,
        sdk: useStaticSdk ? null : s.sdk,
        locale: const Locale('en'),
      );
      future.then((r) {
        result = r;
        onResult?.call(r);
      });
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return result;
    }

    testWidgets('shows the current offering full screen and closing it is cancelled', (
      tester,
    ) async {
      final s = await setup();
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.byType(GemicorePaywall), findsOneWidget);
      expect(s.h.transport.calls('GET', '/v1/purchases/offerings'), hasLength(1));
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(result!.outcome, PaywallOutcome.cancelled);
      expect(result!.isCancelled, isTrue);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('the close button has an accessible label', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await setup();
      await open(tester, s);
      expect(find.byTooltip('Close'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a completed purchase closes the paywall as purchased', (tester) async {
      final s = await setup();
      s.h.transport.json('POST', '/v1/purchases', {
        'customer': customerJson(pro: true),
        'purchase': purchaseJson(),
      });
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'jws',
          needsCompletion: true,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(result!.outcome, PaywallOutcome.purchased);
      expect(result!.purchase!.customerInfo!.hasEntitlement('pro'), isTrue);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('a cancelled store sheet leaves the paywall open', (tester) async {
      final s = await setup();
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.canceled,
          serverVerificationData: '',
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('Go Pro'), findsOneWidget);
    });

    testWidgets('a pending purchase closes the paywall as pending', (tester) async {
      final s = await setup();
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.pending,
          serverVerificationData: '',
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(result!.outcome, PaywallOutcome.pending);
    });

    testWidgets('restore closes the paywall as restored with the customer', (tester) async {
      final s = await setup();
      s.h.store.restoreEmits = const [
        StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-a',
          needsCompletion: true,
        ),
      ];
      s.h.transport.json('POST', '/v1/purchases/restore', {'customer': customerJson(pro: true)});
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.text('Restore purchases'));
      await tester.pump();
      // The SDK waits for a pause in the restore stream with a timer; the test clock runs it.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(result!.outcome, PaywallOutcome.restored);
      expect(result!.customerInfo!.hasEntitlement('pro'), isTrue);
    });

    testWidgets('a network failure on purchase keeps the paywall open and says why', (
      tester,
    ) async {
      final s = await setup();
      s.h.transport.json('POST', '/v1/purchases', {
        'error': {'code': 'SERVER', 'message': 'try later'},
      }, status: 503);
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'jws',
          needsCompletion: true,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, isNull);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(find.text('try later'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
      // The SDK keeps the unrecorded purchase for a retry timer, which a test must not leave behind.
      await tester.runAsync(s.sdk.close);
    });

    testWidgets('a purchase failure closes the paywall as an error', (tester) async {
      final s = await setup();
      s.h.transport.json('POST', '/v1/purchases', {
        'error': {'code': 'PURCHASE_VERIFICATION_FAILED', 'message': 'bad'},
      }, status: 422);
      PaywallResult? result;
      await open(tester, s, onResult: (r) => result = r);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.purchased,
          serverVerificationData: 'bad',
          needsCompletion: true,
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(result!.outcome, PaywallOutcome.error);
      expect(result!.error!.code, GemicoreErrorCode.verificationFailed);
    });

    testWidgets('an offering passed in is shown without asking for offerings', (tester) async {
      final s = await setup();
      s.h.transport.requests.clear();
      await open(tester, s, offering: s.offering);
      expect(find.text('Go Pro'), findsOneWidget);
      expect(s.h.transport.calls('GET', '/v1/purchases/offerings'), isEmpty);
    });

    testWidgets('an offering with no published paywall is an error and nothing is shown', (
      tester,
    ) async {
      final s = await setup(paywallConfig: null);
      final result = await open(tester, s);
      expect(result!.outcome, PaywallOutcome.error);
      expect(result.error!.code, GemicoreErrorCode.paywallNotAvailable);
      expect(find.byType(GemicorePaywall), findsNothing);
    });

    testWidgets('a paywall the SDK cannot read is the same error', (tester) async {
      final s = await setup(paywallConfig: {'version': 5});
      final result = await open(tester, s);
      expect(result!.error!.code, GemicoreErrorCode.paywallNotAvailable);
    });

    testWidgets('no current offering is an error', (tester) async {
      final h = Harness();
      h.transport.json('GET', '/v1/purchases/offerings', offeringsJson(current: false));
      final sdk = await h.configure();
      final result = await open(tester, Setup(h, sdk, (await sdk.getOfferings()).all.values.first));
      expect(result!.error!.code, GemicoreErrorCode.paywallNotAvailable);
      expect(result.error!.message, contains('current offering'));
    });

    testWidgets('offerings that cannot be loaded are an error with the cause', (tester) async {
      final h = Harness();
      h.transport.on('GET', '/v1/purchases/offerings', (_) => throw StateError('offline'));
      final sdk = await h.configure();
      final result = await open(tester, Setup(h, sdk, _dummyOffering()));
      expect(result!.outcome, PaywallOutcome.error);
      expect(result.error!.code, GemicoreErrorCode.network);
    });

    testWidgets('an SDK that is not configured is an error, not an exception', (tester) async {
      final s = await setup();
      // close() waits on stream futures that need the real event loop, not the test clock.
      await tester.runAsync(s.sdk.close);
      final result = await open(tester, s, useStaticSdk: true);
      // The closed instance is gone, so the static instance is missing.
      expect(result!.outcome, PaywallOutcome.error);
      expect(result.error!.code, GemicoreErrorCode.notConfigured);
    });
  });
}

Offering _dummyOffering() =>
    const Offering(identifier: 'x', displayName: 'x', isCurrent: false, packages: []);

class _ThrowingOpener implements CheckoutOpener {
  @override
  Future<bool> open(Uri url) => throw StateError('no browser');
}
