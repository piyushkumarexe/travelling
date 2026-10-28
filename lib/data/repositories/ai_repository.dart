import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../models/itinerary.dart';

class AiChatMessage {
  const AiChatMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'role': role,
        'content': content,
      };
}

/// AI requests use only the authenticated Tourism backend. Provider keys are
/// server-side secrets; there is intentionally no direct-provider fallback.
class AiRepository {
  const AiRepository(this._api);

  final ApiClient _api;

  Future<String> chat({
    required List<AiChatMessage> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
    final Map<String, dynamic> data = await _api.post(
      '/chat',
      <String, dynamic>{
        'messages': messages.map((message) => message.toMap()).toList(),
        if (locationLabel != null && locationLabel.isNotEmpty)
          'locationLabel': locationLabel,
        if (profileContext != null && profileContext.isNotEmpty)
          'profileContext': profileContext,
      },
      receiveTimeout: const Duration(seconds: 65),
    );
    final String? reply = data['reply'] as String?;
    if (reply == null || reply.trim().isEmpty) {
      throw ApiException(ApiErrorKind.server,
          'The assistant returned an empty response. Please try again.');
    }
    return reply.trim();
  }

  Future<List<ItineraryDay>> generateItinerary({
    required String destination,
    required int days,
    required List<String> interests,
    required String budget,
    required String travelStyle,
  }) async {
    final Map<String, dynamic> data = await _api.post(
      '/itinerary',
      <String, dynamic>{
        'destination': destination.trim(),
        'days': days,
        'interests': interests,
        'budget': budget,
        'travelStyle': travelStyle,
      },
      receiveTimeout: const Duration(seconds: 95),
    );
    final List<dynamic> raw =
        data['plan'] is List ? data['plan'] as List : <dynamic>[];
    final List<ItineraryDay> plan = raw
        .whereType<Map<String, dynamic>>()
        .map(ItineraryDay.fromMap)
        .toList();
    if (plan.length != days || plan.any((day) => day.items.isEmpty)) {
      throw ApiException(ApiErrorKind.parser,
          'The itinerary response was incomplete. Please regenerate.');
    }
    return plan;
  }

  Future<Map<String, String>> analyzeIncident({
    required String description,
    String? locationLabel,
    bool hasPhoto = false,
    bool hasVideo = false,
  }) async {
    final Map<String, dynamic> data = await _api.post(
      '/incidentAnalyze',
      <String, dynamic>{
        'description': description.trim(),
        if (locationLabel != null && locationLabel.isNotEmpty)
          'locationLabel': locationLabel,
        'hasPhoto': hasPhoto,
        'hasVideo': hasVideo,
      },
      receiveTimeout: const Duration(seconds: 65),
    );
    final String summary = (data['summary'] as String? ?? '').trim();
    final String action = (data['recommendedAction'] as String? ?? '').trim();
    if (summary.isEmpty || action.isEmpty) {
      throw ApiException(ApiErrorKind.parser,
          'Incident triage was incomplete. Please retry.');
    }
    return <String, String>{
      'category': (data['category'] as String?) ?? 'other',
      'severity': (data['severity'] as String?) ?? 'medium',
      'summary': summary,
      'recommendedAction': action,
    };
  }
}
