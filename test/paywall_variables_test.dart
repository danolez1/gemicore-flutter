import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter/src/paywall_variables.dart';

import 'fakes.dart';

Package packageOf(
  StoreProductDetails? details, {
  PackageType type = PackageType.monthly,
  String? priceString,
}) => Package(
  identifier: 'p',
  packageType: type,
  product: GemicoreProduct(
    identifier: 'pro',
    type: ProductType.subscription,
    title: 'Pro',
    priceString: priceString ?? details?.price,
    rawPrice: details?.rawPrice,
    currencyCode: details?.currencyCode,
    storeDetails: details,
  ),
);

PackageVariables variables(Package package, {String strings = 'en', String numbers = 'en_US'}) {
  final number = numbers.split('_');
  return PackageVariables.of(
    package,
    stringsLocale: Locale(strings),
    numberLocale: Locale(number.first, number.length > 1 ? number[1] : null),
  );
}

void main() {
  group('PackageVariables', () {
    test('a monthly subscription with a trial resolves all four', () {
      final v = variables(
        packageOf(
          storeDetail('x', period: monthly, trial: const SubscriptionPeriod(7, PeriodUnit.day)),
        ),
      );
      expect(v['package.price'], '\$4.99');
      expect(v['package.period'], 'month');
      expect(v['package.trial'], '7 days');
      expect(v['package.pricePerMonth'], '\$4.99');
    });

    test('an annual price is divided by twelve for the per month figure', () {
      final v = variables(
        packageOf(storeDetail('x', price: '\$39.99', rawPrice: 39.99, period: annual)),
      );
      expect(v['package.period'], 'year');
      expect(v['package.pricePerMonth'], '\$3.33');
      expect(v['package.trial'], isNull);
    });

    test('a weekly price is scaled up to a month', () {
      final v = variables(
        packageOf(
          storeDetail(
            'x',
            price: '\$1.99',
            rawPrice: 1.99,
            period: const SubscriptionPeriod(1, PeriodUnit.week),
          ),
        ),
      );
      expect(v['package.period'], 'week');
      expect(v['package.pricePerMonth'], '\$8.62');
    });

    test('the per month figure is written the way the device writes numbers', () {
      final details = storeDetail('x', price: '39,99 \$', rawPrice: 39.99, period: annual);
      expect(
        variables(packageOf(details), numbers: 'de_DE')['package.pricePerMonth'],
        contains('3,33'),
      );
      expect(variables(packageOf(details), numbers: 'en_US')['package.pricePerMonth'], '\$3.33');
    });

    test('a period of several units counts them', () {
      final v = variables(
        packageOf(storeDetail('x', period: const SubscriptionPeriod(3, PeriodUnit.month))),
      );
      expect(v['package.period'], '3 months');
      expect(v['package.pricePerMonth'], '\$1.66');
    });

    test('a one time product has a price and nothing else', () {
      final v = variables(packageOf(storeDetail('x'), type: PackageType.lifetime));
      expect(v['package.price'], '\$4.99');
      expect(v['package.period'], isNull);
      expect(v['package.trial'], isNull);
      expect(v['package.pricePerMonth'], isNull);
    });

    test('with no store details nothing resolves', () {
      final v = variables(packageOf(null));
      expect(v['package.price'], isNull);
      expect(v['package.period'], isNull);
      expect(v['package.pricePerMonth'], isNull);
    });

    test('an unknown variable name is null', () {
      expect(variables(packageOf(storeDetail('x', period: monthly)))['package.unknown'], isNull);
    });

    test('periods are written in the language of the strings', () {
      final details = storeDetail(
        'x',
        period: monthly,
        trial: const SubscriptionPeriod(1, PeriodUnit.week),
      );
      expect(variables(packageOf(details), strings: 'de')['package.period'], 'Monat');
      expect(variables(packageOf(details), strings: 'de')['package.trial'], '1 Woche');
      expect(variables(packageOf(details), strings: 'fr')['package.period'], 'mois');
      expect(variables(packageOf(details), strings: 'es')['package.trial'], '1 semana');
      expect(variables(packageOf(details), strings: 'xx')['package.trial'], '1 week');
    });

    test('a custom labeler replaces the built in table', () {
      final v = PackageVariables.of(
        packageOf(storeDetail('x', period: monthly)),
        stringsLocale: const Locale('ja'),
        numberLocale: const Locale('ja'),
        labeler: (period, locale, {required alwaysCount}) => 'tsuki',
      );
      expect(v.period, 'tsuki');
    });

    test('a labeler that returns null hides the variable', () {
      final v = PackageVariables.of(
        packageOf(storeDetail('x', period: monthly)),
        stringsLocale: const Locale('ja'),
        numberLocale: const Locale('ja'),
        labeler: (period, locale, {required alwaysCount}) => null,
      );
      expect(v.period, isNull);
    });
  });

  group('resolvePaywallString', () {
    final v = variables(
      packageOf(
        storeDetail('x', period: monthly, trial: const SubscriptionPeriod(7, PeriodUnit.day)),
      ),
    );

    test('fills every variable', () {
      expect(
        resolvePaywallString('{{package.price}} per {{package.period}}, {{package.trial}} free', v),
        '\$4.99 per month, 7 days free',
      );
    });

    test('the same variable can appear twice and spaces inside the braces are allowed', () {
      expect(resolvePaywallString('{{ package.price }} / {{package.price}}', v), '\$4.99 / \$4.99');
    });

    test('a text with no variable is returned as it is', () {
      expect(resolvePaywallString('Go Pro', v), 'Go Pro');
      expect(resolvePaywallString('Go Pro', null), 'Go Pro');
    });

    test('a variable the package cannot supply makes the whole line null', () {
      final noTrial = variables(packageOf(storeDetail('x', period: monthly)));
      expect(resolvePaywallString('Start with {{package.trial}} free', noTrial), isNull);
      expect(resolvePaywallString('{{package.price}}', null), isNull);
      expect(resolvePaywallString('{{package.nope}}', v), isNull);
    });
  });

  group('resolvePaywallLabel', () {
    test('an unresolved variable becomes empty text and the spaces close up', () {
      final v = variables(packageOf(storeDetail('x', period: monthly)));
      expect(resolvePaywallLabel('Try {{package.trial}} free', v), 'Try free');
      expect(resolvePaywallLabel('Buy for {{package.price}}', v), 'Buy for \$4.99');
      expect(resolvePaywallLabel('{{package.trial}}', v), '');
      expect(resolvePaywallLabel('Continue', null), 'Continue');
    });
  });

  test('legal labels follow the language and fall back to English', () {
    expect(legalLabels(const Locale('de')).$2, 'Datenschutz');
    expect(legalLabels(const Locale('xx')).$1, 'Terms of Use');
  });
}
