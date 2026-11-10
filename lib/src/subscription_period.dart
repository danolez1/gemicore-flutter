enum PeriodUnit { day, week, month, year }

/// How long a subscription renews for or a trial lasts, as the store reports it.
class SubscriptionPeriod {
  const SubscriptionPeriod(this.value, this.unit);

  final int value;
  final PeriodUnit unit;

  static final _iso = RegExp(r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$');

  /// Parses Google Play's billing period ("P1W", "P1M", "P6M", "P1Y"). A mixed period such as "P1Y6M"
  /// becomes months, one with weeks and days becomes days; anything else is null.
  static SubscriptionPeriod? fromIso8601(String? iso) {
    final match = iso == null ? null : _iso.firstMatch(iso);
    if (match == null) return null;
    final years = int.tryParse(match.group(1) ?? '') ?? 0;
    final months = int.tryParse(match.group(2) ?? '') ?? 0;
    final weeks = int.tryParse(match.group(3) ?? '') ?? 0;
    final days = int.tryParse(match.group(4) ?? '') ?? 0;
    final calendarMonths = years * 12 + months;
    if (calendarMonths > 0 && weeks == 0 && days == 0) {
      if (months == 0) return SubscriptionPeriod(years, PeriodUnit.year);
      return SubscriptionPeriod(calendarMonths, PeriodUnit.month);
    }
    if (calendarMonths == 0 && weeks > 0 && days == 0) {
      return SubscriptionPeriod(weeks, PeriodUnit.week);
    }
    if (calendarMonths == 0 && weeks == 0 && days > 0) {
      return SubscriptionPeriod(days, PeriodUnit.day);
    }
    final totalDays = years * 365 + months * 30 + weeks * 7 + days;
    return totalDays > 0 ? SubscriptionPeriod(totalDays, PeriodUnit.day) : null;
  }

  /// The length in months, only for working out a per month price.
  double get months => switch (unit) {
    PeriodUnit.day => value * 12 / 365,
    PeriodUnit.week => value * 12 / 52,
    PeriodUnit.month => value.toDouble(),
    PeriodUnit.year => value * 12.0,
  };

  @override
  bool operator ==(Object other) =>
      other is SubscriptionPeriod && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'SubscriptionPeriod($value ${unit.name})';
}
