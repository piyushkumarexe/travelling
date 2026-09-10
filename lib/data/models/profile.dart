import 'package:cloud_firestore/cloud_firestore.dart';

/// User profile (extended identity + preferences), stored at profiles/{uid}.
library;

class Profile {
  Profile({
    required this.uid,
    this.name = '',
    this.photoUrl,
    this.language = 'en',
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
    this.interests = const <String>[],
    this.budget = 'mid',
    this.travelStyle = 'balanced',
    this.updatedAt,
  });

  final String uid;
  final String name;
  final String? photoUrl;
  final String language;
  final String emergencyContactName;
  final String emergencyContactPhone;
  final List<String> interests;
  final String budget;
  final String travelStyle;
  final DateTime? updatedAt;

  factory Profile.fromMap(String uid, Map<String, dynamic>? m) {
    final Map<String, dynamic> d = m ?? <String, dynamic>{};
    return Profile(
      uid: uid,
      name: (d['name'] as String?) ?? '',
      photoUrl: d['photoUrl'] as String?,
      language: (d['language'] as String?) ?? 'en',
      emergencyContactName: (d['emergencyContactName'] as String?) ?? '',
      emergencyContactPhone: (d['emergencyContactPhone'] as String?) ?? '',
      interests: (d['interests'] is List)
          ? (d['interests'] as List).whereType<String>().toList()
          : <String>[],
      budget: (d['budget'] as String?) ?? 'mid',
      travelStyle: (d['travelStyle'] as String?) ?? 'balanced',
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'uid': uid,
        'name': name,
        'photoUrl': photoUrl,
        'language': language,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'interests': interests,
        'budget': budget,
        'travelStyle': travelStyle,
        'updatedAt': DateTime.now().toUtc(),
      };
}

const List<String> kSupportedLanguages = <String>[
  'en',
  'hi',
  'es',
  'fr',
  'de',
  'pt',
  'it',
  'ar',
  'zh',
  'ja',
];

const Map<String, String> kLanguageNames = <String, String>{
  'en': 'English',
  'hi': 'हिन्दी (Hindi)',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'pt': 'Português',
  'it': 'Italiano',
  'ar': 'العربية (Arabic)',
  'zh': '中文 (Chinese)',
  'ja': '日本語 (Japanese)',
};

const List<String> kBudgetLevels = <String>['budget', 'mid', 'luxury'];

const List<String> kTravelStyles = <String>['relaxed', 'balanced', 'packed'];

const List<String> kInterestOptions = <String>[
  'History',
  'Culture',
  'Food',
  'Nature',
  'Adventure',
  'Shopping',
  'Nightlife',
  'Family',
  'Relaxation',
  'Photography',
];
