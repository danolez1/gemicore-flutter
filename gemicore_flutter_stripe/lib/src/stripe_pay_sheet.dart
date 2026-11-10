import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'stripe_api.dart';

/// Apple Pay and Google Pay inside the app, on the Stripe payment sheet. Pass it to
/// `Gemicore.configure(nativePaySheet: GemicoreStripePaySheet())`.
///
/// The sheet only confirms the payment with Stripe. The server prices the intent and settles the
/// purchase, and the core SDK waits for that after a completed result.
class GemicoreStripePaySheet implements NativePaySheet {
  /// [api] is for tests; the default talks to the Stripe plugin.
  GemicoreStripePaySheet({StripePaymentSheetApi api = const StripeStaticApi()}) : _api = api;

  final StripePaymentSheetApi _api;

  @override
  Future<NativePayResult> present(NativePayRequest request) async {
    try {
      // Stripe asserts a merchant id whenever Apple Pay is offered, so Apple Pay is left out without one.
      final applePayMerchantId = request.applePayMerchantId;
      final applePay = applePayMerchantId == null || applePayMerchantId.isEmpty
          ? null
          : PaymentSheetApplePay(merchantCountryCode: request.merchantCountryCode);
      _api.configure(
        publishableKey: request.publishableKey,
        merchantIdentifier: applePay == null ? null : applePayMerchantId,
      );
      // The sheet's total comes from the payment intent, so request.amount is not passed on.
      await _api.initPaymentSheet(
        SetupPaymentSheetParameters(
          paymentIntentClientSecret: request.clientSecret,
          // The server sends the app's name; an older server sends none, so the product name stands in.
          merchantDisplayName: request.merchantDisplayName.isEmpty
              ? request.productName
              : request.merchantDisplayName,
          applePay: applePay,
          googlePay: PaymentSheetGooglePay(
            merchantCountryCode: request.merchantCountryCode,
            currencyCode: request.currencyCode,
            testEnv: request.testEnvironment,
          ),
        ),
      );
      await _api.presentPaymentSheet();
      return const NativePayResult.completed();
    } on StripeException catch (error) {
      if (error.error.code == FailureCode.Canceled) return const NativePayResult.canceled();
      return NativePayResult.failed(_describe(error));
    } catch (error) {
      // Only the type: a plugin or platform error can quote the request, client secret included.
      return NativePayResult.failed(
        'The Stripe payment sheet failed (${error.runtimeType}). Check the native setup in the '
        'gemicore_flutter_stripe README.',
      );
    }
  }

  // Stripe's own message can echo the client secret ("No such payment_intent"), so only short codes go in.
  static String _describe(StripeException error) {
    final detail = error.error;
    final parts = <String>[
      detail.code.name,
      ?_safeCode(detail.stripeErrorCode),
      ?_safeCode(detail.declineCode),
    ];
    return 'The Stripe payment sheet failed (${parts.join(', ')}).';
  }

  static final _codePattern = RegExp(r'^[a-z0-9_]{1,40}$');

  static String? _safeCode(String? value) =>
      value != null && _codePattern.hasMatch(value) && !value.contains('secret') ? value : null;
}
