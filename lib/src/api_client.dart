import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// The wire routes, from packages/contracts/src/purchases.ts.
abstract final class PurchaseRoute {
  static const prefix = '/v1/purchases';
  static const createCustomer = '$prefix/customers';
  static const login = '$prefix/customers/login';
  static const logout = '$prefix/customers/logout';
  static const customer = '$prefix/customer';
  static const products = '$prefix/products';
  static const record = prefix;
  static const restore = '$prefix/restore';
  static const checkout = '$prefix/checkout';
  static const offerings = '$prefix/offerings';
  static const offers = '$prefix/offers';
  static const applePromotionalOffer = '$prefix/apple/promotional-offer';
  static const appleIntroEligibility = '$prefix/apple/introductory-eligibility';
  static const consumptionConsent = '$prefix/customer/consumption-consent';
  static const checkoutIntent = '$prefix/checkout/intent';
  static const customerAttributes = '$prefix/customer/attributes';
  static const customerCenter = '$prefix/customer-center';
  static const customerCenterFeedback = '$prefix/customer-center/feedback';
}

const customerTokenHeader = 'x-customer-token';
const userTokenHeader = 'x-user-token';
const platformHeader = 'x-gemicore-platform';
const appVersionHeader = 'x-gemicore-app-version';
const countryHeader = 'x-gemicore-country';

/// The smallest HTTP surface the SDK needs, so tests can answer without a server.
abstract interface class GemicoreTransport {
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  });
}

class TransportResponse {
  const TransportResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class HttpTransport implements GemicoreTransport {
  HttpTransport({http.Client? client, this.timeout = const Duration(seconds: 30)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await _client.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed).timeout(timeout);
    return TransportResponse(response.statusCode, response.body);
  }
}

/// Talks to the Gemicore purchases API with the app key, the device's customer token and the platform.
class GemicoreApiClient {
  GemicoreApiClient({
    required this.apiKey,
    required this.baseUrl,
    required this.platform,
    required this.transport,
    this.sdkVersion = '0.3.0',
    this.appVersion,
    this.countryCode,
  });

  final String apiKey;
  final Uri baseUrl;
  final String platform;
  final GemicoreTransport transport;
  final String sdkVersion;

  /// The host app's version, sent so placements can target by it. Null leaves the header out.
  ///
  /// Not final: the platform lookup runs in the background and sets it when it answers, so it never
  /// holds configure.
  String? appVersion;

  /// Read on every call because the device language can change while the app runs. A null or
  /// malformed answer leaves the header out.
  final String? Function()? countryCode;

  /// Set after configure; every call after that carries it.
  String? customerToken;

  Future<Map<String, Object?>> get(String path, {Map<String, String>? query}) =>
      _call('GET', path, query: query);

  /// [userToken] is the app user's Gemicore access token; only the calls that name a user carry it.
  Future<Map<String, Object?>> post(String path, [Map<String, Object?>? body, String? userToken]) =>
      _call('POST', path, body: body ?? const {}, userToken: userToken);

  Future<Map<String, Object?>> put(String path, Map<String, Object?> body) =>
      _call('PUT', path, body: body);

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    String? userToken,
  }) async {
    final url = baseUrl.replace(
      path: '${baseUrl.path.replaceAll(RegExp(r'/+$'), '')}$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    final country = _validCountry(countryCode?.call());
    final headers = <String, String>{
      'authorization': 'Bearer $apiKey',
      'accept': 'application/json',
      platformHeader: platform,
      appVersionHeader: ?appVersion,
      countryHeader: ?country,
      'x-gemicore-sdk': 'flutter/$sdkVersion',
      customerTokenHeader: ?customerToken,
      userTokenHeader: ?userToken,
      if (body != null) 'content-type': 'application/json',
    };
    final TransportResponse response;
    try {
      response = await transport.send(
        method,
        url,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
    } on GemicoreException {
      rethrow;
    } catch (error) {
      // The message can carry the URL and nothing secret, but the key never goes into it.
      throw GemicoreException(
        GemicoreErrorCode.network,
        'Network request failed: ${error.runtimeType}',
      );
    }
    Object? decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        decoded = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GemicoreException.fromResponse(response.statusCode, decoded);
    }
    if (decoded is! Map) {
      throw GemicoreException(
        GemicoreErrorCode.invalidResponse,
        'Expected a JSON object from $path',
        statusCode: response.statusCode,
      );
    }
    return decoded.cast<String, Object?>();
  }
}

// The server keeps only two letters; a region such as the 419 of es-419 is not a country.
String? _validCountry(String? code) =>
    code != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(code) ? code.toUpperCase() : null;
