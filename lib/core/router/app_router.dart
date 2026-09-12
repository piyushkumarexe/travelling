import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../app_shell.dart';
import '../../data/models/places.dart';
import '../../features/admin/screens/admin_screen.dart';
import '../../features/admin/screens/zone_editor_screen.dart';
import '../../features/assistant/screens/assistant_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/digital_id/screens/digital_id_screen.dart';
import '../../features/digital_id/screens/verify_id_screen.dart';
import '../../features/eco/screens/eco_screen.dart';
import '../../features/essentials/screens/essentials_screen.dart';
import '../../features/explore/screens/explore_screen.dart';
import '../../features/explore/screens/place_detail_screen.dart';
import '../../features/guardian/screens/payment_guardian_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/incidents/screens/incident_detail_screen.dart';
import '../../features/incidents/screens/incident_history_screen.dart';
import '../../features/incidents/screens/report_incident_screen.dart';
import '../../features/itinerary/screens/itinerary_detail_screen.dart';
import '../../features/itinerary/screens/itinerary_list_screen.dart';
import '../../features/itinerary/screens/itinerary_new_screen.dart';
import '../../features/map/screens/map_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/planner/screens/trip_planner_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/route/screens/multi_stop_screen.dart';
import '../../features/safety/screens/safety_screen.dart';
import '../../features/setup/screens/setup_guide_screen.dart';
import '../../features/trip/screens/live_trip_screen.dart';
import '../../features/vehicle/screens/vehicle_screen.dart';
import '../../features/wallet/screens/wallet_screen.dart';
import '../../features/weather/screens/weather_screen.dart';
import '../state/app_container.dart';
import '../state/auth_state.dart';

/// App routing with auth + admin guards.
class AppRouter {
  AppRouter({required this.container});

  final AppContainer container;

  late final GoRouter router = GoRouter(
    initialLocation: '/',
    refreshListenable: container.authState,
    redirect: (BuildContext context, GoRouterState state) {
      final AuthStatus status = container.authState.status;
      final String matched = state.matchedLocation;

      if (status == AuthStatus.initial) {
        return matched == '/' ? null : '/';
      }
      if (status == AuthStatus.unauthenticated) {
        return matched == '/login' ? null : '/login';
      }
      if (matched == '/' || matched == '/login') return '/home';
      if (matched.startsWith('/admin') && !container.authState.isAdmin) {
        return '/home';
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const SetupGuideScreen(splash: true),
      ),
      GoRoute(
        path: '/login',
        builder: (BuildContext context, GoRouterState state) =>
            const LoginScreen(),
      ),
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (BuildContext context, GoRouterState state) =>
                const HomeScreen(),
          ),
          GoRoute(
            path: '/explore',
            builder: (BuildContext context, GoRouterState state) =>
                const ExploreScreen(),
          ),
          GoRoute(
            path: '/map',
            builder: (BuildContext context, GoRouterState state) {
              final Map<String, String> qp = state.uri.queryParameters;
              return MapScreen(
                key: ValueKey<String>(
                    'map-${qp['lat'] ?? ''}-${qp['lng'] ?? ''}-${qp['name'] ?? ''}'),
                initialLat: double.tryParse(qp['lat'] ?? ''),
                initialLng: double.tryParse(qp['lng'] ?? ''),
                initialName: qp['name'],
              );
            },
          ),
          GoRoute(
            path: '/safety',
            builder: (BuildContext context, GoRouterState state) =>
                const SafetyScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (BuildContext context, GoRouterState state) =>
                const ProfileScreen(),
          ),
          GoRoute(
            path: '/vehicle',
            builder: (BuildContext context, GoRouterState state) =>
                const VehicleScreen(),
          ),
          GoRoute(
            path: '/essentials',
            builder: (BuildContext context, GoRouterState state) =>
                const EssentialsScreen(),
          ),
          GoRoute(
            path: '/wallet',
            builder: (BuildContext context, GoRouterState state) =>
                const WalletScreen(),
          ),
          GoRoute(
            path: '/planner',
            builder: (BuildContext context, GoRouterState state) =>
                const TripPlannerScreen(),
          ),
          GoRoute(
            path: '/route/multi',
            builder: (BuildContext context, GoRouterState state) =>
                const MultiStopScreen(),
          ),
          GoRoute(
            path: '/trip/live',
            builder: (BuildContext context, GoRouterState state) {
              final Map<String, String> qp = state.uri.queryParameters;
              return LiveTripScreen(
                destinationLat: double.tryParse(qp['lat'] ?? ''),
                destinationLng: double.tryParse(qp['lng'] ?? ''),
                destinationName: qp['name'],
              );
            },
          ),
        ],
      ),
      GoRoute(
        path: '/explore/place/:placeId',
        builder: (BuildContext context, GoRouterState state) =>
            PlaceDetailScreen(
          placeId: state.pathParameters['placeId'] ?? '',
          place: state.extra is Place ? state.extra as Place : null,
        ),
      ),
      GoRoute(
        path: '/assistant',
        builder: (BuildContext context, GoRouterState state) =>
            const AssistantScreen(),
      ),
      GoRoute(
        path: '/itineraries',
        builder: (BuildContext context, GoRouterState state) =>
            const ItineraryListScreen(),
      ),
      GoRoute(
        path: '/itineraries/new',
        builder: (BuildContext context, GoRouterState state) =>
            const ItineraryNewScreen(),
      ),
      GoRoute(
        path: '/itineraries/:id',
        builder: (BuildContext context, GoRouterState state) =>
            ItineraryDetailScreen(id: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/incidents/report',
        builder: (BuildContext context, GoRouterState state) =>
            const ReportIncidentScreen(),
      ),
      GoRoute(
        path: '/incidents',
        builder: (BuildContext context, GoRouterState state) =>
            const IncidentHistoryScreen(),
      ),
      GoRoute(
        path: '/incidents/:id',
        builder: (BuildContext context, GoRouterState state) =>
            IncidentDetailScreen(id: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/digital-id',
        builder: (BuildContext context, GoRouterState state) =>
            const DigitalIdScreen(),
      ),
      GoRoute(
        path: '/digital-id/verify',
        builder: (BuildContext context, GoRouterState state) =>
            const VerifyIdScreen(),
      ),
      GoRoute(
        path: '/eco',
        builder: (BuildContext context, GoRouterState state) =>
            const EcoScreen(),
      ),
      GoRoute(
        path: '/weather',
        builder: (BuildContext context, GoRouterState state) =>
            const WeatherScreen(),
      ),
      GoRoute(
        path: '/guardian',
        builder: (BuildContext context, GoRouterState state) =>
            const PaymentGuardianScreen(),
      ),
      GoRoute(
        path: '/notifications',
        builder: (BuildContext context, GoRouterState state) =>
            const NotificationsScreen(),
      ),
      GoRoute(
        path: '/admin',
        builder: (BuildContext context, GoRouterState state) =>
            const AdminScreen(),
      ),
      GoRoute(
        path: '/admin/zone/new',
        builder: (BuildContext context, GoRouterState state) =>
            const ZoneEditorScreen(),
      ),
      GoRoute(
        path: '/admin/zone/:id',
        builder: (BuildContext context, GoRouterState state) =>
            ZoneEditorScreen(zoneId: state.pathParameters['id'] ?? ''),
      ),
    ],
  );
}
