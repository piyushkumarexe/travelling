import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/nvidia_direct_client.dart';
import '../models/itinerary.dart';

/// NVIDIA AI calls — preferably through the Yatrawise backend (server-side
/// key, rate limits). When the backend is unreachable (Cloud Functions not
/// deployed yet) and a build-time NVIDIA key is present, calls
/// transparently fall back to a direct NVIDIA request so the AI features
/// keep working.
library;

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
  AiRepository(this._api, {NvidiaDirectClient? direct})
      : _direct = direct ?? NvidiaDirectClient();

  final ApiClient _api;
  final NvidiaDirectClient _direct;

  /// Backend failures that mean "backend missing/unreachable" and are worth
  /// a direct retry. Auth/validation/rate-limit errors come from a live
  /// backend and are reported as-is.
  bool _shouldFallback(ApiException e) =>
      _direct.enabled &&
      (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.server ||
          e.kind == ApiErrorKind.unknown);

  /// Chat with the tourism assistant. `locationLabel` (e.g. "Rishikesh,
  /// Uttarakhand, India") is merged into the server-side system prompt.
  Future<String> chat({
    required List<AiChatMessage> messages,
    String? locationLabel,
    String? profileContext,
  }) async {
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
      if (!_shouldFallback(e)) rethrow;
      final Map<String, dynamic> data = await _direct.postChat(
        messages: messages
            .map((AiChatMessage m) => <String, String>{
                  'role': m.role,
                  'content': m.content,
                })
            .toList(),
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
      if (!_shouldFallback(e)) rethrow;
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
      if (!_shouldFallback(e)) rethrow;
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
