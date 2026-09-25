import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../expense_math.dart';
import '../expense_icons.dart';
import '../expense_models.dart';
import '../expense_repository.dart';

/// Expense details: view everything, edit, delete (with receipt cleanup),
/// and see the saved split settlements ("You paid / Others owe you").
class ExpenseDetailScreen extends StatefulWidget {
  const ExpenseDetailScreen({super.key, required this.expenseId});

  final String expenseId;

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  AppContainer get _c => AppScope.of(context);
  ExpenseRepository get _repo => _c.expenseRepository;

  Future<void> _delete(Expense e) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete expense?'),
        content: Text(
            '₹${e.amount.toStringAsFixed(2)} — ${e.merchant.isEmpty ? ExpenseCategory.of(e.category).label : e.merchant}\n'
            'The saved record and its receipt photo will be removed.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteExpense(e.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (BuildContext context, _) {
        final Expense? e = _repo.expenses
            .where((Expense x) => x.id == widget.expenseId)
            .firstOrNull;
        if (e == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This expense was deleted.')),
          );
        }
        final String tripName =
            ExpenseMath.tripName(_c.tripPlanStore.plans, e.tripId);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Expense details'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  await context
                      .push('/expenses/add', extra: <String, dynamic>{
                    'expense': e,
                  });
                },
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(e),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Center(
                child: Text(
                  '₹${NumberFormat('#,##,##0.##').format(e.amount)}'
                  '${e.currency == 'INR' ? '' : ' ${e.currency}'}',
                  style: Theme.of(context)
                      .textTheme
                      .headlineLarge
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(ExpenseCategory.of(e.category).icon, size: 19),
                    const SizedBox(width: 6),
                    Text(ExpenseCategory.of(e.category).label),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _row('Merchant / description',
                  e.merchant.isEmpty ? '—' : e.merchant),
              _row('Date & time',
                  DateFormat('EEE, d MMM yyyy, h:mm a').format(e.expenseDate)),
              _row('Trip', tripName.isEmpty ? '—' : tripName),
              _row('Payment', e.paymentMethod ?? '—'),
              _row('Notes', e.notes ?? '—'),
              _row('Location',
                  e.latitude == null ? '—' : '${e.latitude!.toStringAsFixed(4)}, ${e.longitude!.toStringAsFixed(4)}'),
              _row('Saved',
                  e.sync == ExpenseSync.synced
                      ? 'Synced to your account'
                      : e.sync == ExpenseSync.syncing
                          ? 'Syncing…'
                          : 'Saved locally — will sync automatically'),
              const SizedBox(height: 12),
              if (e.receiptUrl != null) ...<Widget>[
                Text('Receipt',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    e.receiptUrl!,
                    height: 220,
                    fit: BoxFit.cover,
                    loadingBuilder: (BuildContext ctx, Widget child,
                            ImageChunkEvent? progress) =>
                        progress == null
                            ? child
                            : const Padding(
                                padding: EdgeInsets.all(24),
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                    errorBuilder: (_, __, ___) => const Text(
                        'Receipt image could not be loaded.',
                        style: TextStyle(color: AppTheme.danger)),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (e.splits.isNotEmpty) ...<Widget>[
                Text('Split (${e.splits.length} people)',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: <Widget>[
                        for (final SplitParticipant p in e.splits)
                          Row(
                            children: <Widget>[
                              Expanded(
                                  child: Text(p.isSelf ? 'You' : p.name)),
                              Text('₹${p.amount.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _settlementRow(e),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _settlementRow(Expense e) {
    final bool selfPaid = e.splits.any((SplitParticipant p) => p.isSelf);
    final double others = e.splits
        .where((SplitParticipant p) => !p.isSelf)
        .fold(0, (double s, SplitParticipant p) => s + p.amount);
    return Card(
      color: AppTheme.success.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          selfPaid
              ? 'You paid ₹${e.amount.toStringAsFixed(2)} — others owe you ₹${others.toStringAsFixed(2)}'
              : 'Someone else paid — you owe ₹${others.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
              width: 150,
              child: Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
