import 'package:flutter/material.dart';

import '../../../core/widgets/app_card.dart';

class VehicleScreen extends StatelessWidget {
  const VehicleScreen({super.key});

  void _comingSoon(BuildContext context, String vehicle) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: Icon(vehicle == 'Auto' ? Icons.electric_rickshaw : Icons.two_wheeler),
        title: Text('$vehicle booking'),
        content: const Text(
          'Coming soon. Safe local rides and transparent fares are being prepared.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Choose your ride',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Local ride booking will be available in a future update.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          AppCard(
            onTap: () => _comingSoon(context, 'Auto'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Icon(Icons.electric_rickshaw)),
              title: Text('Auto'),
              subtitle: Text('Quick local rides'),
              trailing: Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            onTap: () => _comingSoon(context, 'Bike'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Icon(Icons.two_wheeler)),
              title: Text('Bike'),
              subtitle: Text('Fast solo travel'),
              trailing: Icon(Icons.chevron_right),
            ),
          ),
        ],
      ),
    );
  }
}
