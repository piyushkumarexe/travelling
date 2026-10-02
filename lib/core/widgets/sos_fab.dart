import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sos_sheet.dart';

/// Always-visible SOS action on the main navigation shell.
///
/// Circular emergency button with a call icon and the word "SOS", so it reads
/// instantly as an emergency action.
class SosFab extends StatelessWidget {
  const SosFab({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.danger,
      shape: const CircleBorder(),
      elevation: 6,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showSOSSheet(context),
        child: const SizedBox(
          width: 68,
          height: 68,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.call, color: Colors.white, size: 24),
              SizedBox(height: 1),
              Text(
                'SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
