/// Form validation helpers shared by all forms.

class Validators {
  Validators._();

  static String? requiredText(String? value, {int min = 1, int max = 5000}) {
    final String v = (value ?? '').trim();
    if (v.length < min) return 'This field is required.';
    if (v.length > max) return 'Keep it under $max characters.';
    return null;
  }

  static String? description(String? value, {int min = 10, int max = 2000}) {
    final String v = (value ?? '').trim();
    if (v.length < min) {
      return 'Describe the incident (at least $min characters).';
    }
    if (v.length > max) return 'Keep it under $max characters.';
    return null;
  }

  static bool isPhone(String? value) {
    final String v = (value ?? '').replaceAll(RegExp(r'[\s\-().]'), '');
    if (!RegExp(r'^\+?[0-9]+$').hasMatch(v)) return false;
    final int digits = v.replaceAll('+', '').length;
    return digits >= 7 && digits <= 15;
  }

  static String? phone(String? value) =>
      isPhone(value) ? null : 'Enter a valid phone number (e.g. +91 98765 43210).';

  static bool isLat(double? v) => v != null && v >= -90 && v <= 90;

  static bool isLng(double? v) => v != null && v >= -180 && v <= 180;

  static String? latText(String? value) {
    final double? v = double.tryParse((value ?? '').trim().replaceAll(',', '.'));
    return isLat(v) ? null : 'Enter a latitude between -90 and 90.';
  }

  static String? lngText(String? value) {
    final double? v = double.tryParse((value ?? '').trim().replaceAll(',', '.'));
    return isLng(v) ? null : 'Enter a longitude between -180 and 180.';
  }

  static String? radiusText(String? value) {
    final double? v = double.tryParse((value ?? '').trim());
    if (v == null || v < 100 || v > 10000) {
      return 'Radius must be between 100 and 10,000 meters.';
    }
    return null;
  }

  static String? daysText(String? value) {
    final int? v = int.tryParse((value ?? '').trim());
    if (v == null || v < 1 || v > 10) return 'Pick 1–10 days.';
    return null;
  }
}
