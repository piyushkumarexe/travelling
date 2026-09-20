import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../expense_math.dart';
import '../expense_models.dart';
import '../expense_repository.dart';

/// Expense history: search + filters (trip, category, date range, payment)
/// + sorting (newest/oldest/highest/lowest) over the user's saved expenses.
/// The repository keeps a bounded recent set (200) locally — large histories
/// page through Firestore as they scroll.
class ExpenseHistoryScreen extends StatefulWidget {
  const ExpenseHistoryScreen({super.key});

  @override
  State<ExpenseHistoryScreen> createState() => _ExpenseHistoryScreenState();
}

enum _SortBy { newest, oldest, highest, lowest }

class _ExpenseHistoryScreenState extends State<ExpenseHistoryScreen> {
  AppContainer get _c => AppScope.of(context);
  ExpenseRepository get _repo => _c.expenseRepository;

  String _query = '';
  String? _category;
  String? _tripId;
  bool _noTripOnly = false;
  String? _payment;
  DateTime? _from;
  DateTime? _to;
  _SortBy _sort = _SortBy.newest;

  List<Expense> get _filtered {
    final List<Expense> all = _repo.expenses;
    final String q = _query.trim().toLowerCase();
    Iterable<Expense> out = all;
    if (q.isNotEmpty) {
      out = out.where((Expense e) =>
          e.merchant.toLowerCase().contains(q) ||
          (e.notes ?? '').toLowerCase().contains(q) ||
          ExpenseCategory.of(e.category).label.toLowerCase().contains(q));
    }
    if (_category != null) {
      out = out.where((Expense e) => e.category == _category);
    }
    if (_noTripOnly) {
      out = out.where((Expense e) => e.tripId == null);
    } else if (_tripId != null) {
      out = out.where((Expense e) => e.tripId == _tripId);
    }
    if (_payment != null) {
      out = out.where((Expense e) => e.paymentMethod == _payment);
    }
    if (_from != null) {
      out = out.where((Expense e) => !e.expenseDate.isBefore(DateTime(
          _from!.year, _from!.month, _from!.day)));
    }
    if (_to != null) {
      out = out.where((Expense e) => !e.expenseDate.isAfter(DateTime(
          _to!.year, _to!.month, _to!.day, 23, 59, 59)));
    }
    final List<Expense> list = out.toList();
    switch (_sort) {
      case _SortBy.newest:
        list.sort((Expense a, Expense b) =>
            b.expenseDate.compareTo(a.expenseDate));
        break;
      case _SortBy.oldest:
        list.sort((Expense a, Expense b) =>
            a.expenseDate.compareTo(b.expenseDate));
        break;
      case _SortBy.highest:
        list.sort((Expense a, Expense b) => b.amount.compareTo(a.amount));
        break;
      case _SortBy.lowest:
        list.sort((Expense a, Expense b) => a.amount.compareTo(b.amount));
        break;
    }
    return list;
  }

  Future<void> _pickRange() async {
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
    );
    if (!mounted) return;
    if (range != null) {
      setState(() {
        _from = range.start;
        _to = range.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (BuildContext context, _) {
        final List<Expense> list = _filtered;
        final Map<String, double> totals =
            ExpenseMath.totalsByCurrency(list);
        return Scaffold(
          appBar: AppBar(title: const Text('Expense history')),
          body: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search merchant, notes, category…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (String v) => setState(() => _query = v),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: _category,
                          hint: const Text('Category'),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('All categories')),
                            for (final ExpenseCategory c in ExpenseCategory.all)
                              DropdownMenuItem<String?>(
                                  value: c.id,
                                  child: Text('${c.emoji} ${c.label}')),
                          ],
                          onChanged: (String? v) =>
                              setState(() => _category = v),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: _tripId,
                          hint: const Text('Trip'),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('All trips')),
                            const DropdownMenuItem<String?>(
                                value: '__none__', child: Text('No trip')),
                            for (final trip in _c.tripPlanStore.plans)
                              DropdownMenuItem<String?>(
                                  value: trip.id,
                                  child: Text(trip.destination)),
                          ],
                          onChanged: (String? v) => setState(() {
                            _noTripOnly = v == '__none__';
                            _tripId =
                                v == '__none__' ? null : v;
                          }),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: _payment,
                          hint: const Text('Payment'),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('Any payment')),
                            for (final String m in Expense.paymentMethods)
                              DropdownMenuItem<String?>(
                                  value: m, child: Text(m)),
                          ],
                          onChanged: (String? v) =>
                              setState(() => _payment = v),
                        ),
                      ),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.date_range, size: 16),
                      label: Text(_from == null
                          ? 'Dates'
                          : '${DateFormat('d MMM').format(_from!)} – '
                              '${DateFormat('d MMM').format(_to!)}'),
                      onPressed: _pickRange,
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.sort, size: 16),
                      label: Text(switch (_sort) {
                        _SortBy.newest => 'Newest',
                        _SortBy.oldest => 'Oldest',
                        _SortBy.highest => 'Highest',
                        _SortBy.lowest => 'Lowest',
                      }),
                      onPressed: () async {
                        final _SortBy? picked = await showDialog<_SortBy>(
                          context: context,
                          builder: (BuildContext ctx) => SimpleDialog(
                            title: const Text('Sort by'),
                            children: <Widget>[
                              for (final _SortBy s in _SortBy.values)
                                SimpleDialogOption(
                                  onPressed: () => Navigator.pop(ctx, s),
                                  child: Text(switch (s) {
                                    _SortBy.newest => 'Newest first',
                                    _SortBy.oldest => 'Oldest first',
                                    _SortBy.highest => 'Highest amount',
                                    _SortBy.lowest => 'Lowest amount',
                                  }),
                                ),
                            ],
                          ),
                        );
                        if (picked != null) setState(() => _sort = picked);
                      },
                    ),
                    if (_category != null ||
                        _from != null ||
                        _payment != null ||
                        _tripId != null ||
                        _noTripOnly)
                      IconButton(
                        tooltip: 'Clear filters',
                        icon: const Icon(Icons.filter_alt_off, size: 18),
                        onPressed: () => setState(() {
                          _category = null;
                          _from = null;
                          _to = null;
                          _payment = null;
                          _tripId = null;
                          _noTripOnly = false;
                        }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${list.length} expenses'
                    '${totals.isEmpty ? '' : ' · '}${totals.entries.map((MapEntry<String, double> e) => '₹${NumberFormat('#,##,##0.##').format(e.value)} ${e.key}').join(' + ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          _repo.expenses.isEmpty
                              ? 'No expenses saved yet.'
                              : 'No expenses match these filters.',
                          style:
                              Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: list.length,
                        itemBuilder: (BuildContext ctx, int i) {
                          final Expense e = list[i];
                          final String tripName = ExpenseMath.tripName(
                              _c.tripPlanStore.plans, e.tripId);
                          return Card(
                            margin:
                                const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              onTap: () => context.push('/expenses/detail',
                                  extra: <String, String>{'id': e.id}),
                              leading: Text(
                                  ExpenseCategory.of(e.category).emoji,
                                  style: const TextStyle(fontSize: 20)),
                              title: Text(e.merchant.isEmpty
                                  ? ExpenseCategory.of(e.category).label
                                  : e.merchant),
                              subtitle: Text(
                                '${DateFormat('d MMM yyyy').format(e.expenseDate)}'
                                '${e.paymentMethod == null ? '' : ' · ${e.paymentMethod}'}'
                                '${tripName.isEmpty ? '' : ' · $tripName'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                '₹${NumberFormat('#,##,##0.##').format(e.amount)}${e.currency == 'INR' ? '' : ' ${e.currency}'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

}
