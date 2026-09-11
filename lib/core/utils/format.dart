import 'package:intl/intl.dart';

/// Formatting helpers.

class Fmt {
  Fmt._();

  static String date(DateTime d) => DateFormat('MMM d, yyyy').format(d);

  static String dateTime(DateTime d) =>
      DateFormat('MMM d, yyyy · HH:mm').format(d);

  static String time(DateTime d) => DateFormat.Hm().format(d);

  static String weekday(DateTime d) => DateFormat('EEEE').format(d);

  static String relative(DateTime d) {
    final Duration diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return date(d);
  }
}
