import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_container.dart';
import '../theme/app_theme.dart';
import 'live_share_prompt.dart';

/// Persistent banner shown while live location sharing is ACTIVE:
/// who it is shared with, whether SMS is actually going out, and Stop /
/// Enable-SMS actions. Used on the Map screen and the Live Trip screen so
/// the traveler always sees (and can stop) an ongoing share.
class LiveShareBanner extends StatelessWidget {
  const LiveShareBanner({super.key, this.margin = const EdgeInsets.all(12)});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final AppContainer c = AppScope.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: c.liveLocationShare,
          builder: (BuildContext context, _) {
            if (!c.liveLocationShare.active) return const SizedBox.shrink();
            final int sent = c.liveLocationShare.smsSent;
            final bool smsOn = c.liveLocationShare.smsEnabled;
            final String who = c.liveLocationShare.sosContactName.isNotEmpty
                ? c.liveLocationShare.sosContactName
                : 'your SOS contact';
            return Padding(
              padding: margin,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.broadcast_on_personal,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _statusText(who: who, sent: sent, smsOn: smsOn),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!smsOn)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () async {
                          final bool ok =
                              await c.smsService.ensureSendSmsPermission();
                          if (ok) await c.liveLocationShare.enableSmsNow();
                        },
                        child: const Text('Enable SMS',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    IconButton(
                      tooltip: 'Send current location on WhatsApp',
                      icon: const Icon(Icons.chat, color: Colors.white, size: 20),
                      onPressed: () =>
                          unawaited(c.liveLocationShare.shareWhatsAppNow()),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () async {
                        await c.liveLocationShare.stop();
                        c.liveLocationShare.recordHistoryEvent(
                          'Live location sharing stopped',
                          'You stopped sharing your live location.',
                        );
                      },
                      child: const Text('Stop',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Convenience wrapper for non-Stack contexts (e.g. inside a Column).
class LiveShareBannerInline extends StatelessWidget {
  const LiveShareBannerInline({super.key});

  @override
  Widget build(BuildContext context) {
    final AppContainer c = AppScope.of(context);
    return ListenableBuilder(
      listenable: c.liveLocationShare,
      builder: (BuildContext context, _) {
        if (!c.liveLocationShare.active) return const SizedBox.shrink();
        final int sent = c.liveLocationShare.smsSent;
        final bool smsOn = c.liveLocationShare.smsEnabled;
        final String who = c.liveLocationShare.sosContactName.isNotEmpty
            ? c.liveLocationShare.sosContactName
            : 'your SOS contact';
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.danger.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.broadcast_on_personal,
                  color: AppTheme.danger, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _statusText(who: who, sent: sent, smsOn: smsOn),
                  style: const TextStyle(
                    color: AppTheme.danger,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!smsOn)
                TextButton(
                  onPressed: () async {
                    final bool ok =
                        await c.smsService.ensureSendSmsPermission();
                    if (ok) await c.liveLocationShare.enableSmsNow();
                  },
                  child: const Text('Enable SMS'),
                ),
              IconButton(
                tooltip: 'Send current location on WhatsApp',
                icon: const Icon(Icons.chat, color: AppTheme.danger, size: 20),
                onPressed: () =>
                    unawaited(c.liveLocationShare.shareWhatsAppNow()),
              ),
              TextButton(
                onPressed: () async {
                  await c.liveLocationShare.stop();
                  c.liveLocationShare.recordHistoryEvent(
                    'Live location sharing stopped',
                    'You stopped sharing your live location.',
                  );
                },
                child: const Text('Stop'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Shows honest feedback for a [LiveShareStartResult] as a snackbar.
void showLiveShareFeedback(
  BuildContext context,
  LiveShareStartResult result, {
  bool smsEnabled = true,
}) {
  if (result == LiveShareStartResult.declined) return;
  final String message = switch (result) {
    LiveShareStartResult.started => smsEnabled
        ? 'Live location sharing is ON — your SOS contact will receive your '
            'location by SMS (in the Messages app, not WhatsApp).'
        : 'Live location sharing is ON, but the SMS permission is off — tap '
            '"Enable SMS" on the red banner so your contact gets messages.',
    LiveShareStartResult.noContact => 'Add an SOS contact first to share '
        'your live location.',
    LiveShareStartResult.noLocation => 'Could not get your GPS location — '
        'turn on location services and try again.',
    LiveShareStartResult.failed => 'Live location sharing could not start. '
        'Please try again.',
    LiveShareStartResult.declined => '',
  };
  if (message.isEmpty || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: smsEnabled ? const Duration(seconds: 4) : const Duration(seconds: 6),
    ),
  );
}

/// One-line status for the share banners, honest about the SMS channel.
String _statusText({required String who, required int sent, required bool smsOn}) {
  if (sent > 0) return 'Sharing live location with $who · $sent SMS sent';
  if (smsOn) return 'Sharing live location with $who · first SMS going out…';
  return 'Sharing live location with $who · SMS permission off';
}
