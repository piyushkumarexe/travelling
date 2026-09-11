import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/openai_compat_client.dart';
import '../models/itinerary.dart';

/// AI calls with a two-step transport fallback:
///   1. YatraWise Cloud Functions backend (server-side key, rate limits).
///   2. Direct OpenAI-compatible provider — NVIDIA NIM when a build-time
///      `NVIDIA_API_KEY` is present, otherwise a generic provider configured
///      via `AI_API_KEY` + `AI_BASE_URL` (+ `AI_MODEL`).
///
/// There is no reliable keyless LLM in 2026 (Pollinations legacy, Hack Club AI
/// and DuckDuckGo AI all shut down anonymous access), so when neither transport
/// is configured the repository surfaces a clear, actionable setup message
/// instead of a confusing HTTP error.

class AiChatMessage {
  AiChatMessage({required this.role, required this.content});
  final String role; // user | assistant
  final String content;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'role': role,
        'content': content,
      };
}

class AiRepository {
  AiRepository(
    this._api, {
    OpenAiCompatClient? direct,
  }) : _direct = direct ?? OpenAiCompatClient();

  final ApiClient _api;
  final OpenAiCompatClient _direct;

  /// Errors that mean "service missing/unreachable" and are worth retrying
  /// on the next transport. Auth/validation/rate-limit/payment errors come
  /// from a live service and are reported as-is.
  bool _fallbackEligible(ApiException e) =>
      e.kind == ApiErrorKind.network ||
      e.kind == ApiErrorKind.timeout ||
      e.kind == ApiErrorKind.server ||
      e.kind == ApiErrorKind.unknown;

  /// Thrown when neither the backend nor a direct AI key is available.
  ApiException _notConfigured() => ApiException(
        ApiErrorKind.server,
        'The AI assistant is not enabled yet.\n\n'
        'Option 1 — deploy the backend and set an NVIDIA key there:\n'
        '`firebase deploy --only functions`\n\n'
        'Option 2 — build the app with a free AI key:\n'
        '`flutter build apk --dart-define=NVIDIA_API_KEY=nvapi-...`\n'
        '(free key at build.nvidia.com)\n\n'
        'Option 3 — any OpenAI-compatible provider:\n'
        '`--dart-define=AI_API_KEY=... --dart-define=AI_BASE_URL=https://.../v1 '
        '--dart-define=AI_MODEL=...`',
        retryable: false,
      );

  /// Chat with the tourism assistant. `locationLabel` (e.g. "Rishikesh,
  /// Uttarakhand, India") is merged into the system prompt.
  Future<String> chat({
    required List<AiChatMessage> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
    final List<Map<String, String>> simple = messages
        .map((AiChatMessage m) => <String, String>{
              'role': m.role,
              'content': m.content,
            })
        .toList();
    final Map<String, dynamic> body = <String, dynamic>{
      'messages': messages.map((AiChatMessage m) => m.toMap()).toList(),
      if (locationLabel != null && locationLabel.isNotEmpty)
        'locationLabel': locationLabel,
      if (profileContext != null && profileContext.isNotEmpty)
        'profileContext': profileContext,
    };
    try {
      final Map<String, dynamic> data = await _api.post('/chat', body);
      return _replyFrom(data);
    } on ApiException catch (e) {
      if (!_fallbackEligible(e)) rethrow;
      if (!_direct.enabled) throw _notConfigured();
      final Map<String, dynamic> data = await _direct.postChat(
        messages: simple,
        locationLabel: locationLabel,
        profileContext: profileContext,
      );
      return _replyFrom(data);
    }
  }

  String _replyFrom(Map<String, dynamic> data) {
    final String? reply = data['reply'] as String?;
    if (reply == null || reply.trim().isEmpty) {
      throw ApiException(ApiErrorKind.server,
          'The AI assistant returned an empty response. Please try again.');
    }
    return reply.trim();
  }

  /// Generates a real itinerary; returns the parsed day plan.
  Future<List<ItineraryDay>> generateItinerary({
    required String destination,
    required int days,
    required List<String> interests,
    required String budget,
    required String travelStyle,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'destination': destination.trim(),
      'days': days,
      'interests': interests,
      'budget': budget,
      'travelStyle': travelStyle,
    };
    try {
      final Map<String, dynamic> data = await _api.post('/itinerary', body);
      return _planFrom(data);
    } on ApiException catch (e) {
      if (!_fallbackEligible(e)) rethrow;
      if (!_direct.enabled) throw _notConfigured();
      final Map<String, dynamic> data = await _direct.postItinerary(
        destination: destination.trim(),
        days: days,
        interests: interests,
        budget: budget,
        travelStyle: travelStyle,
      );
      return _planFrom(data);
    }
  }

  List<ItineraryDay> _planFrom(Map<String, dynamic> data) {
    final List<dynamic> raw =
        (data['plan'] is List) ? data['plan'] as List : <dynamic>[];
    final List<ItineraryDay> plan = raw
        .whereType<Map<String, dynamic>>()
        .map(ItineraryDay.fromMap)
        .toList();
    if (plan.isEmpty) {
      throw ApiException(ApiErrorKind.server,
          'The AI returned an empty itinerary. Please regenerate.');
    }
    return plan;
  }

  /// AI triage of an incident report.
  Future<Map<String, String>> analyzeIncident({
    required String description,
    String? locationLabel,
    bool hasPhoto = false,
    bool hasVideo = false,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'description': description.trim(),
      if (locationLabel != null && locationLabel.isNotEmpty)
        'locationLabel': locationLabel,
      'hasPhoto': hasPhoto,
      'hasVideo': hasVideo,
    };
    try {
      final Map<String, dynamic> data =
          await _api.post('/incidentAnalyze', body);
      return _triageFrom(data);
    } on ApiException catch (e) {
      if (!_fallbackEligible(e)) rethrow;
      if (!_direct.enabled) throw _notConfigured();
      final Map<String, dynamic> data = await _direct.postIncidentAnalyze(
        description: description.trim(),
        locationLabel: locationLabel,
        hasPhoto: hasPhoto,
        hasVideo: hasVideo,
      );
      return _triageFrom(data);
    }
  }

  Map<String, String> _triageFrom(Map<String, dynamic> data) =>
      <String, String>{
        'category': (data['category'] as String?) ?? 'other',
        'severity': (data['severity'] as String?) ?? 'medium',
        'summary': (data['summary'] as String?) ?? '',
        'recommendedAction': (data['recommendedAction'] as String?) ?? '',
      };
}
