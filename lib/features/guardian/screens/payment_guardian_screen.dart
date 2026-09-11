import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/price_guard.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';

/// Tourism "Payment Guardian" — helps foreign tourists understand whether a
/// charge may be higher than the typical range.
///
/// Every verdict is a transparent *estimate* (deterministic reference rules),
/// never an accusation of fraud and never a fake AI answer.
class PaymentGuardianScreen extends StatefulWidget {
  const PaymentGuardianScreen({super.key});

  @override
  State<PaymentGuardianScreen> createState() => _PaymentGuardianScreenState();
}

class _PaymentGuardianScreenState extends State<PaymentGuardianScreen> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _distance = TextEditingController();
  PriceCategory _category = PriceCategory.taxi;
  PriceCheckResult? _result;

  @override
  void dispose() {
    _amount.dispose();
    _distance.dispose();
    super.dispose();
  }

  void _run() {
    final double? amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount in ₹.')),
      );
      return;
    }
    final double? distance =
        double.tryParse(_distance.text.trim().replaceAll(',', '.'));
    FocusScope.of(context).unfocus();
    setState(() {
      _result = PriceGuard.check(
        category: _category,
        amount: amount,
        distanceKm: distance,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Guardian')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.price_check, color: AppTheme.brandEnd),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Check a charge before you pay',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Tourism compares your amount against typical Indian '
                  'reference prices. It is an estimate, not proof of '
                  'overcharging.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Category',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: PriceCategory.values.map((PriceCategory c) {
              return ChoiceChip(
                label: Text(c.label),
                selected: _category == c,
                onSelected: (bool _) => setState(() => _category = c),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              labelText: 'Amount (₹)',
              prefixText: '₹ ',
              hintText: 'e.g. 800',
            ),
          ),
          if (_category.distanceBased) ...<Widget>[
            const SizedBox(height: 12),
            TextField(
              controller: _distance,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: 'Distance',
                suffixText: 'km',
                hintText: 'e.g. 5',
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Reference basis: ${_category.unitHint}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: 'Check price',
            icon: Icons.analytics_outlined,
            onPressed: _run,
          ),
          if (_result != null) ...<Widget>[
            const SizedBox(height: 20),
            _resultCard(_result!),
          ],
        ],
      ),
    );
  }

  Widget _resultCard(PriceCheckResult r) {
    final (IconData icon, Color color) = switch (r.verdict) {
      PriceVerdict.normal => (Icons.check_circle, AppTheme.success),
      PriceVerdict.low => (Icons.info_outline, AppTheme.warning),
      PriceVerdict.potentiallyHigh => (Icons.warning_amber_rounded, AppTheme.danger),
      PriceVerdict.needsMoreInfo => (Icons.help_outline, AppTheme.warning),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r.headline,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (r.referenceText.isNotEmpty)
            Text(
              r.referenceText,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          const SizedBox(height: 8),
          Text(r.explanation, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: PrimaryButton(
                  label: 'I\'m fine',
                  outlined: true,
                  onPressed: () => setState(() => _result = null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  label: 'Report concern',
                  danger: true,
                  onPressed: () => context.push('/incidents/report'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
