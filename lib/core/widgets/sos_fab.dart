import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sos_sheet.dart';

/// Always-visible SOS action on the main navigation shell.
class SosFab extends StatelessWidget {
  const SosFab({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () => showSOSSheet(context),
      backgroundColor: AppTheme.danger,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.sos),
      label: const Text('SOS'),
    );
  }
}
