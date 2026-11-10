/// Shows the Apple Pay or Google Pay sheet for a card payment. The core package only defines this
/// interface so it stays free of a payment SDK; the gemicore_flutter_stripe package implements it
/// on the Stripe payment sheet.
abstract class NativePaySheet {
  /// Presents the sheet and completes when the customer has paid, closed it or the payment failed.
  /// The payment itself settles on the server; the SDK waits for that after a completed result.
  Future<NativePayResult> present(NativePayRequest request);
}

/// What the sheet needs, all from the server except [testEnvironment], which follows the API key.
class NativePayRequest {
  const NativePayRequest({
    required this.clientSecret,
    required this.publishableKey,
    required this.merchantCountryCode,
    required this.currencyCode,
    required this.amount,
    required this.productName,
    required this.testEnvironment,
    this.applePayMerchantId,
    this.merchantDisplayName = '',
  });

  /// The payment intent's client secret. A secret: never log it.
  final String clientSecret;

  /// The app's Stripe publishable key.
  final String publishableKey;

  /// Two letter country of the Stripe account, for the Apple Pay and Google Pay sheets.
  final String merchantCountryCode;

  /// Null when the dashboard has no Apple Pay merchant id; Google Pay does not need one.
  final String? applePayMerchantId;

  /// ISO 4217 currency code of [amount].
  final String currencyCode;

  /// The price in minor units (cents), for the sheet's total line. The charge is the server's price.
  final int amount;

  final String productName;

  /// The business name the sheet shows, from the server (the app's name). Empty when the server
  /// did not send one; implementations then fall back to [productName].
  final String merchantDisplayName;

  /// True with a pk_test_ key, so the sheet uses Google Pay's test environment.
  final bool testEnvironment;
}

enum NativePayOutcome { completed, canceled, failed }

class NativePayResult {
  const NativePayResult({required this.outcome, this.message});

  const NativePayResult.completed() : this(outcome: NativePayOutcome.completed);

  const NativePayResult.canceled() : this(outcome: NativePayOutcome.canceled);

  const NativePayResult.failed([String? message])
    : this(outcome: NativePayOutcome.failed, message: message);

  final NativePayOutcome outcome;

  /// A reason for a failure, already safe to show or log.
  final String? message;
}
