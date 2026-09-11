import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sos_sheet.dart';

/// Always-visible SOS action on the main navigation shell.
///
/// Rendered as a circular call button (red, phone icon) so it reads
/// instantly as an emergency action.
class SosFab extends StatelessWidget {
  const SosFab({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => showSOSSheet(context),
      tooltip: 'SOS emergency',
      backgroundColor: AppTheme.danger,
      foregroundColor: Colors.white,
      child: const Icon(Icons.call, size: 26),
    );
  }
}
