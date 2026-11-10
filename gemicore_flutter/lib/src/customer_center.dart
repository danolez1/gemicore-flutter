import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'customer_center_config.dart';
import 'errors.dart';
import 'gemicore.dart';
import 'models.dart';
import 'offerings.dart';
import 'url_opener.dart';

const _appleRefundHelp = 'https://reportaproblem.apple.com';
const _googleRefundHelp = 'https://play.google.com/store/account/orderhistory';

/// Shows the Customer Center full screen and completes when the customer closes it. Returns false,
/// without showing anything, when the dashboard has not switched the Customer Center on. A failed
/// load (network, an unconfigured SDK) throws a [GemicoreException], like the other reads.
///
/// The screen summarizes what the customer has, opens the store's page to manage a subscription,
/// restores purchases, points to the store's own refund help, reaches support, and runs the cancel
/// flow. It never cancels anything itself: a subscription is cancelled in the store.
Future<bool> presentCustomerCenter(
  BuildContext context, {
  Gemicore? sdk,
  Locale? locale,
  CheckoutOpener? urlOpener,
  bool useRootNavigator = true,
}) async {
  final instance = sdk ?? Gemicore.instance;
  final view = await instance.getCustomerCenter();
  if (!view.enabled || !context.mounted) return false;
  await Navigator.of(context, rootNavigator: useRootNavigator).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _CustomerCenterPage(view: view, sdk: instance, locale: locale, urlOpener: urlOpener),
    ),
  );
  return true;
}

class _CustomerCenterPage extends StatelessWidget {
  const _CustomerCenterPage({required this.view, required this.sdk, this.locale, this.urlOpener});

  final CustomerCenterView view;
  final Gemicore sdk;
  final Locale? locale;
  final CheckoutOpener? urlOpener;

  @override
  Widget build(BuildContext context) {
    final strings = CustomerCenterStrings(view.config, _deviceLocales(context, locale));
    return Scaffold(
      appBar: AppBar(title: Text(strings(CustomerCenterStringKey.title))),
      body: SafeArea(
        child: GemicoreCustomerCenter(view: view, sdk: sdk, locale: locale, urlOpener: urlOpener),
      ),
    );
  }
}

List<Locale> _deviceLocales(BuildContext context, Locale? override) {
  if (override != null) return [override];
  final dispatcher = View.maybeOf(context)?.platformDispatcher ?? PlatformDispatcher.instance;
  return dispatcher.locales.isEmpty ? [dispatcher.locale] : dispatcher.locales;
}

/// One subscription the customer holds, as the summary and the cancel flow need it.
class _Subscription {
  const _Subscription(this.purchase, this.name);

  final PurchaseInfo purchase;
  final String name;

  String? get productIdentifier => purchase.productIdentifier;

  bool get inStore =>
      purchase.store == PurchaseStore.appStore || purchase.store == PurchaseStore.playStore;
}

/// The Customer Center drawn inline: a summary of the active entitlements and subscriptions, Manage
/// subscription, Restore purchases, Get help with a purchase, Contact support and the cancel flow,
/// each shown as the dashboard configured. Use [presentCustomerCenter] to show it full screen.
///
/// Nothing here cancels a subscription: the cancel flow records the survey, shows an eligible
/// retention offer first and then opens the store's management page, where the customer cancels.
/// The widget draws nothing when the Customer Center is disabled.
class GemicoreCustomerCenter extends StatefulWidget {
  const GemicoreCustomerCenter({
    super.key,
    this.sdk,
    this.view,
    this.locale,
    this.urlOpener,
    this.onRestore,
    this.onError,
  });

  /// The SDK the buttons call; [Gemicore.instance] when null.
  final Gemicore? sdk;

  /// The Customer Center to draw; loaded with [Gemicore.getCustomerCenter] when null.
  final CustomerCenterView? view;

  /// Picks the strings of one locale instead of the device's.
  final Locale? locale;

  /// Opens store pages, help and support links. When it also implements [ExternalUrlOpener] pages
  /// open outside the app, which is what store pages and mailto links need; the SDK's own opener
  /// when null.
  final CheckoutOpener? urlOpener;
  final ValueChanged<CustomerInfo>? onRestore;
  final ValueChanged<GemicoreException>? onError;

  @override
  State<GemicoreCustomerCenter> createState() => _GemicoreCustomerCenterState();
}

class _GemicoreCustomerCenterState extends State<GemicoreCustomerCenter>
    with WidgetsBindingObserver {
  CustomerCenterView? _view;
  // A view the parent passed, used by the next load only.
  CustomerCenterView? _seed;
  CustomerInfo? _customer;
  List<GemicoreProduct> _products = const [];
  Object? _loadError;
  bool _loading = true;
  bool _restoring = false;
  bool _flowRunning = false;
  StreamSubscription<CustomerInfo>? _customerSubscription;

  Gemicore get _sdk => widget.sdk ?? Gemicore.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _seed = _view = widget.view;
    _load();
  }

  @override
  void didUpdateWidget(GemicoreCustomerCenter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new view from the parent replaces what is on screen; a reload with none asks the server.
    if (widget.view != null && !identical(widget.view, oldWidget.view)) {
      _seed = _view = widget.view;
      _load(showSpinner: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _customerSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final sdk = _sdk;
      _customerSubscription ??= sdk.customerInfoStream.listen((info) {
        if (mounted) setState(() => _customer = info);
      });
      // The view the parent passed serves only the first load: a reload after a purchase or a retry
      // must see the server's current offers and store pages.
      final view = _seed ?? await sdk.getCustomerCenter();
      _seed = null;
      final customer = await sdk.getCustomerInfo(forceRefresh: true);
      // Names for the summary and the product a retention offer is bought for; without them the
      // identifiers are shown, so a failure here must not fail the screen.
      final products = await sdk.getProducts().then<List<GemicoreProduct>>(
        (list) => list,
        onError: (Object _) => _products,
      );
      if (!mounted) return;
      setState(() {
        _view = view;
        _customer = customer;
        _products = products;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  CustomerCenterStrings get _strings => CustomerCenterStrings(
    _view?.config ?? const CustomerCenterConfig(),
    _deviceLocales(context, widget.locale),
  );

  GemicoreException _wrap(Object error) => error is GemicoreException
      ? error
      : GemicoreException(GemicoreErrorCode.storeError, 'The request failed: ${error.runtimeType}');

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _fail(Object error, {String? message}) {
    final wrapped = _wrap(error);
    widget.onError?.call(wrapped);
    _say(message ?? (wrapped.message.isEmpty ? _strings('error_generic') : wrapped.message));
  }

  Future<bool> _open(Uri url) async {
    try {
      final opened = await _sdk.openExternalUrl(url, opener: widget.urlOpener);
      if (!opened) _say(_strings(CustomerCenterStringKey.errorGeneric));
      return opened;
    } catch (error) {
      _fail(error, message: _strings(CustomerCenterStringKey.errorGeneric));
      return false;
    }
  }

  // What the summary lists: subscriptions that give access or need the customer's attention, newest
  // per product and store.
  List<_Subscription> get _subscriptions {
    final customer = _customer;
    if (customer == null) return const [];
    const needsAttention = {'in_billing_retry', 'on_hold', 'paused'};
    final newest = <String, PurchaseInfo>{};
    for (final purchase in customer.purchases) {
      if (purchase.productType != ProductType.subscription) continue;
      if (!purchase.isActive && !needsAttention.contains(purchase.status)) continue;
      final key = '${purchase.productIdentifier}|${purchase.store.name}';
      final known = newest[key];
      if (known == null || purchase.purchasedAt.isAfter(known.purchasedAt)) newest[key] = purchase;
    }
    return [
      for (final purchase in newest.values)
        _Subscription(purchase, _nameOf(purchase.productIdentifier, purchase.storeProductId)),
    ];
  }

  String _nameOf(String? identifier, String fallback) {
    for (final product in _products) {
      if (product.identifier == identifier) return product.title;
    }
    return identifier ?? fallback;
  }

  String? _urlFor(_Subscription subscription) =>
      _view?.managementUrls[subscription.productIdentifier] ?? subscription.purchase.managementUrl;

  // Every store page the customer can be sent to, one per subscription, without repeats (Apple has one
  // page for all of its subscriptions).
  List<({String name, Uri url})> get _manageTargets {
    final targets = <({String name, Uri url})>[];
    final seen = <String>{};
    void add(String name, String? raw) {
      final url = raw == null ? null : Uri.tryParse(raw);
      if (url == null || !seen.add(url.toString())) return;
      targets.add((name: name, url: url));
    }

    for (final subscription in _subscriptions) {
      add(subscription.name, _urlFor(subscription));
    }
    for (final entry in (_view?.managementUrls ?? const <String, String>{}).entries) {
      add(_nameOf(entry.key, entry.key), entry.value);
    }
    return targets;
  }

  Future<void> _manage() async {
    final targets = _manageTargets;
    if (targets.isEmpty) return _say(_strings(CustomerCenterStringKey.manageUnavailable));
    if (targets.length == 1) {
      await _open(targets.single.url);
      return;
    }
    final chosen = await _pick<Uri>(_strings(CustomerCenterStringKey.chooseSubscription), [
      for (final target in targets) (label: target.name, value: target.url),
    ]);
    if (chosen != null) await _open(chosen);
  }

  Future<T?> _pick<T>(String title, List<({String label, T value})> choices) => showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final choice in choices)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(choice.value),
            child: Text(choice.label),
          ),
      ],
    ),
  );

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() => _restoring = true);
    try {
      final info = await _sdk.restorePurchases();
      widget.onRestore?.call(info);
      if (mounted) setState(() => _customer = info);
      _say(_strings(CustomerCenterStringKey.restoreDone));
    } catch (error) {
      _fail(error, message: _strings(CustomerCenterStringKey.restoreFailed));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  // The help page belongs to the store the purchase was made in, so the customer is sent to the page
  // of the store of their purchase; with purchases from both they say which, and with none the
  // store of this device is used.
  Future<void> _refundHelp() async {
    final stores = <PurchaseStore>{
      for (final purchase in _customer?.purchases ?? const <PurchaseInfo>[])
        if (purchase.store == PurchaseStore.appStore || purchase.store == PurchaseStore.playStore)
          purchase.store,
    };
    final strings = _strings;
    PurchaseStore? store;
    if (stores.length > 1) {
      store = await _pick<PurchaseStore>(strings(CustomerCenterStringKey.refundHelpWhich), [
        (label: strings(CustomerCenterStringKey.storeAppStoreTitle), value: PurchaseStore.appStore),
        (label: strings(CustomerCenterStringKey.storePlayStore), value: PurchaseStore.playStore),
      ]);
      if (store == null) return;
    } else {
      store = stores.isEmpty
          ? (_sdk.platform == 'ios' ? PurchaseStore.appStore : PurchaseStore.playStore)
          : stores.single;
    }
    await _open(Uri.parse(store == PurchaseStore.appStore ? _appleRefundHelp : _googleRefundHelp));
  }

  Future<void> _contactSupport() async {
    final config = _view?.config;
    final url = config?.supportUrl;
    final email = config?.supportEmail;
    if (url != null) {
      // A stored config can hold a url the server never checked (an older one, a self hosted server).
      final parsed = Uri.tryParse(url);
      if (parsed == null) return _say(_strings(CustomerCenterStringKey.errorGeneric));
      await _open(parsed);
    } else if (email != null) {
      await _open(Uri(scheme: 'mailto', path: email));
    }
  }

  // The cancel flow. The survey and the offer are the app's last word to a customer who is leaving;
  // the cancellation itself happens in the store, which is where the flow ends.
  Future<void> _cancel(_Subscription subscription) async {
    if (_flowRunning) return;
    _flowRunning = true;
    try {
      final config = _view!.config;
      final strings = _strings;
      _SurveyAnswer? answer;
      if (config.cancelSurvey.isUsable) {
        answer = await showDialog<_SurveyAnswer>(
          context: context,
          builder: (_) => _SurveyDialog(strings: strings, survey: config.cancelSurvey),
        );
        // Closing the survey backs out of the whole flow.
        if (answer == null || !mounted) return;
      }

      final offer = _retentionOffer(subscription);
      var decision = _OfferDecision.declined;
      if (offer != null) {
        final chosen = await showDialog<_OfferDecision>(
          context: context,
          builder: (_) => _RetentionDialog(
            strings: strings,
            offerName: offer.displayName,
            productName: subscription.name,
            onAccept: () => _buyOffer(subscription, offer),
          ),
        );
        if (!mounted) return;
        // A dismissed offer is a customer who changed their mind about leaving, not one who goes on,
        // and nothing is sent for it: opening the flow again would post a second answer.
        if (chosen == null) return;
        decision = chosen;
        _sendFeedback(
          subscription,
          answer,
          offerShown: offer.identifier,
          accepted: decision == _OfferDecision.accepted,
        );
      } else {
        _sendFeedback(subscription, answer);
      }
      if (!mounted) return;
      if (decision == _OfferDecision.accepted) {
        _say(strings(CustomerCenterStringKey.retentionApplied));
        unawaited(_load(showSpinner: false));
        return;
      }
      if (decision == _OfferDecision.pending) {
        // Ask to Buy, SCA or a slow payment: nothing is applied until the store confirms it, so the
        // customer is told that instead of being sent on to cancel.
        _say(strings(CustomerCenterStringKey.retentionPending));
        return;
      }

      final raw = _urlFor(subscription);
      final url = raw == null ? null : Uri.tryParse(raw);
      if (url == null) return _say(strings(CustomerCenterStringKey.manageUnavailable));
      _say(strings(CustomerCenterStringKey.cancelInStore));
      await _open(url);
    } finally {
      _flowRunning = false;
    }
  }

  // The catalog offer the config names for this subscription's product, when this customer is
  // eligible and the store the subscription is billed through can apply it.
  ProductOffer? _retentionOffer(_Subscription subscription) {
    final view = _view!;
    for (final rule in view.config.retention) {
      if (rule.productIdentifier != subscription.productIdentifier) continue;
      for (final offer in view.eligibleRetentionOffers) {
        if (offer.identifier != rule.offerIdentifier) continue;
        final usable = switch (subscription.purchase.store) {
          PurchaseStore.appStore => offer.appleOfferIdentifier != null,
          // A Play offer is a new base plan offer, and Play Billing refuses a plain purchase of a
          // subscription the customer already holds. Applying one needs a replacement purchase
          // (GooglePlayPurchaseParam.changeSubscriptionParam), which this SDK does not build yet.
          PurchaseStore.playStore => false,
          _ => false,
        };
        if (usable) return offer;
      }
    }
    return null;
  }

  // The same purchase path as any promotional offer, so signing, the store sheet and recording
  // behave exactly as they do from a paywall.
  Future<PurchaseResult> _buyOffer(_Subscription subscription, ProductOffer offer) async {
    var products = _products;
    GemicoreProduct? find() {
      for (final product in products) {
        if (product.identifier == subscription.productIdentifier) return product;
      }
      return null;
    }

    var product = find();
    if (product == null) {
      products = await _sdk.getProducts();
      product = find();
    }
    if (product == null) {
      throw GemicoreException(
        GemicoreErrorCode.productNotAvailable,
        '${subscription.name} is not in the catalog of this device',
      );
    }
    return _sdk.purchase(product, offer: offer);
  }

  // Losing a survey answer must never keep a customer from the store, so nothing here throws and the
  // callers do not wait for it: a slow network would otherwise hold the customer for up to a minute.
  Future<void> _sendFeedback(
    _Subscription subscription,
    _SurveyAnswer? answer, {
    String? offerShown,
    bool accepted = false,
  }) async {
    if (answer == null) return;
    try {
      await _sdk.sendCancelFeedback(
        reasonKey: answer.key,
        reasonText: answer.text,
        purchaseId: subscription.purchase.id,
        offerShown: offerShown,
        offerAccepted: accepted,
      );
    } catch (_) {
      // Deliberately silent: see above.
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    final view = _view;
    if (_loading && view == null) {
      return Center(
        child: Semantics(
          label: strings(CustomerCenterStringKey.loading),
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (view == null || _loadError != null && _customer == null) {
      return _LoadError(
        message: strings(CustomerCenterStringKey.errorGeneric),
        retry: strings(CustomerCenterStringKey.retry),
        onRetry: _load,
      );
    }
    if (!view.enabled) return const SizedBox.shrink();

    final config = view.config;
    final subscriptions = _subscriptions;
    final customer = _customer;
    final entitlements = [
      for (final entitlement in customer?.activeEntitlements.values ?? const <EntitlementInfo>[])
        if (customer!.hasEntitlement(entitlement.identifier)) entitlement,
    ];
    final theme = Theme.of(context);
    final showManage = config.showManageSubscription && _manageTargets.isNotEmpty;
    final hasSupport = config.supportUrl != null || config.supportEmail != null;
    final busy = _restoring;

    final children = <Widget>[
      _Header(strings(CustomerCenterStringKey.summaryTitle)),
      if (entitlements.isEmpty && subscriptions.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(strings(CustomerCenterStringKey.noAccess)),
        )
      else ...[
        if (entitlements.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entitlement in entitlements)
                  Chip(label: Text(entitlement.identifier), avatar: const Icon(Icons.check)),
              ],
            ),
          ),
        if (subscriptions.isNotEmpty) _Header(strings(CustomerCenterStringKey.subscriptionsTitle)),
        for (final subscription in subscriptions)
          _SubscriptionCard(
            subscription: subscription,
            strings: strings,
            onCancel: subscription.inStore && subscription.purchase.willRenew
                ? () => _cancel(subscription)
                : null,
          ),
      ],
      const SizedBox(height: 8),
      const Divider(height: 1),
      if (showManage)
        _Action(
          icon: Icons.manage_accounts_outlined,
          label: strings(CustomerCenterStringKey.manage),
          onTap: busy ? null : _manage,
        ),
      if (config.showRestore)
        _Action(
          icon: Icons.restore,
          label: strings(CustomerCenterStringKey.restore),
          busy: _restoring,
          onTap: busy ? null : _restore,
        ),
      if (config.showRefundHelp)
        _Action(
          icon: Icons.help_outline,
          label: strings(CustomerCenterStringKey.refundHelp),
          onTap: busy ? null : _refundHelp,
        ),
      if (hasSupport)
        _Action(
          icon: Icons.mail_outline,
          label: strings(CustomerCenterStringKey.contactSupport),
          onTap: busy ? null : _contactSupport,
        ),
    ];

    return Material(
      color: theme.colorScheme.surface,
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.retry, required this.onRetry});

  final String message;
  final String retry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(retry)),
        ],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.busy = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    trailing: busy
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.chevron_right),
    enabled: onTap != null,
    onTap: onTap,
  );
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.subscription, required this.strings, this.onCancel});

  final _Subscription subscription;
  final CustomerCenterStrings strings;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final purchase = subscription.purchase;
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final expires = purchase.expiresAt;
    final lines = <String>[
      if (expires != null)
        strings(
          purchase.willRenew ? CustomerCenterStringKey.renewsOn : CustomerCenterStringKey.endsOn,
          args: {'date': dates.formatShortDate(expires.toLocal())},
        ),
      if (purchase.store == PurchaseStore.appStore || purchase.store == PurchaseStore.playStore)
        strings(
          CustomerCenterStringKey.billedBy,
          args: {
            'store': strings(
              purchase.store == PurchaseStore.appStore
                  ? CustomerCenterStringKey.storeAppStore
                  : CustomerCenterStringKey.storePlayStore,
            ),
          },
        ),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subscription.name, style: theme.textTheme.titleSmall),
            for (final line in lines) Text(line),
            if (purchase.billingIssueDetectedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  strings(CustomerCenterStringKey.billingIssue),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (onCancel != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: onCancel,
                  child: Text(strings(CustomerCenterStringKey.cancel)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SurveyAnswer {
  const _SurveyAnswer(this.key, this.text);

  final String key;
  final String? text;
}

enum _OfferDecision { accepted, pending, declined }

const _otherKey = 'other';

class _SurveyDialog extends StatefulWidget {
  const _SurveyDialog({required this.strings, required this.survey});

  final CustomerCenterStrings strings;
  final CancelSurvey survey;

  @override
  State<_SurveyDialog> createState() => _SurveyDialogState();
}

class _SurveyDialogState extends State<_SurveyDialog> {
  final _text = TextEditingController();
  String? _selected;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Widget _choice(String key, String label) {
    final selected = _selected == key;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListTile(
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: Text(label),
        selected: selected,
        onTap: () => setState(() => _selected = key),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(strings(CustomerCenterStringKey.surveyTitle)),
      scrollable: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final option in widget.survey.options)
            _choice(option.key, strings.lookup('survey_option.${option.key}') ?? option.label),
          if (widget.survey.allowOther)
            _choice(_otherKey, strings(CustomerCenterStringKey.surveyOther)),
          if (_selected == _otherKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: TextField(
                controller: _text,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: strings(CustomerCenterStringKey.surveyOtherHint),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings(CustomerCenterStringKey.close)),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () =>
                    Navigator.of(context)
                        .pop(_SurveyAnswer(_selected!, _selected == _otherKey ? _text.text : null)),
          child: Text(strings(CustomerCenterStringKey.surveyContinue)),
        ),
      ],
    );
  }
}

class _RetentionDialog extends StatefulWidget {
  const _RetentionDialog({
    required this.strings,
    required this.offerName,
    required this.productName,
    required this.onAccept,
  });

  final CustomerCenterStrings strings;
  final String offerName;
  final String productName;
  final Future<PurchaseResult> Function() onAccept;

  @override
  State<_RetentionDialog> createState() => _RetentionDialogState();
}

class _RetentionDialogState extends State<_RetentionDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onAccept();
      if (!mounted) return;
      if (result.isCompleted || result.isPending) {
        Navigator.of(context)
            .pop(result.isCompleted ? _OfferDecision.accepted : _OfferDecision.pending);
        return;
      }
      // The customer closed the store sheet: the offer is still on the table.
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is GemicoreException && error.message.isNotEmpty
            ? error.message
            : widget.strings(CustomerCenterStringKey.errorGeneric);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(strings(CustomerCenterStringKey.retentionTitle)),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.offerName, style: theme.textTheme.titleMedium),
            Text(widget.productName),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(_OfferDecision.declined),
            child: Text(strings(CustomerCenterStringKey.retentionDecline)),
          ),
          FilledButton(
            onPressed: _busy ? null : _accept,
            child: _busy
                ? Semantics(
                    label: strings(CustomerCenterStringKey.loading),
                    child: const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Text(strings(CustomerCenterStringKey.retentionAccept)),
          ),
        ],
      ),
    );
  }
}
