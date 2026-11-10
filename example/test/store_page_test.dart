import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter_example/main.dart';

const _customer = {
  'id': '0b9c5f4e-6a1f-4c8e-9a52-2b7e1d3f4a10',
  'externalId': null,
  'entitlements': {'active': {}, 'all': {}},
  'activeSubscriptions': <String>[],
  'purchases': <Object>[],
  'requestedAt': '2026-11-04T12:00:00.000Z',
};

class _Transport implements GemicoreTransport {
  final requests = <Uri>[];

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    requests.add(url);
    final Object payload = switch (url.path) {
      '/v1/purchases/customers' => {'customer': _customer, 'token': 'tok_1'},
      '/v1/purchases/customer' => _customer,
      '/v1/purchases/products' => {'products': <Object>[]},
      '/v1/purchases/offerings' => {'current': null, 'offerings': <Object>[], 'placement': null},
      '/v1/purchases/customer-center' => {
        'enabled': false,
        'config': <String, Object?>{},
        'managementUrls': <String, Object?>{},
        'eligibleRetentionOffers': <Object>[],
      },
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

void main() {
  late _Transport transport;

  setUp(() async {
    transport = _Transport();
    await Gemicore.configure(
      apiKey: 'pk_test_abcdefghijklmnopqrstuvwxyz012345',
      baseUrl: 'https://api.test',
      transport: transport,
      storage: MemoryGemicoreStorage(),
      store: _NoStore(),
      appVersionProvider: () async => '1.0.0',
      observeAppLifecycle: false,
      logLevel: GemicoreLogLevel.none,
    );
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  testWidgets('the Customer Center button says so when the dashboard has it off', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StorePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customer Center'));
    await tester.pumpAndSettle();
    expect(find.text('The Customer Center is not enabled in the dashboard'), findsOneWidget);
  });

  testWidgets('the placement button asks the server for the onboarding placement', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StorePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paywall for the onboarding placement'));
    await tester.pumpAndSettle();
    final offeringCalls = transport.requests.where((u) => u.path == '/v1/purchases/offerings');
    expect(offeringCalls.single.queryParameters, {'placement': 'onboarding'});
    expect(find.text('Placement paywall: error'), findsOneWidget);
  });
}
