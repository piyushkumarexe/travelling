import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sos_sheet.dart';

/// Always-visible SOS action on the main navigation shell.
class SosFab extends StatelessWidget {
  const SosFab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: FloatingActionButton(
        tooltip: 'Emergency SOS',
        onPressed: () => showSOSSheet(context),
        backgroundColor: AppTheme.danger,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        child: const Icon(Icons.phone_in_talk_rounded, size: 28),
      ),
    );
  }
}
