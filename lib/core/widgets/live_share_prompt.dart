import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../state/app_container.dart';
import '../theme/app_theme.dart';

/// What happened after the live-share prompt flow ran.
enum LiveShareStartResult {
  /// The user accepted and local live updates started; see per-channel status.
  started,

  /// The user chose "Not now".
  declined,

  /// No SOS contact is configured — the user was taken to add one.
  noContact,

  /// The user accepted but a GPS fix was unavailable.
  noLocation,

  /// Anything else (should not normally happen).
  failed,
}

/// Shows the English prompt shown right before in-app navigation starts:
///
///   "Do you want to share your live location with your SOS contact?"
///
/// Answering "Yes, share" starts [LiveLocationShareService] — the contact
/// receives coordinates + a live Google Maps link by SMS (immediately, then
/// every 5 minutes) and the position refreshes in the app/cloud every 45 s.
Future<LiveShareStartResult> showLiveSharePrompt(
  BuildContext context, {
  String? destinationName,
}) async {
  final AppContainer c = AppScope.of(context);
  // Already sharing (e.g. resuming a navigation): never re-ask — just
  // confirm the state so the UI can show the honest feedback.
  if (c.liveLocationShare.active) {
    return LiveShareStartResult.started;
  }
  final bool hasContact = c.liveLocationShare.hasContact;
  final String contactLabel = c.liveLocationShare.sosContactName.isNotEmpty
      ? c.liveLocationShare.sosContactName
      : c.liveLocationShare.sosContactPhone;

  final bool? accepted = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      icon: const Icon(Icons.share_location, color: AppTheme.seed, size: 40),
      title: const Text('Share live location?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Do you want to share your live location with your SOS contact'
            '${destinationName != null
                ? ' while you navigate to $destinationName'
                : ''}?',
          ),
          const SizedBox(height: 10),
          Text(
            hasContact
                ? 'While you navigate, Tourism will try to send $contactLabel '
                    'your coordinates and a map link by SMS. The banner shows '
                    'queued, not delivered, status and cloud availability. With internet '
                    'on, your WhatsApp chat also opens automatically with '
                    'the message ready — just press send. You can stop '
                    'sharing any time.'
                : 'You have no SOS contact added yet. Add one to enable live '
                    'location sharing.',
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(hasContact ? 'Yes, share' : 'Add SOS contact'),
        ),
      ],
    ),
  );

  if (accepted != true) return LiveShareStartResult.declined;
  if (!hasContact) {
    // Let the user add the contact right away.
    if (context.mounted) {
      await Future<void>.delayed(Duration.zero);
      if (context.mounted) {
        // ignore: use_build_context_synchronously
        unawaitedPush(context, '/safety?addContact=1');
      }
    }
    return LiveShareStartResult.noContact;
  }

  // Ask for the SEND_SMS permission up-front so the SMS path truly works.
  await c.smsService.ensureSendSmsPermission();

  final String displayName =
      c.authRepository.currentUser?.displayName ?? 'Traveler';
  final bool ok = await c.liveLocationShare.start(
    reason: 'navigation',
    destinationName: destinationName,
    travelerName: displayName.isNotEmpty ? displayName : 'Traveler',
  );
  if (ok) {
    c.liveLocationShare.recordHistoryEvent(
      'Live location sharing started',
      destinationName != null
          ? 'Automatic live updates started for navigation to '
              '$destinationName. SMS delivery is not confirmed.'
          : 'Automatic live updates started. SMS delivery is not confirmed.',
    );
    return LiveShareStartResult.started;
  }
  switch (c.liveLocationShare.lastError) {
    case 'no-location':
      return LiveShareStartResult.noLocation;
    case 'no-contact':
      return LiveShareStartResult.noContact;
    default:
      return LiveShareStartResult.failed;
  }
}

/// Fire-and-forget push that never throws across an async gap.
void unawaitedPush(BuildContext context, String route) {
  try {
    GoRouter.of(context).push(route);
  } catch (_) {
    // Router unavailable — nothing sensible to do here.
  }
}
