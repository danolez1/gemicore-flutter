import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

// Built at run time so no literal looks like a real Stripe client secret to the secret scanner.
final _intentValue = ['pi_3Abc', 'secret', 'Zyx9'].join('_');

class _FakeStripe implements StripePaymentSheetApi {
  _FakeStripe({this.initError, this.presentError});

  final Object? initError;
  final Object? presentError;
  final List<String> calls = [];
  String? publishableKey;
  String? merchantIdentifier;
  SetupPaymentSheetParameters? parameters;

  @override
  void configure({required String publishableKey, String? merchantIdentifier}) {
    calls.add('configure');
    this.publishableKey = publishableKey;
    this.merchantIdentifier = merchantIdentifier;
  }

  @override
  Future<void> initPaymentSheet(SetupPaymentSheetParameters parameters) async {
    calls.add('init');
    this.parameters = parameters;
    if (initError != null) throw initError!;
  }

  @override
  Future<void> presentPaymentSheet() async {
    calls.add('present');
    if (presentError != null) throw presentError!;
  }
}

NativePayRequest _request({
  String? applePayMerchantId = 'merchant.com.example.app',
  bool testEnvironment = true,
  String merchantDisplayName = '',
}) => NativePayRequest(
  clientSecret: _intentValue,
  publishableKey: 'pk_test_abc',
  merchantCountryCode: 'DE',
  applePayMerchantId: applePayMerchantId,
  currencyCode: 'EUR',
  amount: 1999,
  productName: 'Print poster',
  merchantDisplayName: merchantDisplayName,
  testEnvironment: testEnvironment,
);

StripeException _stripeError(
  FailureCode code, {
  String? message,
  String? localizedMessage,
  String? stripeErrorCode,
  String? declineCode,
}) => StripeException(
  error: LocalizedErrorMessage(
    code: code,
    message: message,
    localizedMessage: localizedMessage,
    stripeErrorCode: stripeErrorCode,
    declineCode: declineCode,
  ),
);

void main() {
  group('outcomes', () {
    test('a confirmed payment is completed', () async {
      final fake = _FakeStripe();
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.completed);
      expect(result.message, isNull);
      expect(fake.calls, ['configure', 'init', 'present']);
    });

    test('a closed sheet is canceled', () async {
      final fake = _FakeStripe(presentError: _stripeError(FailureCode.Canceled));
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.canceled);
      expect(result.message, isNull);
    });

    test('a Stripe failure is failed, with the codes and nothing else', () async {
      final fake = _FakeStripe(
        presentError: _stripeError(
          FailureCode.Failed,
          stripeErrorCode: 'card_declined',
          declineCode: 'insufficient_funds',
        ),
      );
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.failed);
      expect(result.message, contains('Failed'));
      expect(result.message, contains('card_declined'));
      expect(result.message, contains('insufficient_funds'));
    });

    test('timeout and unknown Stripe codes are failed, not canceled', () async {
      for (final code in [FailureCode.Timeout, FailureCode.Unknown]) {
        final fake = _FakeStripe(presentError: _stripeError(code));
        final result = await GemicoreStripePaySheet(api: fake).present(_request());
        expect(result.outcome, NativePayOutcome.failed, reason: code.name);
      }
    });

    test('a cancel while the sheet is being set up is also canceled', () async {
      final fake = _FakeStripe(initError: _stripeError(FailureCode.Canceled));
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.canceled);
      expect(fake.calls, ['configure', 'init']);
    });

    test('a platform error is failed with its type and a setup hint', () async {
      final fake = _FakeStripe(
        initError: PlatformException(code: 'x', message: 'boom $_intentValue'),
      );
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.failed);
      expect(result.message, contains('PlatformException'));
      expect(result.message, contains('README'));
    });

    test('any other error is failed, never thrown', () async {
      final fake = _FakeStripe(presentError: StateError('bad state $_intentValue'));
      final result = await GemicoreStripePaySheet(api: fake).present(_request());
      expect(result.outcome, NativePayOutcome.failed);
      expect(result.message, contains('StateError'));
    });
  });

  group('what is passed to Stripe', () {
    test('the keys come from the request', () async {
      final fake = _FakeStripe();
      await GemicoreStripePaySheet(api: fake).present(_request());
      expect(fake.publishableKey, 'pk_test_abc');
      expect(fake.merchantIdentifier, 'merchant.com.example.app');
    });

    test('the sheet shows the merchant name from the server', () async {
      final fake = _FakeStripe();
      await GemicoreStripePaySheet(api: fake).present(_request(merchantDisplayName: 'Poster Shop'));
      expect(fake.parameters!.merchantDisplayName, 'Poster Shop');
    });

    test(
      'the sheet gets the client secret and, without a merchant name, the product name',
      () async {
        final fake = _FakeStripe();
        await GemicoreStripePaySheet(api: fake).present(_request());
        expect(fake.parameters!.paymentIntentClientSecret, _intentValue);
        expect(fake.parameters!.setupIntentClientSecret, isNull);
        expect(fake.parameters!.merchantDisplayName, 'Print poster');
      },
    );

    test('Apple Pay uses the merchant country', () async {
      final fake = _FakeStripe();
      await GemicoreStripePaySheet(api: fake).present(_request());
      expect(fake.parameters!.applePay, isNotNull);
      expect(fake.parameters!.applePay!.merchantCountryCode, 'DE');
    });

    test('Google Pay uses the merchant country, currency and the test flag', () async {
      final fake = _FakeStripe();
      await GemicoreStripePaySheet(api: fake).present(_request());
      final googlePay = fake.parameters!.googlePay!;
      expect(googlePay.merchantCountryCode, 'DE');
      expect(googlePay.currencyCode, 'EUR');
      expect(googlePay.testEnv, isTrue);
    });

    test('a live key turns the Google Pay test environment off', () async {
      final fake = _FakeStripe();
      await GemicoreStripePaySheet(api: fake).present(_request(testEnvironment: false));
      expect(fake.parameters!.googlePay!.testEnv, isFalse);
    });

    test('without an Apple Pay merchant id Apple Pay is left out and Google Pay stays', () async {
      for (final id in [null, '']) {
        final fake = _FakeStripe();
        await GemicoreStripePaySheet(api: fake).present(_request(applePayMerchantId: id));
        expect(fake.parameters!.applePay, isNull, reason: 'id: $id');
        expect(fake.parameters!.googlePay, isNotNull);
        expect(fake.merchantIdentifier, isNull);
      }
    });

    test('the merchant id from an earlier request does not stay behind', () async {
      final fake = _FakeStripe();
      final sheet = GemicoreStripePaySheet(api: fake);
      await sheet.present(_request());
      await sheet.present(_request(applePayMerchantId: null));
      expect(fake.merchantIdentifier, isNull);
    });
  });

  group('secrets', () {
    test('the client secret is in no failure message', () async {
      final errors = <Object>[
        _stripeError(
          FailureCode.Failed,
          message: 'No such payment_intent: $_intentValue',
          localizedMessage: 'No such payment_intent: $_intentValue',
          stripeErrorCode: 'resource_missing',
        ),
        // A hostile or buggy code field that carries the secret is dropped, not echoed.
        _stripeError(FailureCode.Failed, stripeErrorCode: _intentValue, declineCode: _intentValue),
        PlatformException(code: _intentValue, message: _intentValue, details: _intentValue),
        StateError(_intentValue),
        Exception(_intentValue),
      ];
      for (final error in errors) {
        for (final phase in ['init', 'present']) {
          final fake = phase == 'init'
              ? _FakeStripe(initError: error)
              : _FakeStripe(presentError: error);
          final result = await GemicoreStripePaySheet(api: fake).present(_request());
          expect(result.outcome, NativePayOutcome.failed);
          expect(result.message, isNotNull);
          expect(result.message, isNot(contains(_intentValue)));
          expect(result.message, isNot(contains('secret')));
          expect(result.message, isNot(contains('pk_test_abc')));
        }
      }
    });

    test('a confirmed or canceled result carries no message at all', () async {
      final ok = await GemicoreStripePaySheet(api: _FakeStripe()).present(_request());
      final canceled = await GemicoreStripePaySheet(
        api: _FakeStripe(presentError: _stripeError(FailureCode.Canceled, message: _intentValue)),
      ).present(_request());
      expect(ok.message, isNull);
      expect(canceled.message, isNull);
    });
  });
}
