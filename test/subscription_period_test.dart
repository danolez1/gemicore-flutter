import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

void main() {
  group('SubscriptionPeriod.fromIso8601', () {
    test('reads the periods Google Play uses', () {
      expect(SubscriptionPeriod.fromIso8601('P1W'), const SubscriptionPeriod(1, PeriodUnit.week));
      expect(SubscriptionPeriod.fromIso8601('P1M'), const SubscriptionPeriod(1, PeriodUnit.month));
      expect(SubscriptionPeriod.fromIso8601('P3M'), const SubscriptionPeriod(3, PeriodUnit.month));
      expect(SubscriptionPeriod.fromIso8601('P6M'), const SubscriptionPeriod(6, PeriodUnit.month));
      expect(SubscriptionPeriod.fromIso8601('P1Y'), const SubscriptionPeriod(1, PeriodUnit.year));
      expect(SubscriptionPeriod.fromIso8601('P7D'), const SubscriptionPeriod(7, PeriodUnit.day));
    });

    test('a mixed period becomes months or days', () {
      expect(
        SubscriptionPeriod.fromIso8601('P1Y6M'),
        const SubscriptionPeriod(18, PeriodUnit.month),
      );
      expect(SubscriptionPeriod.fromIso8601('P1W2D'), const SubscriptionPeriod(9, PeriodUnit.day));
    });

    test('nothing usable is null', () {
      expect(SubscriptionPeriod.fromIso8601(null), isNull);
      expect(SubscriptionPeriod.fromIso8601(''), isNull);
      expect(SubscriptionPeriod.fromIso8601('P'), isNull);
      expect(SubscriptionPeriod.fromIso8601('P0D'), isNull);
      expect(SubscriptionPeriod.fromIso8601('1 month'), isNull);
      expect(SubscriptionPeriod.fromIso8601('PT1H'), isNull);
    });
  });

  test('months is the length used for a per month price', () {
    expect(const SubscriptionPeriod(1, PeriodUnit.year).months, 12);
    expect(const SubscriptionPeriod(6, PeriodUnit.month).months, 6);
    expect(const SubscriptionPeriod(1, PeriodUnit.week).months, closeTo(0.2308, 0.001));
    expect(const SubscriptionPeriod(30, PeriodUnit.day).months, closeTo(0.986, 0.001));
  });

  test('periods compare by value', () {
    expect(
      const SubscriptionPeriod(1, PeriodUnit.month),
      const SubscriptionPeriod(1, PeriodUnit.month),
    );
    expect(
      const SubscriptionPeriod(1, PeriodUnit.month) == const SubscriptionPeriod(1, PeriodUnit.week),
      isFalse,
    );
  });
}
