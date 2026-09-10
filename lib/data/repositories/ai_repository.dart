import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../models/itinerary.dart';

/// NVIDIA AI calls — always through the Roamio backend. The NVIDIA key
/// never touches the client.

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
  AiRepository(this._api);

  final ApiClient _api;

  /// Chat with the tourism assistant. `locationLabel` (e.g. "Rishikesh,
  /// Uttarakhand, India") is merged into the server-side system prompt.
  Future<String> chat({
    required List<AiChatMessage> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
    final Map<String, dynamic> data = await _api.post('/chat', <String, dynamic>{
      'messages': messages.map((AiChatMessage m) => m.toMap()).toList(),
      if (locationLabel != null && locationLabel.isNotEmpty)
        'locationLabel': locationLabel,
      if (profileContext != null && profileContext.isNotEmpty)
        'profileContext': profileContext,
    });
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
    final Map<String, dynamic> data = await _api.post(
      '/itinerary',
      <String, dynamic>{
        'destination': destination.trim(),
        'days': days,
        'interests': interests,
        'budget': budget,
        'travelStyle': travelStyle,
      },
    );
    final List<dynamic> raw = (data['plan'] is List) ? data['plan'] as List : <dynamic>[];
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
    final Map<String, dynamic> data = await _api.post(
      '/incidentAnalyze',
      <String, dynamic>{
        'description': description.trim(),
        if (locationLabel != null && locationLabel.isNotEmpty)
          'locationLabel': locationLabel,
        'hasPhoto': hasPhoto,
        'hasVideo': hasVideo,
      },
    );
    return <String, String>{
      'category': (data['category'] as String?) ?? 'other',
      'severity': (data['severity'] as String?) ?? 'medium',
      'summary': (data['summary'] as String?) ?? '',
      'recommendedAction': (data['recommendedAction'] as String?) ?? '',
    };
  }
}
