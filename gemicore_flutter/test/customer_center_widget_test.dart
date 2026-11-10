import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'customer_center_test.dart' show centerJson, retentionOfferJson, sampleCenterConfig;
import 'fakes.dart';

const appleManage = 'https://apps.apple.com/account/subscriptions';
const googleManage = 'https://play.google.com/store/account/subscriptions?sku=com.example.pro';
const refundLabel = "Need a refund? Open the store's own page.";
const feedbackPath = '/v1/purchases/customer-center/feedback';

/// An opener that, like the SDK's own, can also leave the app.
class FakeExternalOpener extends FakeOpener implements ExternalUrlOpener {
  final List<Uri> external = [];

  @override
  Future<bool> openExternal(Uri url) async {
    external.add(url);
    return true;
  }
}

Map<String, Object?> subscription({
  String id = 'p1',
  String store = 'app_store',
  String productIdentifier = 'pro_monthly',
  bool willRenew = true,
  bool billingIssue = false,
  String? managementUrl = appleManage,
}) => {
  ...purchaseJson(id: id, store: store, productIdentifier: productIdentifier),
  'willRenew': willRenew,
  'periodType': 'normal',
  'expiresAt': '2099-01-15T10:00:00.000Z',
  'billingIssueDetectedAt': billingIssue ? '2026-11-01T10:00:00.000Z' : null,
  'managementUrl': managementUrl,
};

Map<String, Object?> holder(List<Map<String, Object?>> purchases, {bool pro = true}) {
  final customer = customerJson(pro: pro, purchases: purchases);
  if (pro) {
    final entitlements = customer['entitlements'] as Map;
    for (final set in ['active', 'all']) {
      final pro = ((entitlements[set] as Map)['pro'] as Map);
      pro['expiresAt'] = '2099-01-15T10:00:00.000Z';
    }
  }
  return customer;
}

class Setup {
  Setup(this.h, this.sdk);

  final Harness h;
  final Gemicore sdk;
}

Future<Setup> setup({
  Map<String, Object?>? center,
  List<Map<String, Object?>>? purchases,
  String platform = 'ios',
  bool pro = true,
}) async {
  final h = Harness(platform: platform);
  h.transport.json(
    'GET',
    '/v1/purchases/customer',
    holder(purchases ?? [subscription()], pro: pro),
  );
  h.transport.json('GET', '/v1/purchases/customer-center', center ?? centerJson());
  h.transport.json('POST', feedbackPath, {'id': 'f1'}, status: 201);
  h.store.catalog.add(storeDetail('com.example.pro.monthly', period: monthly));
  return Setup(h, await h.configure());
}

Widget host(
  Widget child, {
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme,
  home: Directionality(
    textDirection: direction,
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: child),
    ),
  ),
);

void useView(WidgetTester tester, [Size size = const Size(600, 2400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, Object?> configWith(Map<String, Object?> changes) => {
  ...sampleCenterConfig(),
  ...changes,
};

Map<String, Object?> survey({bool enabled = true, bool allowOther = true}) => {
  'enabled': enabled,
  'allowOther': allowOther,
  'options': [
    {'key': 'too_expensive', 'label': 'It is too expensive'},
    {'key': 'not_using', 'label': 'I do not use it enough'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  Future<FakeOpener> pump(
    WidgetTester tester,
    Setup s, {
    FakeOpener? opener,
    Locale? locale = const Locale('en'),
    TextDirection direction = TextDirection.ltr,
    double textScale = 1,
    ThemeData? theme,
    ValueChanged<CustomerInfo>? onRestore,
    ValueChanged<GemicoreException>? onError,
    CustomerCenterView? view,
  }) async {
    useView(tester);
    final used = opener ?? FakeOpener();
    await tester.pumpWidget(
      host(
        GemicoreCustomerCenter(
          sdk: s.sdk,
          view: view,
          locale: locale,
          urlOpener: used,
          onRestore: onRestore,
          onError: onError,
        ),
        direction: direction,
        textScale: textScale,
        theme: theme,
      ),
    );
    await tester.pumpAndSettle();
    return used;
  }

  // The store sheet is a fake: the store reports the purchase once the app asked for it.
  Future<void> storeCompletes(WidgetTester tester, Setup s) async {
    for (var i = 0; i < 20 && s.h.store.buys.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(s.h.store.buys, isNotEmpty, reason: 'the store sheet was asked for');
    s.h.store.emit(
      const StorePurchaseUpdate(
        productId: 'com.example.pro.monthly',
        state: StorePurchaseState.purchased,
        serverVerificationData: 'jws-retention',
        needsCompletion: true,
      ),
    );
    await tester.pumpAndSettle();
  }

  void promotionalRoute(Setup s) {
    s.h.transport.json('POST', '/v1/purchases/apple/promotional-offer', {
      'productId': 'pro_monthly',
      'offerIdentifier': 'stay50',
      'signature': 'jws',
      'legacy': {
        'keyIdentifier': 'KEY1',
        'nonce': 'n-1',
        'timestamp': 1700000000000,
        'signature': 'sig',
      },
    });
    s.h.transport.json('POST', '/v1/purchases', {
      'customer': holder([subscription()]),
      'purchase': subscription(),
    });
  }

  group('summary', () {
    testWidgets('lists the active entitlements and subscriptions with renewal and store', (
      tester,
    ) async {
      final s = await setup();
      await pump(tester, s);
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('pro'), findsOneWidget, reason: 'the active entitlement');
      expect(find.text('Subscriptions'), findsOneWidget);
      expect(find.text('Pro monthly'), findsOneWidget, reason: 'the product title, not the id');
      expect(find.textContaining('Renews on'), findsOneWidget);
      expect(find.textContaining('2099'), findsOneWidget);
      expect(find.text('Billed through the App Store'), findsOneWidget);
      expect(find.text('Cancel subscription'), findsOneWidget);
    });

    testWidgets('a subscription that will not renew says when it ends and offers no cancel', (
      tester,
    ) async {
      final s = await setup(purchases: [subscription(willRenew: false)]);
      await pump(tester, s);
      expect(find.textContaining('Ends on'), findsOneWidget);
      expect(find.textContaining('Renews on'), findsNothing);
      expect(find.text('Cancel subscription'), findsNothing);
      expect(find.text('Manage subscription'), findsOneWidget);
    });

    testWidgets('a billing problem is named', (tester) async {
      final s = await setup(purchases: [subscription(billingIssue: true)]);
      await pump(tester, s);
      expect(find.textContaining('problem with your payment'), findsOneWidget);
    });

    testWidgets('a customer with nothing says so and has no cancel or manage', (tester) async {
      final s = await setup(
        purchases: [],
        pro: false,
        center: centerJson(managementUrls: {}),
      );
      await pump(tester, s);
      expect(find.text('You have no active subscriptions or purchases.'), findsOneWidget);
      expect(find.text('Cancel subscription'), findsNothing);
      expect(find.text('Manage subscription'), findsNothing);
      expect(find.text('Restore purchases'), findsOneWidget);
    });

    testWidgets('a one time purchase and an expired subscription are not listed as subscriptions', (
      tester,
    ) async {
      final s = await setup(
        purchases: [
          subscription(id: 'p2', productIdentifier: 'coins_100'),
          {...subscription(id: 'p3'), 'isActive': false, 'status': 'expired'},
        ].map((p) => p['id'] == 'p2' ? {...p, 'productType': 'consumable'} : p).toList(),
        pro: false,
      );
      await pump(tester, s);
      expect(find.text('Subscriptions'), findsNothing);
    });
  });

  group('actions', () {
    testWidgets('Manage subscription opens the product management url with the url opener', (
      tester,
    ) async {
      final s = await setup();
      final opener = await pump(tester, s);
      await tester.tap(find.text('Manage subscription'));
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
    });

    testWidgets('store pages leave the app when the opener can', (tester) async {
      final s = await setup();
      final opener = FakeExternalOpener();
      await pump(tester, s, opener: opener);
      await tester.tap(find.text('Manage subscription'));
      await tester.pumpAndSettle();
      expect(opener.external.map((u) => u.toString()), [appleManage]);
      expect(opener.opened, isEmpty);
    });

    testWidgets('with two store pages the customer picks which subscription', (tester) async {
      final s = await setup(
        purchases: [
          subscription(),
          subscription(
            id: 'p2',
            store: 'play_store',
            productIdentifier: 'pro_annual',
            managementUrl: googleManage,
          ),
        ],
        center: centerJson(
          managementUrls: {'pro_monthly': appleManage, 'pro_annual': googleManage},
        ),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Manage subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Which subscription?'), findsOneWidget);
      expect(opener.opened, isEmpty);
      await tester.tap(
        find.descendant(of: find.byType(SimpleDialog), matching: find.text('pro_annual')),
      );
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), [googleManage]);
    });

    testWidgets('with the manage button switched off the button is gone', (tester) async {
      final s = await setup(
        center: centerJson(
          config: configWith({'showManageSubscription': false}),
          managementUrls: {},
        ),
      );
      await pump(tester, s);
      expect(find.text('Manage subscription'), findsNothing);
    });

    testWidgets('Restore purchases restores, tells the customer and reports the customer info', (
      tester,
    ) async {
      final s = await setup();
      CustomerInfo? restored;
      await pump(tester, s, onRestore: (info) => restored = info);
      await tester.tap(find.text('Restore purchases'));
      await tester.pumpAndSettle();
      expect(find.text('Your purchases were checked and restored.'), findsOneWidget);
      expect(restored, isNotNull);
      expect(s.h.store.restores, [customerId]);
    });

    testWidgets('a failed restore says so and reports the error', (tester) async {
      final s = await setup();
      s.h.store.available = true;
      s.h.transport.on('GET', '/v1/purchases/customer', (_) => throw StateError('offline'));
      // A restore with nothing to collect refreshes the customer; the refresh failing is a network error.
      GemicoreException? reported;
      await pump(tester, s, onError: (e) => reported = e);
      s.h.transport.on('POST', '/v1/purchases/restore', (_) => throw StateError('offline'));
      s.h.store.restoreEmits = [
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.restored,
          serverVerificationData: 'jws-1',
        ),
      ];
      await tester.tap(find.text('Restore purchases'));
      await tester.pumpAndSettle();
      expect(find.text('Restoring purchases did not work. Please try again.'), findsOneWidget);
      expect(reported, isNotNull);
    });

    testWidgets('refund help opens Apple Report a Problem for an App Store purchase', (
      tester,
    ) async {
      final s = await setup();
      final opener = await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), ['https://reportaproblem.apple.com']);
    });

    testWidgets('refund help opens Google order history for a Play purchase', (tester) async {
      final s = await setup(
        platform: 'android',
        purchases: [subscription(store: 'play_store', managementUrl: googleManage)],
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), [
        'https://play.google.com/store/account/orderhistory',
      ]);
    });

    testWidgets('with purchases from both stores the customer chooses the store', (tester) async {
      final s = await setup(
        purchases: [
          subscription(),
          subscription(id: 'p2', store: 'play_store', productIdentifier: 'pro_annual'),
        ],
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(find.text('Which store did you buy from?'), findsOneWidget);
      await tester.tap(find.text('Google Play').last);
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), [
        'https://play.google.com/store/account/orderhistory',
      ]);
    });

    testWidgets('with no store purchase the help page is the one of this device store', (
      tester,
    ) async {
      final s = await setup(purchases: [], pro: false, platform: 'android');
      final opener = await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(opener.opened.single.host, 'play.google.com');
    });

    testWidgets('the refund help label can be translated by the config', (tester) async {
      final s = await setup();
      await pump(tester, s, locale: const Locale('de'));
      expect(find.text('Erstattung noetig? Oeffne die Seite des Stores.'), findsOneWidget);
    });

    testWidgets('with no configured text the refund help label is the built in one', (
      tester,
    ) async {
      final s = await setup(
        center: centerJson(config: configWith({'strings': <String, Object?>{}})),
      );
      await pump(tester, s);
      expect(find.text('Get help with a purchase'), findsOneWidget);
    });

    testWidgets('Contact support prefers the support url', (tester) async {
      final s = await setup();
      final opener = await pump(tester, s);
      await tester.tap(find.text('Contact support'));
      await tester.pumpAndSettle();
      expect(opener.opened.single.toString(), 'https://example.com/support');
    });

    testWidgets('Contact support falls back to mailto', (tester) async {
      final s = await setup(center: centerJson(config: configWith({'supportUrl': null})));
      final opener = await pump(tester, s);
      await tester.tap(find.text('Contact support'));
      await tester.pumpAndSettle();
      expect(opener.opened.single.toString(), 'mailto:support@example.com');
    });

    testWidgets('sections the config leaves out are not drawn', (tester) async {
      final s = await setup(
        center: centerJson(
          config: configWith({
            'showRestore': false,
            'showRefundHelp': false,
            'supportEmail': null,
            'supportUrl': null,
            'showManageSubscription': false,
          }),
        ),
      );
      await pump(tester, s);
      expect(find.text('Restore purchases'), findsNothing);
      expect(find.text(refundLabel), findsNothing);
      expect(find.text('Contact support'), findsNothing);
      expect(find.text('Manage subscription'), findsNothing);
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('an opener that cannot open the page says so', (tester) async {
      final s = await setup();
      final opener = _RefusingOpener();
      await pump(tester, s, opener: opener);
      await tester.tap(find.text('Manage subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    });
  });

  group('cancel flow', () {
    testWidgets(
      'with no survey and no offer it opens the management page and says the store cancels',
      (tester) async {
        final s = await setup(
          center: centerJson(
            config: configWith({'cancelSurvey': survey(enabled: false), 'retention': []}),
          ),
        );
        final opener = await pump(tester, s);
        await tester.tap(find.text('Cancel subscription'));
        await tester.pumpAndSettle();
        expect(opener.opened.map((u) => u.toString()), [appleManage]);
        expect(s.h.transport.calls('POST', feedbackPath), isEmpty, reason: 'nothing to record');
        expect(find.textContaining('cancelled there, not in this app'), findsOneWidget);
        expect(find.textContaining('Your subscription was cancelled'), findsNothing);
      },
    );

    testWidgets(
      'the survey shows its options and Other, and the answer is recorded before the store opens',
      (tester) async {
        final s = await setup(
          center: centerJson(config: configWith({'cancelSurvey': survey(), 'retention': []})),
        );
        final opener = await pump(tester, s);
        await tester.tap(find.text('Cancel subscription'));
        await tester.pumpAndSettle();
        expect(find.text('Why are you leaving?'), findsOneWidget);
        expect(find.text('It is too expensive'), findsOneWidget);
        expect(find.text('I do not use it enough'), findsOneWidget);
        expect(find.text('Other'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed,
          isNull,
          reason: 'an answer is needed first',
        );
        await tester.tap(find.text('It is too expensive'));
        await tester.pump();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(s.h.transport.calls('POST', feedbackPath).single.json, {
          'reasonKey': 'too_expensive',
          'purchaseId': 'p1',
          'offerAccepted': false,
        });
        expect(opener.opened.map((u) => u.toString()), [appleManage]);
      },
    );

    testWidgets('Other opens a text field and sends the text', (tester) async {
      final s = await setup(
        center: centerJson(config: configWith({'cancelSurvey': survey(), 'retention': []})),
      );
      await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Other'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'too many ads');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(s.h.transport.calls('POST', feedbackPath).single.json, {
        'reasonKey': 'other',
        'reasonText': 'too many ads',
        'purchaseId': 'p1',
        'offerAccepted': false,
      });
    });

    testWidgets('Other is not offered when the survey does not allow it', (tester) async {
      final s = await setup(
        center: centerJson(
          config: configWith({'cancelSurvey': survey(allowOther: false), 'retention': []}),
        ),
      );
      await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Other'), findsNothing);
    });

    testWidgets('closing the survey backs out: nothing is recorded and the store is not opened', (
      tester,
    ) async {
      final s = await setup(
        center: centerJson(config: configWith({'cancelSurvey': survey(), 'retention': []})),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(s.h.transport.calls('POST', feedbackPath), isEmpty);
      expect(opener.opened, isEmpty);
    });

    testWidgets('a survey option label can be translated by the config', (tester) async {
      final config = configWith({
        'cancelSurvey': survey(),
        'retention': [],
        'strings': {
          'de': {'survey_option.too_expensive': 'Zu teuer', 'survey_other': 'Sonstiges'},
        },
      });
      final s = await setup(center: centerJson(config: config));
      await pump(tester, s, locale: const Locale('de'));
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Zu teuer'), findsOneWidget);
      expect(
        find.text('I do not use it enough'),
        findsOneWidget,
        reason: 'untranslated keeps the label',
      );
      expect(find.text('Sonstiges'), findsOneWidget);
    });

    testWidgets('an eligible offer is shown first and declining records it and opens the store', (
      tester,
    ) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsOneWidget);
      expect(find.text('50 percent off for three months'), findsOneWidget);
      expect(opener.opened, isEmpty, reason: 'the offer comes before the store');
      expect(
        s.h.transport.calls('POST', feedbackPath),
        isEmpty,
        reason: 'one record, after the choice',
      );
      await tester.tap(find.text('No thanks, continue'));
      await tester.pumpAndSettle();
      expect(s.h.transport.calls('POST', feedbackPath).single.json, {
        'reasonKey': 'too_expensive',
        'purchaseId': 'p1',
        'offerShown': 'stay_50',
        'offerAccepted': false,
      });
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
    });

    testWidgets(
      'accepting buys the offer through the promotional offer path and does not open the store',
      (tester) async {
        final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
        promotionalRoute(s);
        final opener = await pump(tester, s);
        await tester.tap(find.text('Cancel subscription'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('It is too expensive'));
        await tester.pump();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Get this offer'));
        await storeCompletes(tester, s);

        expect(s.h.transport.calls('POST', '/v1/purchases/apple/promotional-offer').single.json, {
          'productId': 'pro_monthly',
          'offerId': 'stay_50',
        });
        final bought = s.h.store.buys.single;
        expect(bought.productId, 'com.example.pro.monthly');
        expect(bought.offer!.promotional!.offerId, 'stay50');
        expect(bought.offer!.promotional!.keyId, 'KEY1');
        expect(s.h.transport.calls('POST', feedbackPath).single.json, {
          'reasonKey': 'too_expensive',
          'purchaseId': 'p1',
          'offerShown': 'stay_50',
          'offerAccepted': true,
        });
        expect(opener.opened, isEmpty);
        expect(find.text('Your offer was applied. Thank you for staying.'), findsOneWidget);
      },
    );

    testWidgets('with the survey off an offer is still shown and nothing is recorded', (
      tester,
    ) async {
      final s = await setup(
        center: centerJson(
          config: configWith({'cancelSurvey': survey(enabled: false)}),
          offers: [retentionOfferJson()],
        ),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsOneWidget);
      await tester.tap(find.text('No thanks, continue'));
      await tester.pumpAndSettle();
      expect(s.h.transport.calls('POST', feedbackPath), isEmpty);
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
    });

    testWidgets('a store sheet the customer closes leaves the offer up to try again', (
      tester,
    ) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      promotionalRoute(s);
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get this offer'));
      for (var i = 0; i < 20 && s.h.store.buys.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.canceled,
          serverVerificationData: '',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsOneWidget);
      expect(find.text('Get this offer'), findsOneWidget);
      expect(s.h.transport.calls('POST', feedbackPath), isEmpty);
      expect(opener.opened, isEmpty);
    });

    testWidgets('an offer that cannot be bought shows the reason and stays', (tester) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      s.h.transport.json('POST', '/v1/purchases/apple/promotional-offer', {
        'error': {
          'code': 'PURCHASE_NOT_ELIGIBLE',
          'message': 'You are not eligible for this offer',
        },
      }, status: 403);
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get this offer'));
      await tester.pumpAndSettle();
      expect(find.text('You are not eligible for this offer'), findsOneWidget);
      expect(find.text('Get this offer'), findsOneWidget);
      expect(opener.opened, isEmpty);
      // The customer can still leave through the store.
      await tester.tap(find.text('No thanks, continue'));
      await tester.pumpAndSettle();
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
    });

    testWidgets('an offer the customer is not eligible for is not shown', (tester) async {
      final s = await setup(center: centerJson(offers: []));
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsNothing);
      expect(opener.opened, hasLength(1));
    });

    testWidgets('an offer that belongs to another product is not shown', (tester) async {
      final s = await setup(
        center: centerJson(
          config: configWith({
            'retention': [
              {'productIdentifier': 'pro_annual', 'offerIdentifier': 'stay_50'},
            ],
          }),
          offers: [retentionOfferJson()],
        ),
      );
      await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsNothing);
    });

    testWidgets('an offer the subscription store cannot apply is not shown', (tester) async {
      final s = await setup(
        center: centerJson(
          offers: [
            {...retentionOfferJson(), 'appleOfferIdentifier': null},
          ],
        ),
      );
      await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsNothing);
    });

    testWidgets('a feedback request that fails never blocks the customer', (tester) async {
      final s = await setup(center: centerJson(config: configWith({'retention': []})));
      s.h.transport.json('POST', feedbackPath, {
        'error': {'code': 'INTERNAL', 'message': 'boom'},
      }, status: 500);
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(s.h.transport.calls('POST', feedbackPath), hasLength(1));
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a feedback request that throws before the network never blocks either', (
      tester,
    ) async {
      final s = await setup(center: centerJson(config: configWith({'retention': []})));
      s.h.transport.on('POST', feedbackPath, (_) => throw StateError('offline'));
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(opener.opened, hasLength(1));
    });

    testWidgets('with no management page known the customer is told, not left waiting', (
      tester,
    ) async {
      final s = await setup(
        purchases: [subscription(managementUrl: null)],
        center: centerJson(
          config: configWith({'cancelSurvey': survey(enabled: false), 'retention': []}),
          managementUrls: {},
        ),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(opener.opened, isEmpty);
      expect(find.text('There is no store page to manage this subscription.'), findsOneWidget);
    });

    testWidgets('a Play subscription goes to its Play page and an offer needs a Google offer id', (
      tester,
    ) async {
      final s = await setup(
        platform: 'android',
        purchases: [subscription(store: 'play_store', managementUrl: googleManage)],
        center: centerJson(
          config: configWith({'cancelSurvey': survey(enabled: false)}),
          managementUrls: {'pro_monthly': googleManage},
          offers: [
            {...retentionOfferJson(), 'googleOfferId': null},
          ],
        ),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsNothing);
      expect(opener.opened.map((u) => u.toString()), [googleManage]);
    });
  });

  group('review fixes', () {
    Future<void> startCancel(WidgetTester tester) async {
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    testWidgets('a pending purchase is not an applied offer', (tester) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      promotionalRoute(s);
      final opener = await pump(tester, s);
      await startCancel(tester);
      await tester.tap(find.text('Get this offer'));
      for (var i = 0; i < 20 && s.h.store.buys.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      s.h.store.emit(
        const StorePurchaseUpdate(
          productId: 'com.example.pro.monthly',
          state: StorePurchaseState.pending,
          serverVerificationData: '',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your offer was applied. Thank you for staying.'), findsNothing);
      expect(
        find.text(
          'Your purchase is waiting for approval. Nothing changes until the store confirms it.',
        ),
        findsOneWidget,
      );
      expect(s.h.transport.calls('POST', feedbackPath).single.json['offerAccepted'], isFalse);
      expect(opener.opened, isEmpty);
    });

    testWidgets('after an accepted offer the screen reloads the view and drops the offer', (
      tester,
    ) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      promotionalRoute(s);
      final view = CustomerCenterView.fromJson(centerJson(offers: [retentionOfferJson()]));
      // The server no longer lists the offer once it is used.
      s.h.transport.json('GET', '/v1/purchases/customer-center', centerJson());
      await pump(tester, s, view: view);
      expect(s.h.transport.calls('GET', '/v1/purchases/customer-center'), isEmpty);
      await startCancel(tester);
      await tester.tap(find.text('Get this offer'));
      await storeCompletes(tester, s);
      expect(s.h.transport.calls('GET', '/v1/purchases/customer-center'), hasLength(1));
      await startCancel(tester);
      expect(find.text('Before you go'), findsNothing);
    });

    testWidgets('a view passed later replaces the one on screen', (tester) async {
      final s = await setup();
      useView(tester);
      Widget page(CustomerCenterView? view) =>
          host(GemicoreCustomerCenter(sdk: s.sdk, view: view, locale: const Locale('en')));
      await tester.pumpWidget(page(CustomerCenterView.fromJson(centerJson())));
      await tester.pumpAndSettle();
      expect(find.text('Restore purchases'), findsOneWidget);
      final changed = centerJson(config: configWith({'showRestore': false}));
      await tester.pumpWidget(page(CustomerCenterView.fromJson(changed)));
      await tester.pumpAndSettle();
      expect(find.text('Restore purchases'), findsNothing);
    });

    testWidgets('a slow feedback request does not hold the store page back', (tester) async {
      final s = await setup(center: centerJson(config: configWith({'retention': []})));
      final release = Completer<void>();
      s.h.transport.on('POST', feedbackPath, (_) async {
        await release.future;
        return TransportResponse(201, '{"id":"f1"}');
      });
      final opener = await pump(tester, s);
      await startCancel(tester);
      expect(opener.opened.map((u) => u.toString()), [appleManage]);
      release.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a dismissed offer sends no feedback and does not open the store', (tester) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      final opener = await pump(tester, s);
      await startCancel(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('Before you go'), findsNothing);
      expect(s.h.transport.calls('POST', feedbackPath), isEmpty);
      expect(opener.opened, isEmpty);
    });

    testWidgets('a Play retention offer is not shown, a replacement purchase is not built', (
      tester,
    ) async {
      final s = await setup(
        platform: 'android',
        purchases: [subscription(store: 'play_store', managementUrl: googleManage)],
        center: centerJson(
          managementUrls: {'pro_monthly': googleManage},
          offers: [retentionOfferJson()],
        ),
      );
      final opener = await pump(tester, s);
      await startCancel(tester);
      expect(find.text('Before you go'), findsNothing);
      expect(opener.opened.map((u) => u.toString()), [googleManage]);
    });

    testWidgets('a malformed support url says so and throws nothing', (tester) async {
      final s = await setup(
        center: centerJson(config: configWith({'supportUrl': 'https://[broken'})),
      );
      final opener = await pump(tester, s);
      await tester.tap(find.text('Contact support'));
      await tester.pumpAndSettle();
      expect(opener.opened, isEmpty);
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the store picker takes its capitalised App Store name from the config', (
      tester,
    ) async {
      final s = await setup(
        purchases: [
          subscription(),
          subscription(id: 'p2', store: 'play_store', productIdentifier: 'pro_annual'),
        ],
        center: centerJson(
          config: configWith({
            'strings': {
              'en': {
                'store_app_store': "l'App Store",
                'store_app_store_title': "L'App Store",
                'refund_help': refundLabel,
              },
            },
          }),
        ),
      );
      await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(find.text("L'App Store"), findsOneWidget);
    });

    testWidgets('the built in picker label is The App Store', (tester) async {
      final s = await setup(
        purchases: [
          subscription(),
          subscription(id: 'p2', store: 'play_store', productIdentifier: 'pro_annual'),
        ],
      );
      await pump(tester, s);
      await tester.tap(find.text(refundLabel));
      await tester.pumpAndSettle();
      expect(find.text('The App Store'), findsOneWidget);
    });
  });

  group('presentCustomerCenter', () {
    Widget app(Future<Object?> Function(BuildContext) onTap) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => onTap(context), child: const Text('open')),
        ),
      ),
    );

    testWidgets('a disabled Customer Center returns false and shows nothing', (tester) async {
      final s = await setup(center: centerJson(enabled: false));
      Object? result;
      await tester.pumpWidget(
        app((context) async => result = await presentCustomerCenter(context, sdk: s.sdk)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(find.byType(GemicoreCustomerCenter), findsNothing);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('an enabled one is shown full screen with its title and returns true when closed', (
      tester,
    ) async {
      useView(tester);
      final s = await setup();
      Object? result;
      await tester.pumpWidget(
        app(
          (context) async => result = await presentCustomerCenter(
            context,
            sdk: s.sdk,
            locale: const Locale('en'),
            urlOpener: FakeOpener(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(GemicoreCustomerCenter), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Manage your subscription')),
        findsOneWidget,
      );
      expect(result, isNull, reason: 'still open');
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('a failed load is a typed error, not a silent false', (tester) async {
      final s = await setup();
      s.h.transport.on('GET', '/v1/purchases/customer-center', (_) => throw StateError('offline'));
      Object? error;
      await tester.pumpWidget(
        app((context) async {
          try {
            await presentCustomerCenter(context, sdk: s.sdk);
          } catch (e) {
            error = e;
          }
          return null;
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(error, isA<GemicoreException>());
      expect((error! as GemicoreException).code, GemicoreErrorCode.network);
    });
  });

  group('the widget on its own', () {
    testWidgets('loads the view itself and shows a progress indicator meanwhile', (tester) async {
      final s = await setup();
      useView(tester);
      await tester.pumpWidget(
        host(
          GemicoreCustomerCenter(sdk: s.sdk, locale: const Locale('en'), urlOpener: FakeOpener()),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      expect(s.h.transport.calls('GET', '/v1/purchases/customer-center'), hasLength(1));
    });

    testWidgets('a disabled Customer Center draws nothing', (tester) async {
      final s = await setup(center: centerJson(enabled: false));
      useView(tester);
      await tester.pumpWidget(
        host(
          GemicoreCustomerCenter(sdk: s.sdk, locale: const Locale('en'), urlOpener: FakeOpener()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsNothing);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('a load failure shows a retry that works', (tester) async {
      final s = await setup();
      var fail = true;
      s.h.transport.on('GET', '/v1/purchases/customer-center', (_) {
        if (fail) throw StateError('offline');
        return TransportResponse(200, jsonEncode(centerJson()));
      });
      useView(tester);
      await tester.pumpWidget(
        host(
          GemicoreCustomerCenter(sdk: s.sdk, locale: const Locale('en'), urlOpener: FakeOpener()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('an unconfigured SDK is an error state, not a crash', (tester) async {
      useView(tester);
      await tester.pumpWidget(host(const GemicoreCustomerCenter(locale: Locale('en'))));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('locale, text scale, direction, theme and semantics', () {
    testWidgets(
      'a German device sees the German strings and English for what the config leaves out',
      (tester) async {
        final s = await setup();
        await pump(tester, s, locale: const Locale('de'));
        expect(find.text('Restore purchases'), findsOneWidget, reason: 'no German restore string');
        await tester.tap(find.text('Cancel subscription'));
        await tester.pumpAndSettle();
        expect(find.text('Warum gehst du?'), findsOneWidget);
      },
    );

    testWidgets('a language the config does not cover shows the config English', (tester) async {
      final s = await setup();
      await pump(tester, s, locale: const Locale('ja'));
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Why are you leaving?'), findsOneWidget);
    });

    testWidgets('with no locale override the device locale decides', (tester) async {
      final s = await setup();
      tester.platformDispatcher.localesTestValue = const [Locale('de')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await pump(tester, s, locale: null);
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Warum gehst du?'), findsOneWidget);
    });

    testWidgets('right to left mirrors the rows and breaks nothing', (tester) async {
      final s = await setup();
      await pump(tester, s, direction: TextDirection.rtl);
      expect(tester.takeException(), isNull);
      final tile = find.widgetWithText(ListTile, 'Restore purchases');
      final icon = find.descendant(of: tile, matching: find.byIcon(Icons.restore));
      final title = find.descendant(of: tile, matching: find.text('Restore purchases'));
      expect(
        tester.getCenter(icon).dx,
        greaterThan(tester.getCenter(title).dx),
        reason: 'the leading icon sits on the right',
      );
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text scales without overflow, on the screen and in the dialogs', (
      tester,
    ) async {
      final s = await setup(center: centerJson(offers: [retentionOfferJson()]));
      await pump(tester, s, textScale: 3);
      expect(tester.takeException(), isNull);
      expect(find.text('Restore purchases'), findsOneWidget);
      await tester.ensureVisible(find.text('Cancel subscription'));
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Other'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a small phone screen scrolls instead of overflowing', (tester) async {
      final s = await setup();
      useView(tester, const Size(320, 480));
      await tester.pumpWidget(
        host(
          GemicoreCustomerCenter(sdk: s.sdk, locale: const Locale('en'), urlOpener: FakeOpener()),
          textScale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Contact support'), 100);
      expect(find.text('Contact support'), findsOneWidget);
    });

    testWidgets('dark and light themes both draw with their own surface', (tester) async {
      final s = await setup();
      await pump(tester, s, theme: ThemeData.light());
      final light = tester.widget<Material>(find.byType(Material).first).color;
      await pump(tester, s, theme: ThemeData.dark());
      final dark = tester.widget<Material>(find.byType(Material).first).color;
      expect(tester.takeException(), isNull);
      expect(
        ThemeData.estimateBrightnessForColor(light!),
        isNot(ThemeData.estimateBrightnessForColor(dark!)),
      );
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('headers, buttons and the survey choices are announced', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await setup(
        center: centerJson(config: configWith({'cancelSurvey': survey(), 'retention': []})),
      );
      await pump(tester, s);
      expect(
        tester.getSemantics(find.text('Your plan')),
        matchesSemantics(label: 'Your plan', isHeader: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(ListTile, 'Restore purchases')),
        matchesSemantics(
          label: 'Restore purchases',
          isButton: true,
          hasEnabledState: true,
          hasSelectedState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      await tester.tap(find.text('Cancel subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('It is too expensive'));
      await tester.pump();
      final chosen = tester.getSemantics(find.widgetWithText(ListTile, 'It is too expensive'));
      final other = tester.getSemantics(find.widgetWithText(ListTile, 'I do not use it enough'));
      // ignore: deprecated_member_use
      expect(chosen.hasFlag(SemanticsFlag.isChecked), isTrue);
      // ignore: deprecated_member_use
      expect(other.hasFlag(SemanticsFlag.isChecked), isFalse);
      // ignore: deprecated_member_use
      expect(chosen.hasFlag(SemanticsFlag.isInMutuallyExclusiveGroup), isTrue);
      handle.dispose();
    });
  });
}

class _RefusingOpener extends FakeOpener {
  @override
  Future<bool> open(Uri url) async => false;
}
