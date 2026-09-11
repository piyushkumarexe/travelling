import 'dart:convert';

import 'package:dio/dio.dart';

import '../app_config.dart';
import 'api_exception.dart';

/// Direct OpenAI-compatible chat-completions client (NVIDIA NIM or any
/// provider that exposes `/chat/completions`).
///
/// Fallback path used only when the Tourism Cloud Functions backend is
/// unreachable (not deployed yet) AND a key was compiled into the app:
///
///   flutter build apk --dart-define=NVIDIA_API_KEY=nvapi-...        (NVIDIA)
///   flutter build apk --dart-define=AI_API_KEY=... \
///                     --dart-define=AI_BASE_URL=https://.../v1 \
///                     --dart-define=AI_MODEL=some/model              (generic)
///
/// It mirrors the backend prompts and response shapes so [AiRepository] can
/// switch transports transparently. Prefer deploying the backend for
/// production (server-side key, rate limits, no key inside the APK).
class OpenAiCompatClient {
  OpenAiCompatClient({Dio? dio, String? baseUrl, String? apiKey, String? model})
      : _baseUrl = baseUrl ?? AppConfig.aiResolvedBaseUrl,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl ?? AppConfig.aiResolvedBaseUrl,
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
              contentType: 'application/json',
            )),
        _apiKey = apiKey ?? AppConfig.aiResolvedApiKey,
        _model = model ?? AppConfig.aiResolvedModel;

  final String _baseUrl;
  final Dio _dio;
  final String _apiKey;
  final String _model;

  static const List<String> categories = <String>[
    'theft',
    'fraud',
    'assault',
    'harassment',
    'accident',
    'unsafe_area',
    'poor_infrastructure',
    'natural_hazard',
    'other',
  ];
  static const List<String> severities = <String>[
    'low',
    'medium',
    'high',
    'critical',
  ];

  /// True when a direct key was compiled into the app.
  bool get enabled => _apiKey.isNotEmpty && _baseUrl.isNotEmpty;

  /// Full chat-completions URL, built explicitly so a trailing slash (or any
  /// base-path quirk) can never drop a path segment.
  String get _chatUrl {
    final String base = _baseUrl.trim();
    final String clean =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$clean/chat/completions';
  }

  /// Host of the configured base URL (shown in errors so it's obvious which
  /// provider is being called). Never includes the key.
  String get _host {
    final Uri? uri = Uri.tryParse(_baseUrl.trim());
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return _baseUrl.trim();
  }

  /// Short, human-readable error body (Gemini/OpenAI return a JSON or HTML
  /// error that pinpoints the problem, e.g. "model not found").
  String _bodySnippet(Object? data) {
    String raw = '';
    if (data is String) {
      raw = data.trim();
    } else if (data is Map) {
      raw = jsonEncode(data);
    }
    if (raw.isEmpty) return '';
    final String clean = raw
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\t', ' ')
        .trim();
    final String snippet =
        clean.length > 220 ? '${clean.substring(0, 220)}…' : clean;
    return '($snippet)\n';
  }

  Future<String> _complete({
    required List<Map<String, String>> messages,
    bool jsonMode = false,
    int maxTokens = 1200,
  }) async {
    // Try the primary model, then fall back to alternates when the provider
    // reports the model was retired/renamed (404/400/410 "model not found"),
    // so the assistant keeps working as providers rotate their catalogues.
    final List<String> models = <String>{
      _model,
      ..._fallbackModelsFor(_baseUrl),
    }.toList();
    DioException? last;
    for (final String m in models) {
      try {
        return await _post(messages, jsonMode, maxTokens, m);
      } on DioException catch (e) {
        last = e;
        if (!_isModelNotFound(e) || m == models.last) throw _map(e);
      }
    }
    throw _map(last ??
        DioException(requestOptions: RequestOptions(path: _chatUrl)));
  }

  Future<String> _post(
    List<Map<String, String>> messages,
    bool jsonMode,
    int maxTokens,
    String model,
  ) async {
    final Response<dynamic> resp = await _dio.post<dynamic>(
      _chatUrl,
      data: <String, dynamic>{
        'model': model,
        'messages': messages,
        'temperature': 0.6,
        'top_p': 0.9,
        'max_tokens': maxTokens,
        if (jsonMode)
          'response_format': <String, String>{'type': 'json_object'},
      },
      options: Options(
        headers: <String, Object?>{
          'Authorization': 'Bearer $_apiKey',
        },
      ),
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
    return content;
  }

  /// True when the provider says the model no longer exists (retired,
  /// renamed, end-of-life) — worth retrying with the next candidate.
  bool _isModelNotFound(DioException e) {
    final int? code = e.response?.statusCode;
    if (code != 400 && code != 404 && code != 410) return false;
    final Object? d = e.response?.data;
    final String s = d is String ? d : (d is Map ? d.toString() : '');
    final String l = s.toLowerCase();
    return l.contains('model') &&
        (l.contains('not found') ||
            l.contains('not_found') ||
            l.contains('does not exist') ||
            l.contains('end of life') ||
            l.contains('deprecated') ||
            l.contains('invalid_request'));
  }

  /// Alternate model ids per provider, tried in order when the primary is
  /// retired. Verified against each provider's current catalogue.
  List<String> _fallbackModelsFor(String baseUrl) {
    final Uri? uri = Uri.tryParse(baseUrl.trim());
    final String host = uri?.host ?? '';
    if (host.contains('groq.com')) {
      return const <String>['openai/gpt-oss-20b', 'qwen/qwen3.6-27b'];
    }
    if (host.contains('nvidia.com')) {
      return const <String>['nvidia/nemotron-3-super-120b-a12b'];
    }
    return const <String>[];
  }

  ApiException _map(DioException e) {
    final int? code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return ApiException(
          ApiErrorKind.unauthorized,
          'The AI API key was rejected. Please check the key and rebuild.',
          statusCode: code,
          retryable: false);
    }
    if (code == 402) {
      return ApiException(
          ApiErrorKind.upstream,
          'The AI provider account has no credits or budget left. '
          'Top it up or use another key.',
          statusCode: code,
          retryable: false);
    }
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
            'The AI service returned an error (${code ?? 'unknown'}) '
            'from $_host (model: $_model). '
            '${_bodySnippet(e.response?.data)}'
            'Please try again.',
            statusCode: code);
      case DioExceptionType.unknown:
        return ApiException(ApiErrorKind.unknown,
            'The AI connection dropped before a reply arrived. The model may '
            'be busy or slow — please try again in a moment.',
            retryable: true);
    }
  }

  /// Parses model JSON, tolerating markdown fences and extra text around
  /// the object (same leniency as the backend).
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

  String _pickEnum(
    Map<String, dynamic> obj,
    String field,
    List<String> allowed,
    String fallback,
  ) {
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

  Map<String, dynamic> _asStringMap(Map<dynamic, dynamic> m) =>
      m.map((Object? k, Object? v) => MapEntry(k.toString(), v));

  /// Mirrors backend POST /chat → `{reply}`.
  Future<Map<String, dynamic>> postChat({
    required List<Map<String, String>> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
    String system =
        'You are Tourism, a smart tourism and personal-safety assistant. '
        'Answer travel questions (attractions, food, transport, itineraries, local tips) '
        'with practical, current, location-aware advice. If safety is at stake, advise '
        'calling local emergency services. Never invent precise facts you are unsure of; '
        'say what is typical and suggest verifying. '
        'Format every reply in light Markdown for a chat UI: use a short **bold** '
        'heading line (or ## heading) first, then bullet points (- ) with 2-6 items, '
        '**bold** key terms (names, prices, times), and 1-2 relevant emojis per section '
        '(🏛️ 🍛 🚕 ⚠️ ✅). Keep it under 250 words, scannable and specific.';
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
        '{"plan":[{"day":1,"items":[{"time":"HH:MM","title":"...","description":"1-2 sentences","cost":"e.g. free, \$15, ~\u20B9500"}]}]}. '
        'Include 3-6 items per day with times, covering $destination\u2019s real attractions, '
        'food and transport. No markdown, no extra keys.';
    final String raw = await _complete(
      messages: <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'You are a meticulous travel planner that outputs strict JSON only.'
        },
        <String, String>{'role': 'user', 'content': prompt},
      ],
      jsonMode: true,
      maxTokens: 2400,
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

  /// Mirrors backend POST /incidentAnalyze →
  /// `{category, severity, summary, recommendedAction}`.
  Future<Map<String, dynamic>> postIncidentAnalyze({
    required String description,
    String? locationLabel,
    bool hasPhoto = false,
    bool hasVideo = false,
  }) async {
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
          'content': 'You output strict JSON only.'
        },
        <String, String>{'role': 'user', 'content': prompt},
      ],
      jsonMode: true,
      maxTokens: 600,
    );
    late final Map<String, dynamic> parsed;
    try {
      parsed = _parseJsonLoose(raw);
    } on FormatException {
      throw ApiException(ApiErrorKind.server,
          'The AI triage failed. Please retry.');
    }
    return <String, dynamic>{
      'category': _pickEnum(parsed, 'category', categories, 'other'),
      'severity': _pickEnum(parsed, 'severity', severities, 'medium'),
      'summary': _pickString(parsed, 'summary', 500),
      'recommendedAction': _pickString(parsed, 'recommendedAction', 500),
    };
  }
}
