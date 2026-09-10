import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_exception.dart';

/// HTTP client for the Roamio backend (Firebase Cloud Functions).
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
    connectTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 90),
    contentType: 'application/json',
  ));

  Future<String?> _idToken() async {
    try {
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;
      return user.getIdToken();
    } catch (_) {
      return null;
    }
  }

  /// POST a JSON body and decode the JSON object response.
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final String? token = await _idToken();
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(
          headers: <String, Object?>{
            'Authorization': 'Bearer $token',
          },
        ),
      );
      final dynamic data = resp.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) {
        return data.map((Object? k, Object? v) => MapEntry(k.toString(), v));
      }
      throw ApiException(ApiErrorKind.server, 'Unexpected response from backend.');
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  /// GET a binary response (used for Places photos proxied by the backend).
  Future<Uint8List> getBytes(String path) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      final dynamic data = resp.data;
      if (data is Uint8List) return data;
      throw ApiException(ApiErrorKind.server, 'Unexpected binary response.');
    } on DioException catch (e) {
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
            'The Roamio backend did not respond in time. Check your connection and try again.');
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
            msg ?? 'The Roamio backend returned an error (${code ?? 'unknown'}).',
            statusCode: code,
            details: details);
      case DioExceptionType.unknown:
        return ApiException(
            ApiErrorKind.unknown,
            msg ?? 'Something went wrong while contacting the backend.');
    }
  }
}
