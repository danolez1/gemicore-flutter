import 'dart:ui' show Locale;

import 'package:intl/intl.dart' show NumberFormat;

import 'offerings.dart';
import 'store_bridge.dart';
import 'subscription_period.dart';

/// Turns a period into words for a paywall line, in the language of the paywall's strings. Return null
/// to say the period cannot be written, which hides the line. [alwaysCount] is set for trials, where
/// "1 week" reads better than "week".
typedef PaywallPeriodLabeler = String? Function(
  SubscriptionPeriod period,
  Locale locale, {
  required bool alwaysCount,
});

// Singular, then plural, per unit in the order day, week, month, year. Covers the languages the
// dashboard's sample paywall is likely to be translated into; other languages pass a labeler.
const _unitWords = <String, List<(String, String)>>{
  'en': [('day', 'days'), ('week', 'weeks'), ('month', 'months'), ('year', 'years')],
  'de': [('Tag', 'Tage'), ('Woche', 'Wochen'), ('Monat', 'Monate'), ('Jahr', 'Jahre')],
  'fr': [('jour', 'jours'), ('semaine', 'semaines'), ('mois', 'mois'), ('an', 'ans')],
  'es': [('día', 'días'), ('semana', 'semanas'), ('mes', 'meses'), ('año', 'años')],
  'it': [('giorno', 'giorni'), ('settimana', 'settimane'), ('mese', 'mesi'), ('anno', 'anni')],
  'pt': [('dia', 'dias'), ('semana', 'semanas'), ('mês', 'meses'), ('ano', 'anos')],
  'nl': [('dag', 'dagen'), ('week', 'weken'), ('maand', 'maanden'), ('jaar', 'jaren')],
};

const _legalWords = <String, (String, String)>{
  'en': ('Terms of Use', 'Privacy Policy'),
  'de': ('Nutzungsbedingungen', 'Datenschutz'),
  'fr': ("Conditions d'utilisation", 'Politique de confidentialité'),
  'es': ('Términos de uso', 'Política de privacidad'),
  'it': ('Termini di utilizzo', 'Informativa sulla privacy'),
  'pt': ('Termos de uso', 'Política de privacidade'),
  'nl': ('Gebruiksvoorwaarden', 'Privacybeleid'),
};

/// The labels for the terms and privacy links when the paywall strings define no `terms` or `privacy`.
(String terms, String privacy) legalLabels(Locale locale) =>
    _legalWords[locale.languageCode] ?? _legalWords['en']!;

String? defaultPeriodLabel(SubscriptionPeriod period, Locale locale, {required bool alwaysCount}) {
  final words = (_unitWords[locale.languageCode] ?? _unitWords['en']!)[period.unit.index];
  final word = period.value == 1 ? words.$1 : words.$2;
  return period.value == 1 && !alwaysCount ? word : '${period.value} $word';
}

/// The values of {{package.price}}, {{package.period}}, {{package.trial}} and
/// {{package.pricePerMonth}} for one package, from the store details of this device. A value the
/// store cannot give (a one-time product has no period, an unavailable store has no price) is null.
class PackageVariables {
  const PackageVariables({this.price, this.period, this.trial, this.pricePerMonth});

  factory PackageVariables.of(
    Package package, {
    required Locale stringsLocale,
    required Locale numberLocale,
    PaywallPeriodLabeler labeler = defaultPeriodLabel,
  }) {
    final product = package.product;
    final details = product.storeDetails;
    final period = details is StoreProductDetails ? details.subscriptionPeriod : null;
    // On Google Play the trial belongs to the default offer that a purchase will buy, not to the
    // plain base plan; Play lists that offer only for customers who are eligible for it.
    final offer = product.defaultOfferDetails;
    final trial = offer is StoreProductDetails
        ? offer.trialPeriod
        : (details is StoreProductDetails ? details.trialPeriod : null);
    return PackageVariables(
      price: product.priceString,
      period: period == null ? null : labeler(period, stringsLocale, alwaysCount: false),
      trial: trial == null ? null : labeler(trial, stringsLocale, alwaysCount: true),
      pricePerMonth: _pricePerMonth(product.rawPrice, product.currencyCode, period, numberLocale),
    );
  }

  final String? price;
  final String? period;
  final String? trial;
  final String? pricePerMonth;

  String? operator [](String name) => switch (name) {
    'package.price' => price,
    'package.period' => period,
    'package.trial' => trial,
    'package.pricePerMonth' => pricePerMonth,
    _ => null,
  };
}

String? _pricePerMonth(
  double? rawPrice,
  String? currencyCode,
  SubscriptionPeriod? period,
  Locale locale,
) {
  if (rawPrice == null || currencyCode == null || period == null) return null;
  final months = period.months;
  if (months <= 0) return null;
  final perMonth = rawPrice / months;
  try {
    return NumberFormat.simpleCurrency(
      locale: _numberLocaleTag(locale),
      name: currencyCode,
    ).format(perMonth);
  } on Object {
    // An unknown locale or currency code falls back to the plain number with its code.
    return '${perMonth.toStringAsFixed(2)} $currencyCode';
  }
}

String _numberLocaleTag(Locale locale) => locale.countryCode == null || locale.countryCode!.isEmpty
    ? locale.languageCode
    : '${locale.languageCode}_${locale.countryCode}';

final _variable = RegExp(r'\{\{([^{}]*)\}\}');

/// Fills the variables of [template]. Returns null when a variable cannot be given a value (or is not
/// one of the four), so the caller can leave the line out instead of showing a hole in a sentence.
String? resolvePaywallString(String template, PackageVariables? variables) {
  var complete = true;
  final text = template.replaceAllMapped(_variable, (match) {
    final value = variables?[match.group(1)!.trim()];
    if (value == null || value.isEmpty) {
      complete = false;
      return '';
    }
    return value;
  });
  return complete ? text : null;
}

/// Like [resolvePaywallString] but an unresolved variable becomes empty text, for button labels, which
/// should not vanish because the store has no trial to mention.
String resolvePaywallLabel(String template, PackageVariables? variables) => template
    .replaceAllMapped(_variable, (match) => variables?[match.group(1)!.trim()] ?? '')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();
