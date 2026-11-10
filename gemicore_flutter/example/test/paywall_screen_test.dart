import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter_example/paywall_screen.dart';

const _key = 'pk_test_abcdefghijklmnopqrstuvwxyz012345';

class _Transport implements GemicoreTransport {
  _Transport(this.offerings);

  final Map<String, Object?> offerings;

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final Object payload = switch (url.path) {
      '/v1/purchases/customers' => {'customer': _customer, 'token': 'tok_1'},
      '/v1/purchases/customer' => _customer,
      '/v1/purchases/offerings' => offerings,
      _ => {
        'error': {'code': 'NOT_FOUND', 'message': 'no fake'},
      },
    };
    return TransportResponse(
      url.path.startsWith('/v1/purchases/') ? 200 : 404,
      jsonEncode(payload),
    );
  }
}

const _customer = {
  'id': '0b9c5f4e-6a1f-4c8e-9a52-2b7e1d3f4a10',
  'externalId': null,
  'entitlements': {'active': {}, 'all': {}},
  'activeSubscriptions': <String>[],
  'purchases': <Object>[],
  'requestedAt': '2026-11-04T12:00:00.000Z',
};

class _NoStore implements StoreBridge {
  @override
  String get platform => 'ios';

  @override
  Future<bool> isAvailable() async => false;

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => const Stream.empty();

  @override
  Future<List<StoreProductDetails>> queryProducts(Set<String> ids) async => const [];

  @override
  Future<void> buy(
    StoreProductDetails product, {
    required bool consumable,
    required String accountId,
    StorePurchaseOffer? offer,
  }) async {}

  @override
  Future<void> complete(StorePurchaseUpdate update) async {}

  @override
  Future<void> restore({required String accountId}) async {}
}

Map<String, Object?> _offerings({Object? paywall}) => {
  'current': 'default',
  'offerings': [
    {
      'identifier': 'default',
      'displayName': 'Pro',
      'description': null,
      'metadata': <String, Object?>{},
      'isCurrent': true,
      'packages': [
        {
          'identifier': r'$rc_monthly',
          'packageType': 'monthly',
          'displayName': 'Monthly',
          'product': {
            'identifier': 'pro_monthly',
            'type': 'subscription',
            'displayName': 'Pro monthly',
            'description': null,
            'storeProductId': 'com.example.pro.monthly',
            'googleBasePlanId': null,
            'entitlements': ['pro'],
            'card': null,
          },
        },
      ],
      'paywall': paywall,
    },
  ],
};

Future<void> _configure(Map<String, Object?> offerings) => Gemicore.configure(
  apiKey: _key,
  baseUrl: 'https://api.test',
  transport: _Transport(offerings),
  storage: MemoryGemicoreStorage(),
  store: _NoStore(),
  observeAppLifecycle: false,
  logLevel: GemicoreLogLevel.none,
);

void main() {
  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  testWidgets('draws the published paywall of the current offering', (tester) async {
    await _configure(
      _offerings(
        paywall: {
          'offeringIdentifier': 'default',
          'revision': 1,
          'config': {
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
              'en': {'title': 'Go Pro', 'cta': 'Continue'},
            },
            'root': {
              'type': 'stack',
              'direction': 'column',
              'spacing': 8,
              'padding': 16,
              'align': 'stretch',
              'children': [
                {'type': 'text', 'stringKey': 'title', 'style': 'title', 'align': 'center'},
                {'type': 'package_list', 'layout': 'vertical', 'selected': null},
                {'type': 'purchase_button', 'stringKey': 'cta'},
              ],
            },
          },
        },
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
    await tester.pump();
    await tester.pump();
    expect(find.byType(GemicorePaywall), findsOneWidget);
    expect(find.text('Go Pro'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Full screen'), findsOneWidget);
  });

  testWidgets('lists the packages when the offering has no paywall', (tester) async {
    await _configure(_offerings());
    await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
    await tester.pump();
    await tester.pump();
    expect(find.byType(GemicorePaywall), findsNothing);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Buy'), findsOneWidget);
  });

  testWidgets('says so when the dashboard has no current offering', (tester) async {
    await _configure({'current': null, 'offerings': <Object>[]});
    await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
    await tester.pump();
    await tester.pump();
    expect(find.text('No current offering is set in the dashboard'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
