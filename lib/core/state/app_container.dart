import 'package:firebase_core/firebase_core.dart' show FirebaseApp;
import 'package:flutter/widgets.dart';

import '../../data/repositories/ai_repository.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/digital_id_repository.dart';
import '../../data/repositories/emergency_repository.dart';
import '../../data/repositories/eco_repository.dart';
import '../../data/repositories/incidents_repository.dart';
import '../../data/repositories/itineraries_repository.dart';
import '../../data/repositories/notifications_repository.dart';
import '../../data/repositories/places_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../data/repositories/weather_repository.dart';
import '../../data/repositories/zones_repository.dart';
import '../app_config.dart';
import '../network/api_client.dart';
import '../services/eco_tracker.dart';
import '../services/geofence_service.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';
import 'auth_state.dart';

/// Dependency container for the whole app. Created once in main() and
/// provided to the tree through [AppScope].
class AppContainer {
  AppContainer({required this.firebaseReady, required this.app});

  final bool firebaseReady;
  final FirebaseApp? app;

  /// Base URL of the Tourism Cloud Functions backend, derived at runtime
  /// from the Firebase project id (no hardcoded secrets/hosts).
  String? get functionsBaseUrl {
    final FirebaseApp? a = app;
    if (a == null) return null;
    final String? projectId = a.options.projectId;
    if (projectId == null || projectId.startsWith('REPLACE_')) return null;
    return AppConfig.functionsBaseUrl(projectId);
  }

  bool get backendConfigured => functionsBaseUrl != null;

  late final ApiClient apiClient = ApiClient(baseUrl: functionsBaseUrl ?? '');

  // --- Repositories ---
  late final AuthRepository authRepository = AuthRepository();
  late final ProfileRepository profileRepository = ProfileRepository();
  late final ZonesRepository zonesRepository = ZonesRepository();
  late final IncidentsRepository incidentsRepository = IncidentsRepository();
  late final EmergencyRepository emergencyRepository = EmergencyRepository();
  late final DigitalIdRepository digitalIdRepository = DigitalIdRepository();
  late final ItinerariesRepository itinerariesRepository = ItinerariesRepository();
  late final EcoRepository ecoRepository = EcoRepository();
  late final NotificationsRepository notificationsRepository =
      NotificationsRepository();

  // --- Backend-backed repositories ---
  late final PlacesRepository placesRepository = PlacesRepository(apiClient);
  late final WeatherRepository weatherRepository = WeatherRepository(apiClient);
  late final AiRepository aiRepository = AiRepository(apiClient);

  // --- Device / platform services ---
  late final LocationService locationService = LocationService();
  late final StorageService storageService = StorageService();
  late final NotificationService notificationService = NotificationService();
  late final EcoTrackerService ecoTracker =
      EcoTrackerService(locationService: locationService);

  // --- App-level state ---
  late final AuthState authState = AuthState(authRepository);

  late final GeofenceService geofenceService = GeofenceService(
    zonesRepository: zonesRepository,
    locationService: locationService,
    notificationService: notificationService,
    notificationsRepository: notificationsRepository,
    currentUid: () {
      final String? uid = authRepository.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        throw StateError('Not signed in');
      }
      return uid;
    },
  );

  /// The signed-in uid (throws when not signed in).
  String currentUid() {
    final String? uid = authRepository.currentUser?.uid;
    if (uid == null || uid.isEmpty) throw StateError('Not signed in');
    return uid;
  }
}

/// Provides [AppContainer] to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.container, required super.child});

  final AppContainer container;

  static AppContainer of(BuildContext context) {
    final AppScope? scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    if (scope == null) {
      throw StateError('AppScope not found above this widget.');
    }
    return scope.container;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      container != oldWidget.container;
}
