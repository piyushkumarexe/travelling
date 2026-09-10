/// Typed errors thrown by [ApiClient] so UI layers can render
/// meaningful, honest error states (no fake "network hiccup" text).
library;

enum ApiErrorKind {
  network,
  timeout,
  unauthorized,
  rateLimited,
  validation,
  upstream,
  server,
  unknown,
}

class ApiException implements Exception {
  ApiException(this.kind, this.message,
      {this.statusCode, this.retryable = true, this.details});

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  final bool retryable;
  final String? details;

  bool get isConfiguredMissing =>
      details != null && details!.contains('not_configured');

  @override
  String toString() => message;
}
