import 'package:flutter_stripe/flutter_stripe.dart';

/// The few Stripe calls the sheet makes, behind an interface so tests run without the platform
/// channel that the static [Stripe] API needs.
abstract interface class StripePaymentSheetApi {
  /// Sets the keys the next sheet uses. [merchantIdentifier] is null when Apple Pay is not set up.
  void configure({required String publishableKey, String? merchantIdentifier});

  Future<void> initPaymentSheet(SetupPaymentSheetParameters parameters);

  /// Completes when the payment is confirmed; throws [StripeException] when it is closed or fails.
  Future<void> presentPaymentSheet();
}

/// The real thing, on the static [Stripe] API.
class StripeStaticApi implements StripePaymentSheetApi {
  const StripeStaticApi();

  @override
  void configure({required String publishableKey, String? merchantIdentifier}) {
    Stripe.publishableKey = publishableKey;
    Stripe.merchantIdentifier = merchantIdentifier;
  }

  @override
  Future<void> initPaymentSheet(SetupPaymentSheetParameters parameters) async {
    await Stripe.instance.initPaymentSheet(paymentSheetParameters: parameters);
  }

  @override
  Future<void> presentPaymentSheet() async {
    await Stripe.instance.presentPaymentSheet();
  }
}
