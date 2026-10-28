import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_exception.dart';

/// Authenticated HTTP client for Tourism Cloud Functions. No third-party
/// provider credentials are accepted or retained by this client.
class ApiClient {
  ApiClient({required this.baseUrl});

  final String baseUrl;
  late final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 6),
    sendTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    contentType: 'application/json',
  ));

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

  void _clearToken() {
    _cachedToken = null;
    _cachedTokenUid = null;
    _tokenFetchedAt = null;
  }

  Future<String?> _idToken({bool forceRefresh = false}) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _clearToken();
      return Future<String?>.value(null);
    }
    if (forceRefresh) _clearToken();
    final DateTime? fetchedAt = _tokenFetchedAt;
    if (_cachedTokenUid == user.uid &&
        _cachedToken != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _tokenReuseWindow) {
      return Future<String?>.value(_cachedToken);
    }
    final Future<String?>? pending = _tokenInFlight;
    if (!forceRefresh && pending != null && _tokenInFlightUid == user.uid) {
      return pending;
    }
    final Future<String?> request = user.getIdToken(forceRefresh).then((token) {
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

  Future<String> _requireToken({bool forceRefresh = false}) async {
    final String? token = await _idToken(forceRefresh: forceRefresh);
    if (token == null || token.isEmpty) {
      throw ApiException(
        ApiErrorKind.unauthorized,
        'Your sign-in session is unavailable. Please sign in again.',
        retryable: false,
      );
    }
    return token;
  }

  void _checkConfigured() {
    if (baseUrl.trim().isEmpty) {
      throw ApiException(
        ApiErrorKind.server,
        'The Tourism backend is not configured for this Firebase project.',
        retryable: false,
      );
    }
    if (_skipBackend) {
      throw ApiException(
        ApiErrorKind.network,
        'The Tourism backend is temporarily unreachable. Retry shortly.',
      );
    }
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    Duration? receiveTimeout,
  }) async {
    _checkConfigured();
    return _post(path, body, receiveTimeout, true);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
    Duration? receiveTimeout,
    bool refreshOnUnauthorized,
  ) async {
    final String token = await _requireToken(forceRefresh: !refreshOnUnauthorized);
    try {
      final Response<dynamic> response = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(
          receiveTimeout: receiveTimeout,
          headers: <String, Object?>{'Authorization': 'Bearer $token'},
        ),
      );
      _markUp();
      final dynamic data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) {
        return data.map((key, value) => MapEntry(key.toString(), value));
      }
      throw ApiException(ApiErrorKind.server, 'Unexpected response from backend.');
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 && refreshOnUnauthorized) {
        _clearToken();
        return _post(path, body, receiveTimeout, false);
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.connectionError) {
        _markDown();
      }
      throw _map(error);
    }
  }

  Future<Uint8List> getBytes(String path) async {
    _checkConfigured();
    return _getBytes(path, true);
  }

  Future<Uint8List> _getBytes(String path, bool refreshOnUnauthorized) async {
    final String token = await _requireToken(forceRefresh: !refreshOnUnauthorized);
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(
        path,
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, Object?>{'Authorization': 'Bearer $token'},
        ),
      );
      _markUp();
      final dynamic data = response.data;
      if (data is Uint8List) return data;
      throw ApiException(ApiErrorKind.server, 'Unexpected binary response.');
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 && refreshOnUnauthorized) {
        _clearToken();
        return _getBytes(path, false);
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.connectionError) {
        _markDown();
      }
      throw _map(error);
    }
  }

  ApiException _map(DioException error) {
    final int? code = error.response?.statusCode;
    final dynamic data = error.response?.data;
    String? message;
    String? details;
    if (data is Map) {
      final Object? candidate = data['error'] ?? data['message'];
      if (candidate is String && candidate.length <= 500) message = candidate;
      final Object? codeCandidate = data['code'];
      if (codeCandidate is String && codeCandidate.length <= 100) {
        details = codeCandidate;
      }
    } else if (data is String && data.isNotEmpty) {
      final String lower = data.toLowerCase();
      if (lower.contains('<html') || lower.contains('<!doctype html')) {
        message = 'The Tourism backend is not deployed for this Firebase project.';
      } else {
        // Never reflect arbitrary proxy/provider text into production UI.
        message = 'The backend returned an unreadable error response.';
      }
    }
    if (code == 401) {
      return ApiException(ApiErrorKind.unauthorized,
          message ?? 'Your session expired. Please sign in again.',
          statusCode: code, retryable: false);
    }
    if (code == 429) {
      return ApiException(ApiErrorKind.rateLimited,
          message ?? 'Too many requests. Please wait and try again.',
          statusCode: code, retryable: false);
    }
    if (code == 400 || code == 413) {
      return ApiException(ApiErrorKind.validation,
          message ?? 'The request could not be processed.',
          statusCode: code, retryable: false);
    }
    if (code == 502 || code == 504) {
      return ApiException(ApiErrorKind.upstream,
          message ?? 'An upstream service is temporarily unavailable.',
          statusCode: code, details: details);
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException(ApiErrorKind.timeout,
            'The Tourism backend did not respond in time. Please retry.');
      case DioExceptionType.connectionError:
        return ApiException(ApiErrorKind.network,
            'No network connection. Check your connection and retry.');
      case DioExceptionType.badCertificate:
        return ApiException(ApiErrorKind.unknown,
            'Secure connection check failed. Check the device date and time.',
            retryable: false);
      case DioExceptionType.cancel:
        return ApiException(ApiErrorKind.unknown, 'Request cancelled.',
            retryable: false);
      case DioExceptionType.badResponse:
        return ApiException(ApiErrorKind.server,
            message ?? 'The backend returned an error (${code ?? 'unknown'}).',
            statusCode: code, details: details, retryable: code != 503);
      case DioExceptionType.unknown:
        return ApiException(ApiErrorKind.unknown,
            message ?? 'Something went wrong while contacting the backend.');
    }
  }
}
