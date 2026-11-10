import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

/// The canonical sample of services/api/src/stores/customer-center/sample-config.ts.
Map<String, Object?> sampleCenterConfig() => {
  'version': 1,
  'supportEmail': 'support@example.com',
  'supportUrl': 'https://example.com/support',
  'showManageSubscription': true,
  'showRestore': true,
  'showRefundHelp': true,
  'cancelSurvey': {
    'enabled': true,
    'allowOther': true,
    'options': [
      {'key': 'too_expensive', 'label': 'It is too expensive'},
      {'key': 'not_using', 'label': 'I do not use it enough'},
      {'key': 'missing_feature', 'label': 'It is missing a feature I need'},
      {'key': 'technical_problems', 'label': 'It has technical problems'},
    ],
  },
  'retention': [
    {'productIdentifier': 'pro_monthly', 'offerIdentifier': 'stay_50'},
  ],
  'strings': {
    'en': {
      'title': 'Manage your subscription',
      'survey_title': 'Why are you leaving?',
      'retention_title': 'Before you go',
      'refund_help': "Need a refund? Open the store's own page.",
    },
    'de': {
      'title': 'Abo verwalten',
      'survey_title': 'Warum gehst du?',
      'retention_title': 'Bevor du gehst',
      'refund_help': 'Erstattung noetig? Oeffne die Seite des Stores.',
    },
  },
};

Map<String, Object?> retentionOfferJson({String identifier = 'stay_50'}) => {
  'identifier': identifier,
  'kind': 'promotional',
  'displayName': '50 percent off for three months',
  'appleOfferIdentifier': 'stay50',
  'googleOfferId': 'stay50',
  'eligibility': 'existing_subscriber',
  'isDefault': false,
};

Map<String, Object?> centerJson({
  bool enabled = true,
  Map<String, Object?>? config,
  Map<String, String>? managementUrls,
  List<Map<String, Object?>> offers = const [],
}) => {
  'enabled': enabled,
  'config': config ?? sampleCenterConfig(),
  'managementUrls':
      managementUrls ?? {'pro_monthly': 'https://apps.apple.com/account/subscriptions'},
  'eligibleRetentionOffers': offers,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('models', () {
    test('the sample config parses field for field', () {
      final view = CustomerCenterView.fromJson(centerJson(offers: [retentionOfferJson()]));
      expect(view.enabled, isTrue);
      final config = view.config;
      expect(config.supportEmail, 'support@example.com');
      expect(config.supportUrl, 'https://example.com/support');
      expect(config.showManageSubscription, isTrue);
      expect(config.showRestore, isTrue);
      expect(config.showRefundHelp, isTrue);
      expect(config.cancelSurvey.enabled, isTrue);
      expect(config.cancelSurvey.allowOther, isTrue);
      expect(config.cancelSurvey.options.map((o) => o.key), [
        'too_expensive',
        'not_using',
        'missing_feature',
        'technical_problems',
      ]);
      expect(config.cancelSurvey.options.first.label, 'It is too expensive');
      expect(config.retention.single.productIdentifier, 'pro_monthly');
      expect(config.retention.single.offerIdentifier, 'stay_50');
      expect(config.strings.keys, containsAll(['en', 'de']));
      expect(view.managementUrls, {'pro_monthly': 'https://apps.apple.com/account/subscriptions'});
      expect(view.eligibleRetentionOffers.single.identifier, 'stay_50');
      expect(view.eligibleRetentionOffers.single.kind, OfferKind.promotional);
    });

    test('a disabled view with the inert config shows nothing and parses', () {
      final view = CustomerCenterView.fromJson({
        'enabled': false,
        'config': {
          'version': 1,
          'supportEmail': null,
          'supportUrl': null,
          'showManageSubscription': false,
          'showRestore': false,
          'showRefundHelp': false,
          'cancelSurvey': {'enabled': false, 'allowOther': false, 'options': <Object?>[]},
          'retention': <Object?>[],
          'strings': <String, Object?>{},
        },
        'managementUrls': <String, Object?>{},
        'eligibleRetentionOffers': <Object?>[],
      });
      expect(view.enabled, isFalse);
      expect(view.config.cancelSurvey.isUsable, isFalse);
      expect(view.config.retention, isEmpty);
    });

    test('an unreadable shape never throws and leaves everything off', () {
      final view = CustomerCenterView.fromJson({
        'enabled': 'yes',
        'config': [1, 2],
        'managementUrls': {'a': 1, 'b': 'https://x.test'},
        'eligibleRetentionOffers': [
          {'displayName': 'no identifier'},
          'junk',
          retentionOfferJson(),
        ],
      });
      expect(view.enabled, isFalse);
      expect(view.config.showRestore, isFalse);
      expect(view.config.supportEmail, isNull);
      expect(view.managementUrls, {'b': 'https://x.test'});
      expect(view.eligibleRetentionOffers.map((o) => o.identifier), ['stay_50']);
    });

    test('a survey with only allowOther is usable, a survey with nothing is not', () {
      expect(
        CancelSurvey.fromJson({'enabled': true, 'allowOther': true, 'options': <Object?>[]})
            .isUsable,
        isTrue,
      );
      expect(
        CancelSurvey.fromJson({'enabled': true, 'allowOther': false, 'options': <Object?>[]})
            .isUsable,
        isFalse,
      );
      expect(
        CancelSurvey.fromJson({
          'enabled': false,
          'options': [
            {'key': 'a', 'label': 'A'},
          ],
        }).isUsable,
        isFalse,
      );
    });
  });

  group('strings', () {
    final config = CustomerCenterConfig.fromJson(sampleCenterConfig());

    test('every label of the screen has a built in English text', () {
      final strings = CustomerCenterStrings(const CustomerCenterConfig(), const [Locale('en')]);
      const keys = [
        CustomerCenterStringKey.title,
        CustomerCenterStringKey.summaryTitle,
        CustomerCenterStringKey.noAccess,
        CustomerCenterStringKey.subscriptionsTitle,
        CustomerCenterStringKey.renewsOn,
        CustomerCenterStringKey.endsOn,
        CustomerCenterStringKey.billingIssue,
        CustomerCenterStringKey.billedBy,
        CustomerCenterStringKey.storeAppStore,
        CustomerCenterStringKey.storePlayStore,
        CustomerCenterStringKey.manage,
        CustomerCenterStringKey.manageUnavailable,
        CustomerCenterStringKey.restore,
        CustomerCenterStringKey.restoreDone,
        CustomerCenterStringKey.restoreFailed,
        CustomerCenterStringKey.refundHelp,
        CustomerCenterStringKey.refundHelpWhich,
        CustomerCenterStringKey.contactSupport,
        CustomerCenterStringKey.cancel,
        CustomerCenterStringKey.surveyTitle,
        CustomerCenterStringKey.surveyOther,
        CustomerCenterStringKey.surveyOtherHint,
        CustomerCenterStringKey.surveyContinue,
        CustomerCenterStringKey.retentionTitle,
        CustomerCenterStringKey.retentionAccept,
        CustomerCenterStringKey.retentionDecline,
        CustomerCenterStringKey.retentionApplied,
        CustomerCenterStringKey.cancelInStore,
        CustomerCenterStringKey.close,
        CustomerCenterStringKey.retry,
        CustomerCenterStringKey.loading,
        CustomerCenterStringKey.errorGeneric,
        CustomerCenterStringKey.chooseSubscription,
      ];
      for (final key in keys) {
        expect(customerCenterEnglish[key], isNotNull, reason: key);
        expect(strings.lookup(key), isNotEmpty, reason: key);
        expect(strings(key), isNot(key), reason: 'a label never shows its key');
      }
    });

    test(
      'the device language wins, a missing key falls back to the config English, then built in',
      () {
        expect(CustomerCenterStrings(config, const [Locale('de')])('title'), 'Abo verwalten');
        // The de table has no restore key, the config has no English restore either: built in English.
        expect(CustomerCenterStrings(config, const [Locale('de')])('restore'), 'Restore purchases');
        expect(
          CustomerCenterStrings(config, const [Locale('de', 'AT')])('survey_title'),
          'Warum gehst du?',
          reason: 'de-AT falls back to the de table',
        );
      },
    );

    test('a language with no table uses the config English, then the built in English', () {
      final fr = CustomerCenterStrings(config, const [Locale('fr')]);
      expect(fr('survey_title'), 'Why are you leaving?');
      expect(fr('cancel_subscription'), 'Cancel subscription');
      final bare = CustomerCenterStrings(
        const CustomerCenterConfig(
          strings: {
            'de': {'title': 'Abo'},
          },
        ),
        const [Locale('fr')],
      );
      expect(bare('title'), 'Manage your subscription');
    });

    test('locale tags match without regard to case or underscore, the first device language with a table wins', () {
      final cfg = CustomerCenterConfig.fromJson({
        'strings': {
          'pt_BR': {'title': 'Gerenciar'},
          'es': {'title': 'Gestionar'},
        },
      });
      expect(CustomerCenterStrings(cfg, const [Locale('pt', 'br')])('title'), 'Gerenciar');
      expect(
        CustomerCenterStrings(cfg, const [Locale('ja'), Locale('es', 'MX')])('title'),
        'Gestionar',
      );
    });

    test('placeholders are filled and an unknown key is shown as itself, never a crash', () {
      final strings = CustomerCenterStrings(config, const [Locale('en')]);
      expect(strings('renews_on', args: {'date': 'Dec 1, 2026'}), 'Renews on Dec 1, 2026');
      expect(strings('renews_on'), 'Renews on {date}');
      expect(strings('no_such_key'), 'no_such_key');
    });
  });

  group('Gemicore.getCustomerCenter and sendCancelFeedback', () {
    late Harness h;

    setUp(() {
      h = Harness();
      h.transport.json('GET', '/v1/purchases/customer-center', centerJson());
    });

    tearDown(() async {
      if (Gemicore.isConfigured) await Gemicore.instance.close();
    });

    test('getCustomerCenter reads the route with the customer token', () async {
      final sdk = await h.configure();
      final view = await sdk.getCustomerCenter();
      expect(view.enabled, isTrue);
      final request = h.transport.calls('GET', '/v1/purchases/customer-center').single;
      expect(request.headers['x-customer-token'], 'tok_1');
    });

    test('sendCancelFeedback posts the body the server validates', () async {
      h.transport.json('POST', '/v1/purchases/customer-center/feedback', {
        'id': 'f1',
        'purchaseId': 'p1',
        'reasonKey': 'other',
        'reasonText': 'too many ads',
        'offerShown': 'stay_50',
        'offerAccepted': true,
        'createdAt': '2026-11-07T10:00:00.000Z',
      }, status: 201);
      final sdk = await h.configure();
      await sdk.sendCancelFeedback(
        reasonKey: 'other',
        reasonText: '  too many ads ',
        purchaseId: 'p1',
        offerShown: 'stay_50',
        offerAccepted: true,
      );
      expect(h.transport.calls('POST', '/v1/purchases/customer-center/feedback').single.json, {
        'reasonKey': 'other',
        'reasonText': 'too many ads',
        'purchaseId': 'p1',
        'offerShown': 'stay_50',
        'offerAccepted': true,
      });
    });

    test('an empty text and absent optional fields are left out of the body', () async {
      h.transport.json('POST', '/v1/purchases/customer-center/feedback', {}, status: 201);
      final sdk = await h.configure();
      await sdk.sendCancelFeedback(reasonKey: 'too_expensive', reasonText: '   ');
      expect(h.transport.calls('POST', '/v1/purchases/customer-center/feedback').single.json, {
        'reasonKey': 'too_expensive',
        'offerAccepted': false,
      });
    });

    test('a server refusal is a typed error', () async {
      h.transport.json('POST', '/v1/purchases/customer-center/feedback', {
        'error': {
          'code': 'VALIDATION_ERROR',
          'message': 'reasonKey is not one of the configured answers',
        },
      }, status: 422);
      final sdk = await h.configure();
      await expectLater(
        sdk.sendCancelFeedback(reasonKey: 'nope'),
        throwsA(isA<GemicoreException>().having((e) => e.statusCode, 'status', 422)),
      );
    });
  });
}
