import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Keyless AI fallback via Pollinations.ai (OpenAI-compatible endpoint).
///
/// Used as the LAST resort in [AiRepository] when neither the YatraWise
/// backend nor a build-time NVIDIA key is available, so the AI assistant
/// works out of the box. It needs no API key and stores no data; the free
/// anonymous tier is rate-limited (roughly one request per 15 seconds).
///
/// https://text.pollinations.ai/openai
class PollinationsClient {
  PollinationsClient({Dio? dio, this.model = 'openai'})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://text.pollinations.ai',
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 120),
              contentType: 'application/json',
            ));

  final Dio _dio;
  final String model;

  /// Mirrors the NVIDIA/backend response shapes so [AiRepository] can treat
  /// this transport identically.
  Future<Map<String, dynamic>> postChat({
    required List<Map<String, String>> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
    String system =
        'You are YatraWise, a smart tourism and personal-safety assistant. '
        'Answer travel questions (attractions, food, transport, itineraries, local tips) '
        'with practical, current, location-aware advice. Keep replies under 250 words, '
        'friendly and specific. If safety is at stake, advise calling local emergency services. '
        'Never invent precise facts you are unsure of; say what is typical and suggest verifying. ';
    if (locationLabel != null && locationLabel.trim().isNotEmpty) {
      final String loc = locationLabel.trim();
      system +=
          'The traveler is currently in: ${loc.length > 200 ? loc.substring(0, 200) : loc}. ';
    }
    if (profileContext != null && profileContext.trim().isNotEmpty) {
      final String pc = profileContext.trim();
      system +=
          'Traveler preferences: ${pc.length > 400 ? pc.substring(0, 400) : pc}. ';
    }
    final String reply = await _complete(
      messages: <Map<String, String>>[
        <String, String>{'role': 'system', 'content': system},
        ...messages,
      ],
    );
    return <String, dynamic>{'reply': reply.trim()};
  }

  /// Mirrors backend POST /itinerary → `{plan}`.
  Future<Map<String, dynamic>> postItinerary({
    required String destination,
    required int days,
    required List<String> interests,
    required String budget,
    required String travelStyle,
  }) async {
    final String prompt =
        'Create a realistic $days-day travel itinerary for $destination. '
        'Traveler interests: ${interests.isNotEmpty ? interests.join(', ') : 'general sightseeing'}. '
        'Budget level: $budget. Pace: $travelStyle. '
        'Respond with ONLY JSON matching exactly this schema: '
        '{"plan":[{"day":1,"items":[{"time":"HH:MM","title":"...","description":"1-2 sentences","cost":"e.g. free, \$15"}]}]}. '
        'Include 3-6 items per day with times, covering real attractions, food and transport. '
        'No markdown, no extra keys.';
    final String raw = await _complete(
      messages: <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': 'You are a meticulous travel planner that outputs strict JSON only.',
        },
        <String, String>{'role': 'user', 'content': prompt},
      ],
    );
    late final Map<String, dynamic> parsed;
    try {
      parsed = _parseJsonLoose(raw);
    } on FormatException {
      throw ApiException(ApiErrorKind.server,
          'The AI returned a malformed itinerary. Please regenerate.');
    }
    final List<dynamic> rawPlan =
        parsed['plan'] is List ? parsed['plan'] as List : <dynamic>[];
    final List<Map<String, dynamic>> plan = <Map<String, dynamic>>[];
    for (final dynamic d in rawPlan.take(10)) {
      if (d is! Map) continue;
      final Map<String, dynamic> dm =
          d is Map<String, dynamic> ? d : _asStringMap(d);
      final List<dynamic> rawItems =
          dm['items'] is List ? dm['items'] as List : <dynamic>[];
      final List<Map<String, String>> items = <Map<String, String>>[];
      for (final dynamic it in rawItems.take(10)) {
        if (it is! Map) continue;
        final Map<String, dynamic> im =
            it is Map<String, dynamic> ? it : _asStringMap(it);
        items.add(<String, String>{
          'time': _pickString(im, 'time', 8),
          'title': _pickString(im, 'title', 140),
          'description': _pickString(im, 'description', 400),
          'cost': _pickString(im, 'cost', 60),
        });
      }
      if (items.isEmpty) continue;
      int dayNo = plan.length + 1;
      final Object? dayRaw = dm['day'];
      final int? parsedDay =
          dayRaw is int ? dayRaw : int.tryParse(dayRaw?.toString() ?? '');
      if (parsedDay != null) dayNo = parsedDay;
      plan.add(<String, dynamic>{'day': dayNo, 'items': items});
    }
    if (plan.isEmpty) {
      throw ApiException(ApiErrorKind.server,
          'The AI returned an empty itinerary. Please regenerate.');
    }
    return <String, dynamic>{'plan': plan};
  }

  /// Mirrors backend POST /incidentAnalyze → category/severity/summary/action.
  Future<Map<String, dynamic>> postIncidentAnalyze({
    required String description,
    String? locationLabel,
    bool hasPhoto = false,
    bool hasVideo = false,
  }) async {
    const List<String> categories = <String>[
      'theft', 'fraud', 'assault', 'harassment', 'accident',
      'unsafe_area', 'poor_infrastructure', 'natural_hazard', 'other',
    ];
    const List<String> severities = <String>[
      'low', 'medium', 'high', 'critical',
    ];
    final List<String> evidence = <String>[
      if (hasPhoto) 'photo',
      if (hasVideo) 'video',
    ];
    final String prompt =
        'You are a security analyst triaging a traveler\u2019s incident report. '
        'Description: """$description""" '
        '${locationLabel != null && locationLabel.trim().isNotEmpty ? 'Location: ${locationLabel.trim()}. ' : ''}'
        'Attached evidence: ${evidence.isNotEmpty ? evidence.join(' + ') : 'none'}. '
        'Respond with ONLY JSON: '
        '{"category":"one of ${categories.join('|')}",'
        '"severity":"one of ${severities.join('|')}",'
        '"summary":"1-2 sentence neutral summary",'
        '"recommendedAction":"1-2 concrete safety actions for the traveler"}. '
        'Do not claim authorities were notified. Be factual.';
    final String raw = await _complete(
      messages: <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': 'You output strict JSON only.',
        },
        <String, String>{'role': 'user', 'content': prompt},
      ],
    );
    late final Map<String, dynamic> parsed;
    try {
      parsed = _parseJsonLoose(raw);
    } on FormatException {
      throw ApiException(ApiErrorKind.server, 'The AI triage failed. Please retry.');
    }
    return <String, dynamic>{
      'category': _pickEnum(parsed, 'category', categories, 'other'),
      'severity': _pickEnum(parsed, 'severity', severities, 'medium'),
      'summary': _pickString(parsed, 'summary', 500),
      'recommendedAction': _pickString(parsed, 'recommendedAction', 500),
    };
  }

  Future<String> _complete({
    required List<Map<String, String>> messages,
  }) async {
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '/openai',
        data: <String, dynamic>{
          'model': model,
          'messages': messages,
        },
      );
      final dynamic data = resp.data;
      final dynamic choices = data is Map ? data['choices'] : null;
      String? content;
      if (choices is List && choices.isNotEmpty) {
        final dynamic first = choices[0];
        final dynamic msg = first is Map ? first['message'] : null;
        if (msg is Map) content = msg['content'] as String?;
      }
      if (content == null || content.trim().isEmpty) {
        throw ApiException(ApiErrorKind.server,
            'The AI model returned an empty response. Please try again.');
      }
      return content.trim();
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  ApiException _map(DioException e) {
    final int? code = e.response?.statusCode;
    if (code == 429) {
      return ApiException(
          ApiErrorKind.rateLimited,
          'The AI is rate-limited right now. Please wait a moment and retry.',
          statusCode: code);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException(ApiErrorKind.timeout,
            'The AI did not respond in time. Check your connection and try again.');
      case DioExceptionType.connectionError:
        return ApiException(ApiErrorKind.network,
            'No network connection. Check your internet connection and try again.');
      case DioExceptionType.badCertificate:
        return ApiException(ApiErrorKind.unknown,
            'Secure connection check failed. Check your device date/time.');
      case DioExceptionType.cancel:
        return ApiException(ApiErrorKind.unknown, 'Request cancelled.');
      case DioExceptionType.badResponse:
        return ApiException(
            ApiErrorKind.server,
            'The AI service returned an error (${code ?? 'unknown'}). '
            'Please try again.',
            statusCode: code);
      case DioExceptionType.unknown:
        return ApiException(ApiErrorKind.unknown,
            'Something went wrong while contacting the AI service.');
    }
  }

  Map<String, dynamic> _parseJsonLoose(String text) {
    String t = text.trim();
    if (t.startsWith('```')) {
      t = t
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '');
    }
    final int start = t.indexOf('{');
    final int end = t.lastIndexOf('}');
    if (start >= 0 && end > start) t = t.substring(start, end + 1);
    final dynamic decoded = jsonDecode(t);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v));
    }
    throw const FormatException('Not a JSON object');
  }

  Map<String, dynamic> _asStringMap(Map<dynamic, dynamic> m) =>
      m.map((Object? k, Object? v) => MapEntry(k.toString(), v));

  String _pickEnum(
      Map<String, dynamic> obj, String field, List<String> allowed, String fallback) {
    final Object? v = obj[field];
    final String s = v is String ? v.trim().toLowerCase() : '';
    return allowed.contains(s) ? s : fallback;
  }

  String _pickString(Map<String, dynamic> obj, String field, int max) {
    final Object? v = obj[field];
    if (v is! String) return '';
    final String s = v.trim();
    return s.length > max ? s.substring(0, max) : s;
  }
}
