import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_exception.dart';

/// HTTP client for the Tourism backend (Firebase Cloud Functions).
///
/// The backend URL is derived from the Firebase project id; no secrets and
/// no third-party endpoints are reachable from this client. Every request
/// carries the Firebase ID token, which the backend verifies with
/// firebase-admin (server-side auth check).
class ApiClient {
  ApiClient({required this.baseUrl});

  final String baseUrl;
  late final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 4),
    sendTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    contentType: 'application/json',
  ));

  // When the backend is unreachable (not deployed yet), remember it for a
  // while so subsequent calls fail instantly instead of waiting on the
  // connect timeout every time — this is what made the app feel slow.
  bool _backendDown = false;
  DateTime? _downSince;

  static const Duration _retryAfter = Duration(seconds: 45);
  static const Duration _tokenReuseWindow = Duration(minutes: 5);

  String? _cachedToken;
  String? _cachedTokenUid;
  DateTime? _tokenFetchedAt;
  Future<String?>? _tokenInFlight;
  String? _tokenInFlightUid;

  bool get _skipBackend {
    final DateTime? since = _downSince;
    if (!_backendDown || since == null) return false;
    return DateTime.now().difference(since) < _retryAfter;
  }

  void _markDown() {
    _backendDown = true;
    _downSince = DateTime.now();
  }

  void _markUp() {
    _backendDown = false;
    _downSince = null;
  }

  Future<String?> _idToken() {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _cachedToken = null;
      _cachedTokenUid = null;
      _tokenFetchedAt = null;
      return Future<String?>.value(null);
    }

    final DateTime? fetchedAt = _tokenFetchedAt;
    if (_cachedTokenUid == user.uid &&
        _cachedToken != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _tokenReuseWindow) {
      return Future<String?>.value(_cachedToken);
    }
    final Future<String?>? pending = _tokenInFlight;
    if (pending != null && _tokenInFlightUid == user.uid) return pending;

    final Future<String?> request = user.getIdToken().then((String? token) {
      // Do not retain a token if the account changed while the asynchronous
      // refresh was running.
      if (FirebaseAuth.instance.currentUser?.uid == user.uid) {
        _cachedToken = token;
        _cachedTokenUid = user.uid;
        _tokenFetchedAt = DateTime.now();
      }
      return token;
    }).catchError((Object _) => null);
    _tokenInFlight = request;
    _tokenInFlightUid = user.uid;
    return request.whenComplete(() {
      if (identical(_tokenInFlight, request)) {
        _tokenInFlight = null;
        _tokenInFlightUid = null;
      }
    });
  }

  /// POST a JSON body and decode the JSON object response.
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (_skipBackend) {
      throw ApiException(
        ApiErrorKind.network,
        'The Tourism backend is not reachable right now.',
        retryable: true,
      );
    }
    final String? token = await _idToken();
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(
          headers: <String, Object?>{
            // Never send "Bearer null": the backend would try to verify it,
            // get no uid and treat the call as an anonymous flood (429).
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      _markUp();
      final dynamic data = resp.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) {
        return data.map((Object? k, Object? v) => MapEntry(k.toString(), v));
      }
      throw ApiException(ApiErrorKind.server, 'Unexpected response from backend.');
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        _markDown();
      }
      throw _map(e);
    }
  }

  /// GET a binary response (used for Places photos proxied by the backend).
  ///
  /// This MUST carry the ID token like [post] does: the backend rate-limits
  /// per uid and rejects an anonymous bucket with 401/429 (`rateLimit(null,
  /// 'placesPhoto')` → 429), so photos used to fail on every single device.
  Future<Uint8List> getBytes(String path) async {
    if (_skipBackend) {
      throw ApiException(ApiErrorKind.network, 'Backend unreachable.');
    }
    final String? token = await _idToken();
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        path,
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, Object?>{
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      _markUp();
      final dynamic data = resp.data;
      if (data is Uint8List) return data;
      throw ApiException(ApiErrorKind.server, 'Unexpected binary response.');
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        _markDown();
      }
      throw _map(e);
    }
  }

  ApiException _map(DioException e) {
    final int? code = e.response?.statusCode;
    final Object? data = e.response?.data;
    String? msg;
    String? details;
    if (data is Map) {
      msg = (data['error'] ?? data['message']) as String?;
      details = data['code'] as String?;
    } else if (data is String && data.isNotEmpty) {
      // Cloud Functions that are NOT deployed return an HTML error page from
      // the hosting/gateway layer. Don't dump raw HTML at the user — explain
      // what's actually wrong.
      final String lower = data.toLowerCase();
      if (lower.contains('<html') || lower.contains('<!doctype html')) {
        return ApiException(
          ApiErrorKind.server,
          'The Tourism backend is not available yet (Cloud Functions are '
          'not deployed for this Firebase project). Deploy it with: '
          '`firebase deploy --only functions`.',
          statusCode: code,
          retryable: true,
        );
      }
      msg = data.length > 300 ? data.substring(0, 300) : data;
    }
    if (code == 401) {
      return ApiException(ApiErrorKind.unauthorized,
          msg ?? 'Your session expired. Please sign in again.',
          statusCode: code, retryable: false);
    }
    if (code == 429) {
      return ApiException(ApiErrorKind.rateLimited,
          msg ?? 'Too many requests — please wait a moment and retry.',
          statusCode: code);
    }
    if (code == 400) {
      return ApiException(ApiErrorKind.validation,
          msg ?? 'The request could not be processed.',
          statusCode: code, retryable: false);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException(ApiErrorKind.timeout,
            'The Tourism backend did not respond in time. Check your connection and try again.');
      case DioExceptionType.connectionError:
        return ApiException(ApiErrorKind.network,
            'No network connection. Check your internet connection and try again.');
      case DioExceptionType.badCertificate:
        return ApiException(ApiErrorKind.unknown,
            'Secure connection check failed. Check your device date/time.');
      case DioExceptionType.cancel:
        return ApiException(ApiErrorKind.unknown, 'Request cancelled.');
      case DioExceptionType.badResponse:
        return ApiException(ApiErrorKind.server,
            msg ?? 'The Tourism backend returned an error (${code ?? 'unknown'}).',
            statusCode: code,
            details: details);
      case DioExceptionType.unknown:
        return ApiException(
            ApiErrorKind.unknown,
            msg ?? 'Something went wrong while contacting the backend.');
    }
  }
}
