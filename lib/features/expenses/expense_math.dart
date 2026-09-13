import '../data/models/trip_plan.dart';
import 'expense_models.dart';

/// TRAVEL EXPENSE GUARD — deterministic calculations from REAL saved data.
/// No AI, no invented numbers: every function here is pure and unit-tested.

class ExpenseMath {
  ExpenseMath._();

  /// Totals grouped BY CURRENCY — never mixed (no conversion service).
  static Map<String, double> totalsByCurrency(List<Expense> expenses) {
    final Map<String, double> out = <String, double>{};
    for (final Expense e in expenses) {
      if (e.pendingDelete) continue;
      out[e.currency] = (out[e.currency] ?? 0) + e.amount;
    }
    return out;
  }

  static double totalFor(List<Expense> expenses, String currency) =>
      totalsByCurrency(expenses)[currency] ?? 0;

  /// Same calendar-day total in [currency] (uses the device's local day).
  static double todayTotal(List<Expense> expenses, DateTime now,
      String currency) {
    double sum = 0;
    for (final Expense e in expenses) {
      if (e.pendingDelete || e.currency != currency) continue;
      if (e.expenseDate.year == now.year &&
          e.expenseDate.month == now.month &&
          e.expenseDate.day == now.day) {
        sum += e.amount;
      }
    }
    return sum;
  }

  /// Category -> total (for one currency), highest first.
  static List<(String, double)> categoryTotals(
      List<Expense> expenses, String currency) {
    final Map<String, double> sums = <String, double>{};
    for (final Expense e in expenses) {
      if (e.pendingDelete || e.currency != currency) continue;
      sums[e.category] = (sums[e.category] ?? 0) + e.amount;
    }
    final List<(String, double)> out = sums.entries
        .map((MapEntry<String, double> e) => (e.key, e.value))
        .toList()
      ..sort(((_, double a), (_, double b)) => b.compareTo(a));
    return out;
  }

  /// Budget remaining + percent used from ACTUAL saved expenses.
  static ({double spent, double remaining, double usedPct, bool over})
      budgetState({
    required double budget,
    required double spent,
  }) {
    final double remaining = budget - spent;
    final double pct = budget <= 0 ? 100 : (spent / budget * 100);
    return (
      spent: spent,
      remaining: remaining,
      usedPct: pct.clamp(0, 999),
      over: remaining < 0,
    );
  }

  /// Daily budget: expenses fall on trip days [start, start+days] or simply
  /// "today" when no trip — evaluated per calendar day against [daily].
  static ({double todaySpent, double remainingToday, double usedPct})
      dailyBudgetState({
    required double daily,
    required List<Expense> expenses,
    required DateTime now,
    required String currency,
  }) {
    final double spent = todayTotal(expenses, now, currency);
    return (
      todaySpent: spent,
      remainingToday: daily - spent,
      usedPct: daily <= 0 ? 100.0 : (spent / daily * 100).clamp(0, 999),
    );
  }

  /// Deterministic insight strings from real data only.
  static List<String> insights(
      List<Expense> expenses, DateTime now, String currency) {
    final List<String> out = <String>[];
    final List<Expense> live =
        expenses.where((Expense e) => !e.pendingDelete).toList();
    if (live.isEmpty) return out;

    final double today = todayTotal(live, now, currency);
    if (today > 0) {
      out.add('You spent ${_fmt(today)} $currency today.');
    }

    final List<(String, double)> cats = categoryTotals(live, currency);
    if (cats.isNotEmpty) {
      final double grand = cats.fold(0, (double s, (String, double) c) => s + c.$2);
      if (grand > 0 && cats.first.$2 / grand >= 0.4 && cats.length > 1) {
        out.add('${ExpenseCategory.of(cats.first.$1).label} is your highest '
            'expense category (${_fmt(cats.first.$2)} $currency).');
      }
    }

    // Busiest day this week (last 7 days).
    final Map<String, double> byDay = <String, double>{};
    for (final Expense e in live) {
      if (e.currency != currency) continue;
      if (now.difference(e.expenseDate).inDays > 7) continue;
      final String key =
          '${e.expenseDate.year}-${e.expenseDate.month}-${e.expenseDate.day}';
      byDay[key] = (byDay[key] ?? 0) + e.amount;
    }
    if (byDay.length > 1) {
      final MapEntry<String, double> top =
          byDay.entries.reduce((MapEntry<String, double> a,
                  MapEntry<String, double> b) =>
              a.value >= b.value ? a : b);
      if (top.value > 0) {
        out.add('Your biggest spending day this week was '
            '${top.key.replaceAll('-', '/')} '
            '(${_fmt(top.value)} $currency).');
      }
    }
    return out;
  }

  /// ----------------------------------------------
  /// Splits — validation BEFORE saving; settlements from saved data only.
  /// ----------------------------------------------

  /// Equal split shares; remainder cents go to the payer.
  static List<SplitParticipant> equalSplit({
    required double amount,
    required List<String> names,
    required String selfName,
  }) {
    if (names.isEmpty || amount <= 0) return const <SplitParticipant>[];
    final double each =
        ((amount * 100).round() / names.length / 100);
    final List<SplitParticipant> out = <SplitParticipant>[];
    double assigned = 0;
    for (int i = 0; i < names.length; i++) {
      final bool self = names[i] == selfName;
      // Last participant absorbs the rounding remainder.
      double share = each;
      if (i == names.length - 1) {
        share = double.parse(
            (amount - assigned).toStringAsFixed(2));
      }
      assigned += share;
      out.add(SplitParticipant(
          name: names[i], amount: share, isSelf: self));
    }
    return out;
  }

  /// Validates a custom split BEFORE save: shares must sum to the expense
  /// amount (±0.01 for rounding) and every share must be positive.
  static String? validateSplit(double amount, List<SplitParticipant> parts) {
    if (parts.isEmpty) return 'Add at least one participant.';
    if (parts.any((SplitParticipant p) =>
        p.name.trim().isEmpty || p.amount <= 0)) {
      return 'Every participant needs a name and a positive amount.';
    }
    final double sum =
        parts.fold(0, (double s, SplitParticipant p) => s + p.amount);
    if ((sum - amount).abs() > 0.01) {
      return 'Split amounts (${sum.toStringAsFixed(2)}) must equal the '
          'expense amount (${amount.toStringAsFixed(2)}).';
    }
    return null;
  }

  /// "You paid / Others owe you / You owe" — from SAVED split data only.
  /// The payer is the expense owner (isSelf participant).
  static ({double othersOwe, double youOwe}) splitSettlement(
      List<Expense> expenses, String selfName) {
    double othersOwe = 0;
    double youOwe = 0;
    for (final Expense e in expenses) {
      if (e.pendingDelete || e.splits.isEmpty) continue;
      final bool selfPaid =
          e.splits.any((SplitParticipant p) => p.isSelf);
      for (final SplitParticipant p in e.splits) {
        if (p.isSelf) continue;
        if (selfPaid) {
          othersOwe += p.amount; // someone else owes the payer (you)
        } else {
          youOwe += p.amount; // you owe for something you didn't pay
        }
      }
      // When you paid AND are part of the split, your own share is excluded
      // from "others owe" by the isSelf check above.
      if (selfName.isEmpty) continue;
    }
    return (othersOwe: othersOwe, youOwe: youOwe);
  }

  /// Group expenses by their linked trip (for trip-scoped dashboards).
  static List<Expense> forTrip(List<Expense> expenses, String tripId) =>
      expenses
          .where((Expense e) => !e.pendingDelete && e.tripId == tripId)
          .toList();

  /// Trip name lookup WITHOUT duplicating trip data (existing local store).
  static String tripName(List<TripPlan> plans, String? tripId) {
    if (tripId == null) return '';
    for (final TripPlan p in plans) {
      if (p.id == tripId) return p.destination;
    }
    return '';
  }

  static String _fmt(double v) {
    final bool whole = v == v.roundToDouble();
    return whole
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);
  }
}
