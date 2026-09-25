import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../expense_math.dart';
import '../expense_icons.dart';
import '../expense_models.dart';
import '../expense_repository.dart';

/// 💰 TRAVEL EXPENSE GUARD — "Track every rupee of your trip."
///
/// Dashboard: totals per currency (never mixed — no conversion service),
/// today's spend, budget with 80/100% warnings, category breakdown,
/// deterministic insights, recent expenses. Local-cache-first, then live
/// Firestore refresh.
class ExpenseGuardScreen extends StatefulWidget {
  const ExpenseGuardScreen({super.key});

  @override
  State<ExpenseGuardScreen> createState() => _ExpenseGuardScreenState();
}

class _ExpenseGuardScreenState extends State<ExpenseGuardScreen> {
  AppContainer get _c => AppScope.of(context);
  ExpenseRepository get _repo => _c.expenseRepository;

  @override
  void initState() {
    super.initState();
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      _repo.start(uid);
      // Trips live in the existing local store; make sure they're loaded
      // so expenses can link to them.
      _c.tripPlanStore.loadFor(uid).catchError((Object _) {});
    }
  }

  String _primaryCurrency(List<Expense> all) {
    final Map<String, double> totals = ExpenseMath.totalsByCurrency(all);
    if (totals.isEmpty) return 'INR';
    String best = 'INR';
    double bestV = -1;
    totals.forEach((String k, double v) {
      if (v > bestV) {
        best = k;
        bestV = v;
      }
    });
    return best;
  }

  Future<void> _openBudgetEditor() async {
    final double? currentDaily = _repo.budget.daily;
    final TextEditingController daily = TextEditingController(
        text: currentDaily == null ? '' : currentDaily.toStringAsFixed(0));
    final BudgetConfig? result = await showModalBottomSheet<BudgetConfig>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => Padding(
        padding:
            EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Set budget',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Text('Optional — daily budget applies to every day.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: daily,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Daily budget (₹/${_repo.budget.currency})',
                hintText: 'e.g. 1500',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final double? d = double.tryParse(daily.text.trim());
                  Navigator.pop(
                      ctx,
                      BudgetConfig(
                        daily: d,
                        perTrip: _repo.budget.perTrip,
                        currency: _repo.budget.currency,
                      ));
                },
                child: const Text('Save budget'),
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await _repo.saveBudget(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (BuildContext context, _) {
        final List<Expense> all = _repo.expenses;
        final String cur = _primaryCurrency(all);
        final double total = ExpenseMath.totalFor(all, cur);
        final double today =
            ExpenseMath.todayTotal(all, DateTime.now(), cur);
        final List<(String, double)> cats =
            ExpenseMath.categoryTotals(all, cur);

        return Scaffold(
          appBar: AppBar(title: const Text('Travel Expense Guard')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.push('/expenses/add'),
            icon: const Icon(Icons.add),
            label: const Text('Add Expense'),
          ),
          body: all.isEmpty && !_repo.ready
              ? const LoadingView(message: 'Loading your expenses…')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: <Widget>[
                    _syncBar(),
                    _totalCard(total, today, cur),
                    _budgetCard(all, cur),
                    const SizedBox(height: 12),
                    if (cats.isNotEmpty) ...<Widget>[
                      _section('Category breakdown'),
                      _categoryCard(cats, total, cur),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 12),
                    _section('Insights'),
                    _insightCard(all, cur),
                    const SizedBox(height: 12),
                    _section('Recent expenses'),
                    if (all.isEmpty)
                      const EmptyState(
                        icon: Icons.receipt_long,
                        title: 'No expenses yet',
                        message:
                            'Tap "Add Expense" — amount and category is '
                            'all you need. Receipts, trips and notes are '
                            'optional.',
                      )
                    else
                      for (final Expense e in all.take(10))
                        _expenseTile(e),
                    const SizedBox(height: 8),
                    if (all.length > 10)
                      TextButton.icon(
                        onPressed: () => context.push('/expenses/history'),
                        icon: const Icon(Icons.history),
                        label: Text(
                            'See all ${all.length} expenses · search & filters'),
                      ),
                    for (final MapEntry<String, double> other
                        in ExpenseMath.totalsByCurrency(all).entries)
                      if (other.key != cur && all.length <= 10)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              '${other.key}: ${other.value.toStringAsFixed(2)} '
                              '(shown separately — rates are not invented)',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                        ),
                    // Temporary build identifier so the installed APK can be
                    // verified on device (remove after confirmation).
                    const SizedBox(height: 18),
                    const Center(
                      child: Text('TRAVEL-EXPENSE-GUARD-2026-09-13-01',
                          style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              letterSpacing: 0.5)),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  Widget _syncBar() {
    if (_repo.pendingOps == 0 && _repo.lastError == null) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.sync_problem, size: 16, color: Color(0xFFB26A00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _repo.syncing
                  ? 'Syncing…'
                  : '${_repo.pendingOps} change(s) saved locally — will sync '
                      'when the network is back.${_repo.lastError == null ? '' : ' ${_repo.lastError}'}',
              style:
                  const TextStyle(fontSize: 12, color: Color(0xFFB26A00)),
            ),
          ),
          if (!_repo.syncing)
            TextButton(
              onPressed: () => _repo.syncNow(),
              child: const Text('Sync now',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
        ],
      ),
    );
  }

  Widget _totalCard(double total, double today, String cur) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('TOTAL SPENT ($cur)',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                '₹${NumberFormat('#,##,##0.##').format(total)}',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('Today: ₹${NumberFormat('#,##,##0.##').format(today)} $cur',
                style: Theme.of(context).textTheme.bodyMedium),
            TextButton.icon(
              onPressed: () => context.push('/expenses/history'),
              icon: const Icon(Icons.history, size: 16),
              label: const Text('History, filters & splits'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _budgetCard(List<Expense> all, String cur) {
    final double? daily = _repo.budget.daily;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Budget',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _openBudgetEditor,
                    icon: const Icon(Icons.edit, size: 14),
                    label: const Text('Set'),
                  ),
                ],
              ),
              if (daily == null)
                const Text('No daily budget set yet — tap "Set" to add one.',
                    style: TextStyle(fontSize: 12.5))
              else ...<Widget>[
                ..._budgetRows(daily, all, cur),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _budgetRows(double daily, List<Expense> all, String cur) {
    final double todaySpent =
        ExpenseMath.todayTotal(all, DateTime.now(), cur);
    final ({double spent, double remaining, double usedPct, bool over}) st =
        ExpenseMath.budgetState(budget: daily, spent: todaySpent);
    final bool warn = st.usedPct >= 80;
    final Color color =
        st.over ? AppTheme.danger : (warn ? AppTheme.warning : AppTheme.success);
    return <Widget>[
      Text('Daily: ₹${daily.toStringAsFixed(0)} $cur',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      LinearProgressIndicator(
        value: (st.usedPct / 100).clamp(0, 1),
        color: color,
        backgroundColor: color.withValues(alpha: 0.15),
      ),
      const SizedBox(height: 6),
      Text(
        '₹${NumberFormat('#,##,##0.##').format(st.spent)} spent · '
        '${st.over ? '₹${(-st.remaining).toStringAsFixed(0)} over' : '₹${NumberFormat('#,##,##0.##').format(st.remaining)} remaining'} · '
        '${st.usedPct.round()}% used',
        style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
      ),
      if (warn && !st.over)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('⚠️ You are close to your daily budget (80%+).',
              style: TextStyle(fontSize: 12, color: AppTheme.warning)),
        ),
      if (st.over)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('You have crossed today\'s budget.',
              style: TextStyle(fontSize: 12, color: AppTheme.danger)),
        ),
    ];
  }

  Widget _categoryCard(List<(String, double)> cats, double total, String cur) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: <Widget>[
            for (final (String, double) c in cats.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Icon(ExpenseCategory.of(c.$1).icon, size: 18),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 92,
                      child: Text(ExpenseCategory.of(c.$1).label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: total <= 0 ? 0 : (c.$2 / total).clamp(0, 1),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        '₹${NumberFormat('#,##,##0.##').format(c.$2)}',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _insightCard(List<Expense> all, String cur) {
    final List<String> tips = ExpenseMath.insights(all, DateTime.now(), cur);
    if (tips.isEmpty) return const SizedBox.shrink();
    return Card(
      color: AppTheme.success.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Summary (from your saved expenses)',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final String t in tips)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('· $t',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _expenseTile(Expense e) {
    final String tripName =
        ExpenseMath.tripName(_c.tripPlanStore.plans, e.tripId);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () =>
            context.push('/expenses/detail', extra: <String, String>{'id': e.id}),
        leading: Icon(ExpenseCategory.of(e.category).icon),
        title: Text(e.merchant.isEmpty
            ? ExpenseCategory.of(e.category).label
            : e.merchant),
        subtitle: Text(
          '${DateFormat('d MMM').format(e.expenseDate)}'
          '${tripName.isEmpty ? '' : ' · $tripName'}'
          '${e.splits.isEmpty ? '' : ' · split ${e.splits.length} ways'}'
          '${e.sync == ExpenseSync.synced ? '' : ' · ${e.sync.name}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          '₹${NumberFormat('#,##,##0.##').format(e.amount)}${e.currency == 'INR' ? '' : ' ${e.currency}'}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
      ),
    );
  }
}
