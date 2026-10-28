import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/wallet_local_store.dart';
import '../../../data/models/wallet_entry.dart';

/// Trip budget and expense wallet. All data lives on-device (offline-first),
/// so the wallet works without any backend.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  AppContainer get _c => AppScope.of(context);

  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    try {
      await _c.walletStore.loadFor(uid ?? 'anon');
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _ready = true;
        });
      }
    }
  }

  static String _inr(double v) => '₹${v.toStringAsFixed(0)}';

  Future<void> _setBudget() async {
    final TextEditingController ctrl = TextEditingController(
      text: _c.walletStore.budget > 0
          ? _c.walletStore.budget.toStringAsFixed(0)
          : '',
    );
    final double? value = await showDialog<double>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Set trip budget'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: '₹ ',
            labelText: 'Total budget',
            hintText: 'e.g. 50000',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final double? v = double.tryParse(ctrl.text.trim());
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null && value >= 0) {
      await _c.walletStore.setBudget(value);
    }
  }

  Future<void> _editEntry({WalletEntry? existing}) async {
    final TextEditingController title =
        TextEditingController(text: existing?.title ?? '');
    final TextEditingController amount =
        TextEditingController(
            text: existing != null ? existing.amount.toStringAsFixed(2) : '');
    final TextEditingController notes =
        TextEditingController(text: existing?.notes ?? '');
    String category = existing?.category ?? 'Other';
    DateTime date = existing?.date ?? DateTime.now();

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add expense' : 'Edit expense'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    prefixText: '₹ ',
                    labelText: 'Amount',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: <DropdownMenuItem<String>>[
                    for (final String c in WalletEntry.categories)
                      DropdownMenuItem<String>(value: c, child: Text(c)),
                  ],
                  onChanged: (String? v) =>
                      setDialogState(() => category = v ?? category),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(Fmt.date(date)),
                  onTap: () async {
                    final DateTime? picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final double amt = double.tryParse(amount.text.trim()) ?? 0;
    if (title.text.trim().isEmpty || amt <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Enter a title and an amount greater than 0.')),
        );
      }
      return;
    }
    if (existing == null) {
      await _c.walletStore.add(WalletEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: title.text.trim(),
        category: category,
        amount: amt,
        date: date,
        notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
      ));
    } else {
      await _c.walletStore.update(WalletEntry(
        id: existing.id,
        title: title.text.trim(),
        category: category,
        amount: amt,
        date: date,
        notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
      ));
    }
  }

  Future<void> _deleteEntry(WalletEntry e) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete expense?'),
        content: Text('"${e.title}" — ${_inr(e.amount)} will be removed.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _c.walletStore.remove(e.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget & wallet'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Add expense',
            icon: const Icon(Icons.add),
            onPressed: () => _editEntry(),
          ),
        ],
      ),
      body: !_ready
          ? const LoadingView(message: 'Loading wallet…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _content(),
    );
  }

  Widget _content() {
    final WalletLocalStore store = _c.walletStore;
    final bool hasBudget = store.budget > 0;
    final double spent = store.totalSpent;
    final double remaining = store.budget - spent;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        AppCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Trip budget',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _setBudget,
                    icon: const Icon(Icons.edit, size: 16),
                    label: Text(hasBudget ? 'Edit' : 'Set'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                hasBudget ? _inr(store.budget) : 'Not set yet',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: hasBudget
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                    ),
              ),
              if (hasBudget) ...<Widget>[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: store.budget <= 0
                        ? 0
                        : (spent / store.budget).clamp(0.0, 1.0),
                    minHeight: 10,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    color: remaining < 0 ? AppTheme.danger : AppTheme.success,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(child: _stat('Spent', _inr(spent))),
                    Expanded(
                      child: _stat(
                        'Remaining',
                        _inr(remaining),
                        color: remaining < 0
                            ? AppTheme.danger
                            : AppTheme.success,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (store.perCategory.isNotEmpty) ...<Widget>[
          AppCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('By category',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                for (final MapEntry<String, double> e
                    in store.perCategory.entries) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(child: Text(e.key)),
                        Text(_inr(e.value),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Expenses (${store.entries.length})',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (store.entries.isEmpty)
          EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'No expenses yet',
            message:
                'Add your first expense to start tracking the trip budget.',
            actionLabel: 'Add expense',
            onAction: () => _editEntry(),
          )
        else
          for (final WalletEntry e in store.entries)
            _entryTile(e),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
        ),
      ],
    );
  }

  Widget _entryTile(WalletEntry e) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: CircleAvatar(
          backgroundColor: scheme.primary.withValues(alpha: 0.10),
          child: Icon(Icons.receipt_long, color: scheme.primary, size: 20),
        ),
        title: Text(e.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${e.category} · ${Fmt.date(e.date)}'
          '${e.notes != null ? '\n${e.notes}' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(_inr(e.amount),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            PopupMenuButton<String>(
              onSelected: (String v) {
                if (v == 'edit') _editEntry(existing: e);
                if (v == 'delete') _deleteEntry(e);
              },
              itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
                PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}
