import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/expenses/expense_math.dart';
import 'package:yatrawise/features/expenses/expense_models.dart';

Expense _e(
  String id,
  double amount,
  String currency,
  String category,
  DateTime when, {
  List<SplitParticipant> splits = const <SplitParticipant>[],
  String? tripId,
}) {
  return Expense(
    id: id,
    userId: 'u1',
    amount: amount,
    currency: currency,
    category: category,
    merchant: 'm$id',
    expenseDate: when,
    createdAt: when,
    updatedAt: when,
    splits: splits,
    tripId: tripId,
  );
}

void main() {
  final DateTime now = DateTime(2026, 9, 13, 18, 0);

  test('totals never mix currencies', () {
    final List<Expense> list = <Expense>[
      _e('1', 100, 'INR', 'food', now),
      _e('2', 50, 'INR', 'food', now),
      _e('3', 20, 'USD', 'tickets', now),
    ];
    final Map<String, double> t = ExpenseMath.totalsByCurrency(list);
    expect(t['INR'], 150);
    expect(t['USD'], 20);
    expect(ExpenseMath.totalFor(list, 'EUR'), 0);
  });

  test('today total uses the local calendar day only', () {
    final List<Expense> list = <Expense>[
      _e('1', 120, 'INR', 'food', now),
      _e('2', 80, 'INR', 'fuel', now.subtract(const Duration(hours: 30))),
      _e('3', 10, 'INR', 'other', now.add(const Duration(minutes: 5))),
    ];
    expect(ExpenseMath.todayTotal(list, now, 'INR'), 130);
  });

  test('category breakdown ranks highest first (single currency)', () {
    final List<Expense> list = <Expense>[
      _e('1', 100, 'INR', 'food', now),
      _e('2', 300, 'INR', 'stay', now),
      _e('3', 50, 'INR', 'food', now),
    ];
    final List<(String, double)> cats =
        ExpenseMath.categoryTotals(list, 'INR');
    expect(cats.first, ('stay', 300.0));
    expect(cats[1].$1, 'food');
    expect(cats[1].$2, 150);
  });

  test('budget state: spent / remaining / percent / over', () {
    final st = ExpenseMath.budgetState(budget: 1000, spent: 4250 * 0.0 + 250);
    expect(st.remaining, 750);
    expect(st.usedPct, 25);
    expect(st.over, isFalse);
    final over = ExpenseMath.budgetState(budget: 500, spent: 600);
    expect(over.over, isTrue);
    expect(over.remaining, -100);
  });

  test('equal split distributes with remainder to the last participant', () {
    final List<SplitParticipant> parts = ExpenseMath.equalSplit(
        amount: 100, names: <String>['Me', 'A', 'B'], selfName: 'Me');
    final double sum =
        parts.fold(0, (double s, SplitParticipant p) => s + p.amount);
    expect((sum - 100).abs() < 0.01, isTrue);
    expect(parts.first.isSelf, isTrue);
  });

  test('split validation: sums must match before saving', () {
    final List<SplitParticipant> bad = const <SplitParticipant>[
      SplitParticipant(name: 'Me', amount: 60, isSelf: true),
      SplitParticipant(name: 'A', amount: 30),
    ];
    expect(ExpenseMath.validateSplit(100, bad), contains('must equal'));
    final List<SplitParticipant> zero = const <SplitParticipant>[
      SplitParticipant(name: 'Me', amount: 100, isSelf: true),
      SplitParticipant(name: 'A', amount: 0),
    ];
    expect(ExpenseMath.validateSplit(100, zero), isNotNull);
    final List<SplitParticipant> good = const <SplitParticipant>[
      SplitParticipant(name: 'Me', amount: 60, isSelf: true),
      SplitParticipant(name: 'A', amount: 40),
    ];
    expect(ExpenseMath.validateSplit(100, good), isNull);
  });

  test('settlements come only from saved split data', () {
    // The recorded expense owner is the payer; isSelf marks the owner's own
    // share.
    final List<Expense> list = <Expense>[
      // You paid 120, your share 60 -> others owe you 40+20 = 60.
      _e('1', 120, 'INR', 'food', now, splits: const <SplitParticipant>[
        SplitParticipant(name: 'You', amount: 60, isSelf: true),
        SplitParticipant(name: 'A', amount: 40),
        SplitParticipant(name: 'B', amount: 20),
      ]),
      // You paid 200, your share 50 -> C owes you 150.
      _e('2', 200, 'INR', 'tickets', now, splits: const <SplitParticipant>[
        SplitParticipant(name: 'C', amount: 150),
        SplitParticipant(name: 'You', amount: 50, isSelf: true),
      ]),
    ];
    final r = ExpenseMath.splitSettlement(list, 'You');
    expect(r.othersOwe, 210);
    expect(r.youOwe, 0);
  });

  test('insights are deterministic strings from real data', () {
    final List<Expense> list = <Expense>[
      _e('1', 1240, 'INR', 'food', now),
      _e('2', 200, 'INR', 'fuel', now.subtract(const Duration(days: 1))),
    ];
    final List<String> tips = ExpenseMath.insights(list, now, 'INR');
    expect(tips.join(' '), contains('You spent 1240 INR today'));
    expect(tips.join(' '), contains('highest expense category'));
  });

  test('pending deletes are excluded from every calculation', () {
    final Expense ghost =
        _e('g', 999, 'INR', 'other', now).copyWith(pendingDelete: true);
    expect(ExpenseMath.totalFor(<Expense>[ghost], 'INR'), 0);
  });
}
