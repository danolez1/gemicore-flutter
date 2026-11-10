import 'dart:ui' show Locale;

import 'models.dart';
import 'offerings.dart';

// The Customer Center wire shapes, mirroring packages/contracts/src/purchases.ts. The server validates
// the config on write; this parser still never throws on a shape it does not expect, because the
// config is data and the screen must not take the host app down.

Map<String, Object?> _map(Object? value) => asJsonMap(value);

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

List<Object?> _list(Object? value) => value is List ? value : const [];

/// One answer of the cancel survey.
class CancelSurveyOption {
  const CancelSurveyOption({required this.key, required this.label});

  final String key;
  final String label;
}

class CancelSurvey {
  const CancelSurvey({this.enabled = false, this.allowOther = false, this.options = const []});

  factory CancelSurvey.fromJson(Object? value) {
    final map = _map(value);
    return CancelSurvey(
      enabled: map['enabled'] == true,
      allowOther: map['allowOther'] == true,
      options: [
        for (final item in _list(map['options']))
          if (_string(_map(item)['key']) != null && _string(_map(item)['label']) != null)
            CancelSurveyOption(
              key: _map(item)['key']! as String,
              label: _map(item)['label']! as String,
            ),
      ],
    );
  }

  final bool enabled;

  /// Whether the customer may answer "Other" with a free text.
  final bool allowOther;
  final List<CancelSurveyOption> options;

  /// True when the survey is on and has something to pick.
  bool get isUsable => enabled && (options.isNotEmpty || allowOther);
}

/// A catalog offer shown first to a customer who holds [productIdentifier] and tries to cancel it.
class RetentionRule {
  const RetentionRule({required this.productIdentifier, required this.offerIdentifier});

  final String productIdentifier;
  final String offerIdentifier;
}

/// What the dashboard configured for the Customer Center. Every field has a safe default, so a
/// config from a newer server never fails to parse.
class CustomerCenterConfig {
  const CustomerCenterConfig({
    this.supportEmail,
    this.supportUrl,
    this.showManageSubscription = false,
    this.showRestore = false,
    this.showRefundHelp = false,
    this.cancelSurvey = const CancelSurvey(),
    this.retention = const [],
    this.strings = const {},
  });

  factory CustomerCenterConfig.fromJson(Object? value) {
    final map = _map(value);
    final strings = <String, Map<String, String>>{};
    for (final locale in _map(map['strings']).entries) {
      strings[locale.key] = {
        for (final text in _map(locale.value).entries)
          if (text.value is String) text.key: text.value! as String,
      };
    }
    return CustomerCenterConfig(
      supportEmail: _string(map['supportEmail']),
      supportUrl: _string(map['supportUrl']),
      showManageSubscription: map['showManageSubscription'] == true,
      showRestore: map['showRestore'] == true,
      showRefundHelp: map['showRefundHelp'] == true,
      cancelSurvey: CancelSurvey.fromJson(map['cancelSurvey']),
      retention: [
        for (final item in _list(map['retention']))
          if (_string(_map(item)['productIdentifier']) != null &&
              _string(_map(item)['offerIdentifier']) != null)
            RetentionRule(
              productIdentifier: _map(item)['productIdentifier']! as String,
              offerIdentifier: _map(item)['offerIdentifier']! as String,
            ),
      ],
      strings: strings,
    );
  }

  final String? supportEmail;

  /// https only, checked by the server.
  final String? supportUrl;
  final bool showManageSubscription;
  final bool showRestore;
  final bool showRefundHelp;
  final CancelSurvey cancelSurvey;
  final List<RetentionRule> retention;

  /// Locale tag to string key to text; keys the config leaves out use the built in English.
  final Map<String, Map<String, String>> strings;
}

/// What [Gemicore.getCustomerCenter] answers.
class CustomerCenterView {
  const CustomerCenterView({
    required this.enabled,
    required this.config,
    this.managementUrls = const {},
    this.eligibleRetentionOffers = const [],
  });

  factory CustomerCenterView.fromJson(Map<String, Object?> json) {
    final offers = <ProductOffer>[];
    for (final item in _list(json['eligibleRetentionOffers'])) {
      try {
        offers.add(ProductOffer.fromJson(_map(item)));
      } on FormatException {
        // An offer without an identifier cannot be bought, so it is left out.
      }
    }
    return CustomerCenterView(
      enabled: json['enabled'] == true,
      config: CustomerCenterConfig.fromJson(json['config']),
      managementUrls: {
        for (final entry in _map(json['managementUrls']).entries)
          if (entry.value is String) entry.key: entry.value! as String,
      },
      eligibleRetentionOffers: offers,
    );
  }

  /// False until the dashboard switches the Customer Center on; nothing is shown then.
  final bool enabled;
  final CustomerCenterConfig config;

  /// Per product identifier the customer holds: the store page that manages it. Empty when the
  /// config hides the manage button.
  final Map<String, String> managementUrls;

  /// Retention offers of the config this customer may use now. They carry no product identifier:
  /// [CustomerCenterConfig.retention] says which product each belongs to.
  final List<ProductOffer> eligibleRetentionOffers;
}

/// The keys of the screen's text. A config's `strings` may define any of them per locale; the ones it
/// leaves out use [customerCenterEnglish]. `survey_option.<key>` translates a survey option's label.
abstract final class CustomerCenterStringKey {
  static const title = 'title';
  static const summaryTitle = 'summary_title';
  static const noAccess = 'no_access';
  static const subscriptionsTitle = 'subscriptions_title';
  static const renewsOn = 'renews_on';
  static const endsOn = 'ends_on';
  static const billingIssue = 'billing_issue';
  static const billedBy = 'billed_by';
  static const storeAppStore = 'store_app_store';
  static const storeAppStoreTitle = 'store_app_store_title';
  static const storePlayStore = 'store_play_store';
  static const manage = 'manage_subscription';
  static const manageUnavailable = 'manage_unavailable';
  static const restore = 'restore';
  static const restoreDone = 'restore_done';
  static const restoreFailed = 'restore_failed';
  static const refundHelp = 'refund_help';
  static const refundHelpWhich = 'refund_help_which';
  static const contactSupport = 'contact_support';
  static const cancel = 'cancel_subscription';
  static const surveyTitle = 'survey_title';
  static const surveyOther = 'survey_other';
  static const surveyOtherHint = 'survey_other_hint';
  static const surveyContinue = 'survey_continue';
  static const retentionTitle = 'retention_title';
  static const retentionAccept = 'retention_accept';
  static const retentionDecline = 'retention_decline';
  static const retentionApplied = 'retention_applied';
  static const retentionPending = 'retention_pending';
  static const cancelInStore = 'cancel_in_store';
  static const close = 'close';
  static const retry = 'retry';
  static const loading = 'loading';
  static const errorGeneric = 'error_generic';
  static const chooseSubscription = 'choose_subscription';
}

/// The built in English text of every label. Nothing in the screen is hard coded outside this table.
const customerCenterEnglish = <String, String>{
  CustomerCenterStringKey.title: 'Manage your subscription',
  CustomerCenterStringKey.summaryTitle: 'Your plan',
  CustomerCenterStringKey.noAccess: 'You have no active subscriptions or purchases.',
  CustomerCenterStringKey.subscriptionsTitle: 'Subscriptions',
  CustomerCenterStringKey.renewsOn: 'Renews on {date}',
  CustomerCenterStringKey.endsOn: 'Ends on {date}',
  CustomerCenterStringKey.billingIssue:
      'There is a problem with your payment. Update your payment method in the store.',
  CustomerCenterStringKey.billedBy: 'Billed through {store}',
  CustomerCenterStringKey.storeAppStore: 'the App Store',
  CustomerCenterStringKey.storeAppStoreTitle: 'The App Store',
  CustomerCenterStringKey.storePlayStore: 'Google Play',
  CustomerCenterStringKey.manage: 'Manage subscription',
  CustomerCenterStringKey.manageUnavailable: 'There is no store page to manage this subscription.',
  CustomerCenterStringKey.restore: 'Restore purchases',
  CustomerCenterStringKey.restoreDone: 'Your purchases were checked and restored.',
  CustomerCenterStringKey.restoreFailed: 'Restoring purchases did not work. Please try again.',
  CustomerCenterStringKey.refundHelp: 'Get help with a purchase',
  CustomerCenterStringKey.refundHelpWhich: 'Which store did you buy from?',
  CustomerCenterStringKey.contactSupport: 'Contact support',
  CustomerCenterStringKey.cancel: 'Cancel subscription',
  CustomerCenterStringKey.surveyTitle: 'Why are you leaving?',
  CustomerCenterStringKey.surveyOther: 'Other',
  CustomerCenterStringKey.surveyOtherHint: 'Tell us more (optional)',
  CustomerCenterStringKey.surveyContinue: 'Continue',
  CustomerCenterStringKey.retentionTitle: 'Before you go',
  CustomerCenterStringKey.retentionAccept: 'Get this offer',
  CustomerCenterStringKey.retentionDecline: 'No thanks, continue',
  CustomerCenterStringKey.retentionApplied: 'Your offer was applied. Thank you for staying.',
  CustomerCenterStringKey.retentionPending:
      'Your purchase is waiting for approval. Nothing changes until the store confirms it.',
  CustomerCenterStringKey.cancelInStore: 'Opening the store. A subscription is cancelled there, not in this app, and stays active until you do.',
  CustomerCenterStringKey.close: 'Close',
  CustomerCenterStringKey.retry: 'Try again',
  CustomerCenterStringKey.loading: 'Loading',
  CustomerCenterStringKey.errorGeneric: 'Something went wrong. Please try again.',
  CustomerCenterStringKey.chooseSubscription: 'Which subscription?',
};

/// Looks up the screen's text: the device language's table in the config (the full tag, then the
/// language), then the config's English table, then the built in English, key by key.
class CustomerCenterStrings {
  CustomerCenterStrings(this.config, List<Locale> locales)
    : _device = _tableFor(config, locales),
      _english = _matchTag(config.strings.keys, 'en');

  final CustomerCenterConfig config;
  final String? _device;
  final String? _english;

  static String _normalize(String tag) => tag.toLowerCase().replaceAll('_', '-');

  static String? _matchTag(Iterable<String> tags, String wanted) {
    final target = _normalize(wanted);
    for (final tag in tags) {
      if (_normalize(tag) == target) return tag;
    }
    return null;
  }

  static String? _tableFor(CustomerCenterConfig config, List<Locale> locales) {
    final tags = config.strings.keys.toList();
    for (final locale in locales) {
      final language = locale.languageCode.toLowerCase();
      final country = locale.countryCode;
      if (country != null && country.isNotEmpty) {
        final exact = _matchTag(tags, '$language-$country');
        if (exact != null) return exact;
      }
      final plain = _matchTag(tags, language);
      if (plain != null) return plain;
      for (final tag in tags) {
        if (_normalize(tag).split('-').first == language) return tag;
      }
    }
    return null;
  }

  /// The text of [key] with `{name}` placeholders filled from [args]. A key nobody defines is
  /// returned as is, so a typo shows up on screen instead of crashing.
  String call(String key, {Map<String, String> args = const {}}) {
    final raw = lookup(key) ?? key;
    return raw.replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (match) => args[match.group(1)!] ?? match.group(0)!,
    );
  }

  /// The configured or built in text, or null when [key] has none (a survey option label has no
  /// built in text, for example).
  String? lookup(String key) {
    final device = _device;
    final english = _english;
    return (device == null ? null : config.strings[device]?[key]) ??
        (english == null ? null : config.strings[english]?[key]) ??
        customerCenterEnglish[key];
  }
}
