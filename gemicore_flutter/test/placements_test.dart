import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

const path = '/v1/purchases/offerings';

/// The offerings answer for a placement: the server puts the chosen offering in `current`.
Map<String, Object?> placementAnswer({
  String chosen = 'spring',
  String source = 'rule',
  Map<String, Object?>? experiment,
  String placement = 'onboarding',
}) {
  final base = offeringsJson();
  final offerings = (base['offerings'] as List).cast<Map<String, Object?>>();
  final spring = {
    ...offerings.first,
    'identifier': 'spring',
    'displayName': 'Spring sale',
    'isCurrent': chosen == 'spring',
    'paywall': null,
  };
  return {
    'current': chosen,
    'offerings': [
      {...offerings.first, 'isCurrent': chosen == 'default'},
      spring,
    ],
    'placement': {'identifier': placement, 'source': source, 'experiment': experiment},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() {
    h = Harness();
    h.transport.json('GET', path, offeringsJson());
    h.store.catalog.addAll([
      storeDetail('com.example.pro.monthly', period: monthly),
      storeDetail('com.example.pro.annual', price: '\$39.99', rawPrice: 39.99, period: annual),
    ]);
  });

  tearDown(() async {
    if (Gemicore.isConfigured) await Gemicore.instance.close();
  });

  test('getOfferings(placement:) sends the placement query and models the resolution', () async {
    h.transport.on('GET', path, (request) {
      expect(request.url.queryParameters, {'placement': 'onboarding'});
      return TransportResponse(
        200,
        jsonEncode(
          placementAnswer(
            source: 'experiment',
            experiment: {'identifier': 'price_test', 'variant': 'b'},
          ),
        ),
      );
    });
    final sdk = await h.configure();
    final offerings = await sdk.getOfferings(placement: 'onboarding');
    expect(offerings.current!.identifier, 'spring');
    expect(offerings.current!.isCurrent, isTrue);
    final placement = offerings.placement!;
    expect(placement.identifier, 'onboarding');
    expect(placement.source, PlacementSource.experiment);
    expect(placement.experiment!.identifier, 'price_test');
    expect(placement.experiment!.variant, 'b');
  });

  test('every source parses, an unknown one is kept as unknown', () async {
    final sdk = await h.configure();
    for (final entry in {
      'rule': PlacementSource.rule,
      'default': PlacementSource.defaultOffering,
      'current': PlacementSource.current,
      'brand_new': PlacementSource.unknown,
    }.entries) {
      h.transport.json('GET', path, placementAnswer(source: entry.key));
      final offerings = await sdk.getOfferings(placement: 'onboarding', forceRefresh: true);
      expect(offerings.placement!.source, entry.value, reason: entry.key);
      expect(offerings.placement!.experiment, isNull);
    }
  });

  test('without a placement the query is empty and the resolution is null', () async {
    final sdk = await h.configure();
    final offerings = await sdk.getOfferings();
    expect(h.transport.calls('GET', path).single.url.hasQuery, isFalse);
    expect(offerings.placement, isNull);
  });

  test('each placement has its own memory cache', () async {
    h.transport.on('GET', path, (request) {
      final placement = request.url.queryParameters['placement'];
      return TransportResponse(
        200,
        jsonEncode(placement == null ? offeringsJson() : placementAnswer(placement: placement)),
      );
    });
    final sdk = await h.configure();
    final plain = await sdk.getOfferings();
    final onboarding = await sdk.getOfferings(placement: 'onboarding');
    final settings = await sdk.getOfferings(placement: 'settings');
    expect(h.transport.calls('GET', path), hasLength(3));
    expect(await sdk.getOfferings(), same(plain));
    expect(await sdk.getOfferings(placement: 'onboarding'), same(onboarding));
    expect(await sdk.getOfferings(placement: 'settings'), same(settings));
    expect(h.transport.calls('GET', path), hasLength(3));
    expect(onboarding.placement!.identifier, 'onboarding');
    expect(settings.placement!.identifier, 'settings');
    await sdk.getOfferings(placement: 'onboarding', forceRefresh: true);
    expect(h.transport.calls('GET', path), hasLength(4));
  });

  test('currentOffering follows the plain call, not a placement call', () async {
    h.transport.on('GET', path, (request) {
      final placement = request.url.queryParameters['placement'];
      return TransportResponse(
        200,
        jsonEncode(placement == null ? offeringsJson() : placementAnswer()),
      );
    });
    final sdk = await h.configure();
    await sdk.getOfferings();
    await sdk.getOfferings(placement: 'onboarding');
    expect(sdk.currentOffering!.identifier, 'default');
  });

  test('a placement is kept on the device and shown offline, apart from the plain copy', () async {
    h.transport.on('GET', path, (request) {
      final placement = request.url.queryParameters['placement'];
      return TransportResponse(
        200,
        jsonEncode(placement == null ? offeringsJson() : placementAnswer()),
      );
    });
    var sdk = await h.configure();
    await sdk.getOfferings();
    await sdk.getOfferings(placement: 'onboarding');
    await sdk.close();

    h.transport.on('GET', path, (_) => throw StateError('offline'));
    sdk = await h.configure();
    final offline = await sdk.getOfferings(placement: 'onboarding');
    expect(offline.current!.identifier, 'spring');
    expect(offline.placement!.source, PlacementSource.rule);
    final plain = await sdk.getOfferings();
    expect(plain.current!.identifier, 'default');
    // A placement never saved falls back to the app's own saved offerings, not an error.
    final other = await sdk.getOfferings(placement: 'other');
    expect(other.current!.identifier, 'default');
    expect(other.placement, isNull);
  });

  test('a placement with odd characters is stored under a safe key and queried verbatim', () async {
    h.transport.json('GET', path, placementAnswer(placement: r'a b/c$'));
    final sdk = await h.configure();
    await sdk.getOfferings(placement: r'a b/c$');
    expect(h.transport.calls('GET', path).single.url.queryParameters['placement'], r'a b/c$');
    expect(
      h.storage.values.keys.where((k) => k.contains('offerings')).every((k) => !k.contains('/')),
      isTrue,
    );
  });

  test('an unknown placement answers like none and is used silently', () async {
    // The server answers the app's offerings with placement null for a name it does not know.
    final sdk = await h.configure();
    final offerings = await sdk.getOfferings(placement: 'no_such_placement');
    expect(offerings.current!.identifier, 'default');
    expect(offerings.placement, isNull);
  });

  test(
    'a placement the server rejects falls back to the plain offerings without an error',
    () async {
      h.transport.on('GET', path, (request) {
        if (request.url.queryParameters.containsKey('placement')) {
          return TransportResponse(
            422,
            jsonEncode({
              'error': {'code': 'VALIDATION_ERROR', 'message': 'placement too long'},
            }),
          );
        }
        return TransportResponse(200, jsonEncode(offeringsJson()));
      });
      final sdk = await h.configure();
      final offerings = await sdk.getOfferings(placement: 'x' * 80);
      expect(offerings.current!.identifier, 'default');
      expect(offerings.placement, isNull);
      expect(h.transport.calls('GET', path), hasLength(2));
    },
  );

  test('a rejected key is not hidden by the placement fallback', () async {
    h.transport.json('GET', path, {
      'error': {'code': 'UNAUTHORIZED', 'message': 'bad key'},
    }, status: 401);
    final sdk = await h.configure();
    await expectLater(
      sdk.getOfferings(placement: 'onboarding'),
      throwsA(isA<GemicoreException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(h.transport.calls('GET', path), hasLength(1));
  });
}
