/// Error codes the purchases API answers with, from packages/contracts/src/purchases.ts.
abstract final class GemicoreErrorCode {
  static const customerTokenInvalid = 'PURCHASE_CUSTOMER_TOKEN_INVALID';
  static const storeNotConfigured = 'PURCHASE_STORE_NOT_CONFIGURED';
  static const verificationFailed = 'PURCHASE_VERIFICATION_FAILED';
  static const productUnknown = 'PURCHASE_PRODUCT_UNKNOWN';
  static const notForCard = 'PURCHASE_NOT_FOR_CARD';
  static const testStoreLive = 'PURCHASE_TEST_STORE_LIVE';
  static const storeUnavailable = 'PURCHASE_STORE_UNAVAILABLE';
  static const offerUnknown = 'PURCHASE_OFFER_UNKNOWN';
  static const notEligible = 'PURCHASE_NOT_ELIGIBLE';
  static const paywallInvalid = 'PURCHASE_PAYWALL_INVALID';
  static const identityUnverified = 'PURCHASE_IDENTITY_UNVERIFIED';

  /// The server refused customer attributes (details.reason says why; details.field names the key).
  static const attributesInvalid = 'PURCHASE_ATTRIBUTES_INVALID';

  // Codes this SDK raises itself.
  static const notConfigured = 'SDK_NOT_CONFIGURED';
  static const network = 'SDK_NETWORK_ERROR';
  static const invalidResponse = 'SDK_INVALID_RESPONSE';
  static const storeError = 'SDK_STORE_ERROR';
  static const purchaseInProgress = 'SDK_PURCHASE_IN_PROGRESS';
  static const checkoutTimeout = 'SDK_CHECKOUT_TIMEOUT';
  static const productNotAvailable = 'SDK_PRODUCT_NOT_AVAILABLE';
  static const offerNotSupported = 'SDK_OFFER_NOT_SUPPORTED';
  static const paywallNotAvailable = 'SDK_PAYWALL_NOT_AVAILABLE';
  static const nativePayNotConfigured = 'SDK_NATIVE_PAY_NOT_CONFIGURED';
  static const nativePayFailed = 'SDK_NATIVE_PAY_FAILED';
  static const paymentFailed = 'SDK_PAYMENT_FAILED';

  /// Attributes that break the server limits, found before any request was sent.
  static const invalidAttributes = 'SDK_INVALID_ATTRIBUTES';

  /// The server answered PURCHASE_NOT_FOR_CARD with reason card_sale_kind_missing: the product has a
  /// card price but was never declared as physical goods or a real world service.
  static const cardSaleNotDeclared = 'SDK_CARD_SALE_NOT_DECLARED';
}

/// Every failure the SDK reports. [code] is the API's error code, or an SDK_ code for local failures.
class GemicoreException implements Exception {
  const GemicoreException(this.code, this.message, {this.statusCode, this.details = const {}});

  /// Parses the API error body `{ "error": { "code", "message", "details" } }`.
  factory GemicoreException.fromResponse(int statusCode, Object? body) {
    final error = body is Map ? body['error'] : null;
    if (error is Map) {
      final code = error['code'];
      final message = error['message'];
      final details = error['details'];
      final detailMap = details is Map
          ? details.cast<String, Object?>()
          : const <String, Object?>{};
      if (code == GemicoreErrorCode.notForCard && detailMap['reason'] == 'card_sale_kind_missing') {
        final productId = detailMap['productId'];
        return GemicoreException(
          GemicoreErrorCode.cardSaleNotDeclared,
          '${productId is String ? productId : 'This product'} has a card price but no card sale '
          'declaration. In the Gemicore dashboard, declare the product as physical goods or a real '
          'world service. Digital goods must be bought with purchase(), through the store.',
          statusCode: statusCode,
          details: detailMap,
        );
      }
      return GemicoreException(
        code is String ? code : GemicoreErrorCode.invalidResponse,
        message is String ? message : 'Request failed with status $statusCode',
        statusCode: statusCode,
        details: detailMap,
      );
    }
    return GemicoreException(
      GemicoreErrorCode.invalidResponse,
      'Request failed with status $statusCode',
      statusCode: statusCode,
    );
  }

  final String code;
  final String message;

  /// The HTTP status, or null for a failure that never reached the server.
  final int? statusCode;
  final Map<String, Object?> details;

  /// True when retrying later may succeed (network trouble, rate limits, server errors).
  bool get isRetryable =>
      statusCode == null && code == GemicoreErrorCode.network ||
      statusCode == 429 ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() =>
      'GemicoreException($code${statusCode != null ? ', $statusCode' : ''}): $message';
}
