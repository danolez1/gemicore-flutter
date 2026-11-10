import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'errors.dart';
import 'gemicore.dart';
import 'models.dart';
import 'offerings.dart';
import 'paywall_config.dart';
import 'paywall_variables.dart';
import 'url_opener.dart';

/// How a paywall shown with [presentPaywall] ended.
enum PaywallOutcome {
  /// The purchase went through and the customer has what they bought.
  purchased,

  /// Restore finished. Check [PaywallResult.customerInfo] for what it brought back.
  restored,

  /// The store is waiting (Ask to Buy, a slow payment). Access arrives later through
  /// [Gemicore.customerInfoStream].
  pending,

  /// The customer closed the paywall.
  cancelled,

  /// The paywall could not be shown, or a purchase or restore failed. See [PaywallResult.error].
  error,
}

class PaywallResult {
  const PaywallResult._(this.outcome, {this.customerInfo, this.purchase, this.error});

  const PaywallResult.purchased(PurchaseResult result)
    : this._(PaywallOutcome.purchased, customerInfo: null, purchase: result);

  const PaywallResult.pending(PurchaseResult result)
    : this._(PaywallOutcome.pending, customerInfo: null, purchase: result);

  const PaywallResult.restored(CustomerInfo info)
    : this._(PaywallOutcome.restored, customerInfo: info);

  const PaywallResult.cancelled() : this._(PaywallOutcome.cancelled);

  const PaywallResult.error(GemicoreException error) : this._(PaywallOutcome.error, error: error);

  final PaywallOutcome outcome;

  /// The customer after a restore, or after a purchase.
  final CustomerInfo? customerInfo;

  /// The purchase result for [PaywallOutcome.purchased] and [PaywallOutcome.pending].
  final PurchaseResult? purchase;
  final GemicoreException? error;

  bool get isPurchased => outcome == PaywallOutcome.purchased;
  bool get isRestored => outcome == PaywallOutcome.restored;
  bool get isCancelled => outcome == PaywallOutcome.cancelled;
  bool get isError => outcome == PaywallOutcome.error;
}

/// Shows the paywall of [offering] full screen and completes when the customer has bought, restored
/// or closed it. Needs a configured SDK, or pass [sdk].
///
/// With no [offering] the paywall is the one of [placement] when given (the server resolves it for
/// this customer from the targeting rules and experiments of the dashboard; an unknown placement
/// gives the current offering), else the current offering. An explicit [offering] wins over
/// [placement]. Showing a placement that runs an experiment enrolls the customer; there is nothing
/// else to call.
///
/// The offering must have a published paywall; otherwise the result is [PaywallOutcome.error] with
/// [GemicoreErrorCode.paywallNotAvailable] and nothing is shown.
Future<PaywallResult> presentPaywall(
  BuildContext context, {
  String? placement,
  Offering? offering,
  Gemicore? sdk,
  Locale? locale,
  CheckoutOpener? urlOpener,
  PaywallPeriodLabeler? periodLabeler,
  bool useRootNavigator = true,
}) async {
  final Gemicore instance;
  var target = offering;
  try {
    instance = sdk ?? Gemicore.instance;
    target ??= (await instance.getOfferings(placement: placement)).current;
  } on GemicoreException catch (error) {
    return PaywallResult.error(error);
  }
  if (target == null) {
    return const PaywallResult.error(
      GemicoreException(
        GemicoreErrorCode.paywallNotAvailable,
        'The dashboard has no current offering; set one or pass an offering',
      ),
    );
  }
  if (target.paywall?.config == null) {
    return PaywallResult.error(
      GemicoreException(
        GemicoreErrorCode.paywallNotAvailable,
        'The offering ${target.identifier} has no published paywall this SDK can show',
      ),
    );
  }
  if (!context.mounted) return const PaywallResult.cancelled();
  final shown = target;
  final result = await Navigator.of(context, rootNavigator: useRootNavigator).push<PaywallResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PaywallPage(
        offering: shown,
        sdk: instance,
        locale: locale,
        urlOpener: urlOpener,
        periodLabeler: periodLabeler,
      ),
    ),
  );
  return result ?? const PaywallResult.cancelled();
}

class _PaywallPage extends StatefulWidget {
  const _PaywallPage({
    required this.offering,
    required this.sdk,
    this.locale,
    this.urlOpener,
    this.periodLabeler,
  });

  final Offering offering;
  final Gemicore sdk;
  final Locale? locale;
  final CheckoutOpener? urlOpener;
  final PaywallPeriodLabeler? periodLabeler;

  @override
  State<_PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<_PaywallPage> {
  bool _closed = false;

  void _close(PaywallResult result) {
    // A second tap while the route animates out must not pop the page underneath.
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  // A dropped connection or a second tap is something the customer can simply try again, so the
  // paywall stays up and says so; anything else will not get better by tapping again.
  bool _canRetry(GemicoreException error) =>
      error.isRetryable || error.code == GemicoreErrorCode.purchaseInProgress;

  void _onError(GemicoreException error) {
    if (!_canRetry(error)) return _close(PaywallResult.error(error));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.offering.paywall!.config!.theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GemicorePaywall(
                offering: widget.offering,
                sdk: widget.sdk,
                locale: widget.locale,
                urlOpener: widget.urlOpener,
                periodLabeler: widget.periodLabeler,
                onPurchase: (result) {
                  if (result.isCompleted) _close(PaywallResult.purchased(result));
                  if (result.isPending) _close(PaywallResult.pending(result));
                },
                onRestore: (info) => _close(PaywallResult.restored(info)),
                onError: _onError,
              ),
            ),
            PositionedDirectional(
              top: 4,
              end: 4,
              child: IconButton(
                icon: Icon(Icons.close, color: theme.foreground),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => _close(const PaywallResult.cancelled()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the paywall the dashboard designed for [offering]. Prices, periods and trials come from
/// the store details of the selected package; nothing in the config is code, and a node that is
/// unknown or unusable is left out.
///
/// The purchase and restore buttons call the SDK and report through [onPurchase], [onRestore] and
/// [onError]. Use [presentPaywall] to show it full screen and get a [PaywallResult].
class GemicorePaywall extends StatefulWidget {
  const GemicorePaywall({
    super.key,
    required this.offering,
    this.config,
    this.sdk,
    this.locale,
    this.onPurchase,
    this.onRestore,
    this.onError,
    this.urlOpener,
    this.periodLabeler,
  });

  /// Where the packages come from.
  final Offering offering;

  /// The paywall to draw; the offering's published paywall when null.
  final PaywallConfig? config;

  /// The SDK the buttons call; [Gemicore.instance] when null.
  final Gemicore? sdk;

  /// Picks the strings of one locale instead of the device's. Falls back to the config's default.
  final Locale? locale;

  /// Called with every result of the purchase button: completed, pending and cancelled.
  final ValueChanged<PurchaseResult>? onPurchase;
  final ValueChanged<CustomerInfo>? onRestore;
  final ValueChanged<GemicoreException>? onError;

  /// Opens the terms and privacy links; the SDK's own opener (an in-app browser) when null.
  final CheckoutOpener? urlOpener;

  /// Writes periods in languages the built in table does not cover.
  final PaywallPeriodLabeler? periodLabeler;

  @override
  State<GemicorePaywall> createState() => _GemicorePaywallState();
}

class _GemicorePaywallState extends State<GemicorePaywall> with WidgetsBindingObserver {
  String? _selected;
  bool _purchasing = false;
  bool _restoring = false;

  PaywallConfig? get _config => widget.config ?? widget.offering.paywall?.config;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = _initialSelection();
  }

  @override
  void didUpdateWidget(GemicorePaywall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.offering.package(_selected ?? '') == null) _selected = _initialSelection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted) setState(() {});
  }

  String? _initialSelection() {
    final packages = widget.offering.packages;
    if (packages.isEmpty) return null;
    final config = _config;
    final wanted = config == null ? null : _firstListSelection(config.root);
    if (wanted != null && widget.offering.package(wanted) != null) return wanted;
    return packages.first.identifier;
  }

  String? _firstListSelection(PaywallNode node) {
    if (node is PackageListNode) return node.selected;
    if (node is StackNode) {
      for (final child in node.children) {
        final found = _firstListSelection(child);
        if (found != null) return found;
      }
    }
    return null;
  }

  Package? get _selectedPackage {
    final id = _selected;
    return id == null ? null : widget.offering.package(id);
  }

  List<Locale> _deviceLocales(BuildContext context) {
    final override = widget.locale;
    if (override != null) return [override];
    final dispatcher = View.maybeOf(context)?.platformDispatcher ?? PlatformDispatcher.instance;
    return dispatcher.locales.isEmpty ? [dispatcher.locale] : dispatcher.locales;
  }

  Gemicore get _sdk => widget.sdk ?? Gemicore.instance;

  GemicoreException _wrap(Object error, String what) => error is GemicoreException
      ? error
      : GemicoreException(GemicoreErrorCode.storeError, '$what failed: ${error.runtimeType}');

  Future<void> _purchase() async {
    final package = _selectedPackage;
    if (package == null || _purchasing || _restoring) return;
    setState(() => _purchasing = true);
    try {
      final result = await _sdk.purchasePackage(package);
      widget.onPurchase?.call(result);
    } catch (error) {
      widget.onError?.call(_wrap(error, 'The purchase'));
    } finally {
      if (mounted) setState(() => _purchasing = false);
    }
  }

  Future<void> _restore() async {
    if (_purchasing || _restoring) return;
    setState(() => _restoring = true);
    try {
      final info = await _sdk.restorePurchases();
      widget.onRestore?.call(info);
    } catch (error) {
      widget.onError?.call(_wrap(error, 'Restoring purchases'));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _open(Uri url) async {
    try {
      await (widget.urlOpener?.open(url) ?? _sdk.openUrl(url));
    } catch (error) {
      widget.onError?.call(_wrap(error, 'Opening the page'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) return const SizedBox.shrink();
    final ctx = _RenderContext.create(
      config: config,
      package: _selectedPackage,
      selectedId: _selected,
      locales: _deviceLocales(context),
      labeler: widget.periodLabeler ?? defaultPeriodLabel,
    );
    final root = _node(config.root, ctx, Axis.vertical);
    if (root == null) return const SizedBox.shrink();
    final theme = config.theme;
    final scheme = ColorScheme(
      brightness: ThemeData.estimateBrightnessForColor(theme.background),
      primary: theme.accent,
      onPrimary: theme.accentForeground,
      secondary: theme.accent,
      onSecondary: theme.accentForeground,
      error: const Color(0xFFB3261E),
      onError: const Color(0xFFFFFFFF),
      surface: theme.background,
      onSurface: theme.foreground,
    );
    return Theme(
      data: Theme.of(context).copyWith(colorScheme: scheme),
      child: Material(
        color: theme.background,
        child: SingleChildScrollView(
          // A paywall on a tablet stays a readable column instead of stretching across the screen.
          child: Center(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: root),
          ),
        ),
      ),
    );
  }

  Widget? _node(PaywallNode node, _RenderContext ctx, Axis parentAxis) => switch (node) {
    StackNode() => _stack(node, ctx),
    TextNode() => _text(node, ctx, parentAxis),
    ImageNode() => _image(node, ctx),
    PackageListNode() => _packageList(node, ctx),
    PurchaseButtonNode() => _purchaseButton(node, ctx),
    RestoreButtonNode() => _restoreButton(node, ctx),
    LegalLinksNode() => _legalLinks(node, ctx),
    SpacerNode() => SizedBox(
      width: parentAxis == Axis.horizontal ? node.size : 0,
      height: parentAxis == Axis.vertical ? node.size : 0,
    ),
    DividerNode() =>
      parentAxis == Axis.vertical
          ? Divider(height: 1, thickness: 1, color: ctx.theme.foreground.withValues(alpha: 0.15))
          : Container(width: 1, height: 24, color: ctx.theme.foreground.withValues(alpha: 0.15)),
    UnknownNode() => null,
  };

  Widget? _stack(StackNode node, _RenderContext ctx) {
    final children = <Widget>[];
    for (final child in node.children) {
      final built = _node(child, ctx, node.direction);
      if (built == null) continue;
      // In a row every content child may shrink, so long text wraps instead of overflowing.
      final flexible =
          node.direction == Axis.horizontal && child is! SpacerNode && child is! DividerNode;
      children.add(flexible ? Flexible(child: built) : built);
    }
    if (children.isEmpty) return null;
    final vertical = node.direction == Axis.vertical;
    final flex = Flex(
      direction: node.direction,
      mainAxisSize: MainAxisSize.min,
      spacing: node.spacing,
      crossAxisAlignment: switch (node.align) {
        PaywallAlign.start => CrossAxisAlignment.start,
        PaywallAlign.end => CrossAxisAlignment.end,
        PaywallAlign.center => CrossAxisAlignment.center,
        // A row cannot stretch to the height of an unbounded scroll view.
        PaywallAlign.stretch => vertical ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
      },
      children: children,
    );
    return node.padding > 0 ? Padding(padding: EdgeInsets.all(node.padding), child: flex) : flex;
  }

  Widget? _text(TextNode node, _RenderContext ctx, Axis parentAxis) {
    final template = ctx.string(node.stringKey);
    if (template == null) return null;
    final text = resolvePaywallString(template, ctx.variables);
    if (text == null || text.trim().isEmpty) return null;
    final theme = ctx.theme;
    final style = switch (node.style) {
      PaywallTextStyle.title => TextStyle(
        fontSize: 28 * theme.fontScale,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: theme.foreground,
      ),
      PaywallTextStyle.body => TextStyle(
        fontSize: 16 * theme.fontScale,
        height: 1.35,
        color: theme.foreground,
      ),
      PaywallTextStyle.caption => TextStyle(
        fontSize: 13 * theme.fontScale,
        height: 1.35,
        color: theme.foreground.withValues(alpha: 0.7),
      ),
    };
    Widget built = Text(
      text,
      style: style,
      textAlign: switch (node.align) {
        PaywallAlign.center => TextAlign.center,
        PaywallAlign.end => TextAlign.end,
        _ => TextAlign.start,
      },
    );
    if (node.style == PaywallTextStyle.title) built = Semantics(header: true, child: built);
    // Full width so the alignment has room to act; start and end follow the text direction.
    return parentAxis == Axis.vertical ? SizedBox(width: double.infinity, child: built) : built;
  }

  Widget _image(ImageNode node, _RenderContext ctx) {
    final theme = ctx.theme;
    final tint = theme.foreground.withValues(alpha: 0.06);
    final placeholder = ColoredBox(
      key: const ValueKey('gemicore-paywall-image-placeholder'),
      color: tint,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: theme.foreground.withValues(alpha: 0.3),
        ),
      ),
    );
    final uri = Uri.tryParse(node.url);
    // https only, whatever the config says: the server checks it too, a device never trusts it.
    final Widget content = uri == null || uri.scheme != 'https' || uri.host.isEmpty
        ? placeholder
        : LayoutBuilder(
            builder: (context, constraints) {
              // Decoded at the drawn width: a 4000 px hero would otherwise sit in the image cache
              // at full size for as long as the paywall is open.
              final pixels = constraints.hasBoundedWidth
                  ? (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context)).round()
                  : null;
              return Image.network(
                node.url,
                fit: node.fit,
                width: double.infinity,
                cacheWidth: pixels != null && pixels > 0 ? pixels : null,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : ColoredBox(color: tint),
              );
            },
          );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(theme.cornerRadius),
        child: AspectRatio(aspectRatio: node.aspect, child: content),
      ),
    );
  }

  Widget? _packageList(PackageListNode node, _RenderContext ctx) {
    final packages = widget.offering.packages;
    if (packages.isEmpty) return null;
    if (node.layout == Axis.horizontal) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final package in packages)
              SizedBox(width: 168, child: _packageCard(package, ctx, compact: true)),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [for (final package in packages) _packageCard(package, ctx, compact: false)],
    );
  }

  Widget _packageCard(Package package, _RenderContext ctx, {required bool compact}) {
    final theme = ctx.theme;
    final selected = package.identifier == ctx.selectedId;
    final title = package.displayName ?? package.product.title;
    final price = package.product.priceString;
    final accent = selected ? theme.accent : theme.foreground.withValues(alpha: 0.35);
    final titleStyle = TextStyle(
      fontSize: 16 * theme.fontScale,
      fontWeight: FontWeight.w600,
      color: theme.foreground,
    );
    final priceStyle = TextStyle(fontSize: 15 * theme.fontScale, color: theme.foreground);
    void select() => setState(() => _selected = package.identifier);
    final body = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: titleStyle),
              if (price != null) Text(price, style: priceStyle),
            ],
          )
        : Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: accent,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: titleStyle)),
              if (price != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(price, style: priceStyle, textAlign: TextAlign.end),
                ),
              ],
            ],
          );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: price == null ? title : '$title, $price',
      onTap: select,
      excludeSemantics: true,
      child: Material(
        color: selected ? theme.accent.withValues(alpha: 0.08) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.cornerRadius),
          side: BorderSide(color: accent, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: select,
          child: Padding(padding: const EdgeInsets.all(16), child: body),
        ),
      ),
    );
  }

  Widget? _purchaseButton(PurchaseButtonNode node, _RenderContext ctx) {
    final template = ctx.string(node.stringKey);
    if (template == null) return null;
    final label = resolvePaywallLabel(template, ctx.variables);
    if (label.isEmpty) return null;
    final theme = ctx.theme;
    final enabled = _selectedPackage != null && !_purchasing && !_restoring;
    return FilledButton(
      onPressed: enabled ? _purchase : null,
      style: FilledButton.styleFrom(
        backgroundColor: theme.accent,
        foregroundColor: theme.accentForeground,
        disabledBackgroundColor: theme.accent.withValues(alpha: 0.5),
        disabledForegroundColor: theme.accentForeground.withValues(alpha: 0.8),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(theme.cornerRadius)),
      ),
      child: _withProgress(
        busy: _purchasing,
        color: theme.accentForeground,
        size: 20,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17 * theme.fontScale, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget? _restoreButton(RestoreButtonNode node, _RenderContext ctx) {
    final template = ctx.string(node.stringKey);
    if (template == null) return null;
    final label = resolvePaywallLabel(template, ctx.variables);
    if (label.isEmpty) return null;
    final theme = ctx.theme;
    return TextButton(
      onPressed: !_purchasing && !_restoring ? _restore : null,
      style: TextButton.styleFrom(foregroundColor: theme.accent),
      child: _withProgress(
        busy: _restoring,
        color: theme.accent,
        size: 18,
        child: Text(label, style: TextStyle(fontSize: 15 * theme.fontScale)),
      ),
    );
  }

  // The label stays laid out and in the semantics tree while a spinner covers it, so the button keeps
  // its size and a screen reader still hears what it is.
  Widget _withProgress({
    required bool busy,
    required Color color,
    required double size,
    required Widget child,
  }) => Stack(
    alignment: Alignment.center,
    children: [
      Opacity(opacity: busy ? 0 : 1, alwaysIncludeSemantics: true, child: child),
      if (busy)
        ExcludeSemantics(
          child: SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
        ),
    ],
  );

  Widget? _legalLinks(LegalLinksNode node, _RenderContext ctx) {
    final (defaultTerms, defaultPrivacy) = legalLabels(ctx.stringsLocale);
    final links = <(String, Uri)>[
      if (_httpsUri(node.termsUrl) case final url?) (ctx.string('terms') ?? defaultTerms, url),
      if (_httpsUri(node.privacyUrl) case final url?)
        (ctx.string('privacy') ?? defaultPrivacy, url),
    ];
    if (links.isEmpty) return null;
    final theme = ctx.theme;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        for (final (label, url) in links)
          MergeSemantics(
            child: Semantics(
              link: true,
              child: TextButton(
                onPressed: () => _open(url),
                style: TextButton.styleFrom(
                  foregroundColor: theme.foreground.withValues(alpha: 0.7),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13 * theme.fontScale,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Uri? _httpsUri(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri : null;
  }
}

class _RenderContext {
  _RenderContext._({
    required this.config,
    required this.selectedId,
    required this.variables,
    required this.table,
    required this.defaults,
    required this.stringsLocale,
  });

  factory _RenderContext.create({
    required PaywallConfig config,
    required Package? package,
    required String? selectedId,
    required List<Locale> locales,
    required PaywallPeriodLabeler labeler,
  }) {
    final tag = _tableFor(config, locales);
    final defaultTag = _matchTag(config.strings.keys, config.defaultLocale);
    final stringsLocale = _localeOf(tag ?? config.defaultLocale);
    return _RenderContext._(
      config: config,
      selectedId: selectedId,
      table: tag == null ? const {} : config.strings[tag]!,
      defaults: defaultTag == null ? const {} : config.strings[defaultTag]!,
      stringsLocale: stringsLocale,
      variables: package == null
          ? null
          : PackageVariables.of(
              package,
              stringsLocale: stringsLocale,
              numberLocale: locales.first,
              labeler: labeler,
            ),
    );
  }

  final PaywallConfig config;
  final String? selectedId;
  final PackageVariables? variables;
  final Map<String, String> table;
  final Map<String, String> defaults;
  final Locale stringsLocale;

  PaywallTheme get theme => config.theme;

  /// The string in the device's language, else in the default locale, else null.
  String? string(String key) => table[key] ?? defaults[key];

  static String _normalize(String tag) => tag.toLowerCase().replaceAll('_', '-');

  static Locale _localeOf(String tag) {
    final parts = tag.split(RegExp('[-_]'));
    return Locale(parts.first, parts.length > 1 && parts[1].length == 2 ? parts[1] : null);
  }

  static String? _matchTag(Iterable<String> tags, String wanted) {
    final target = _normalize(wanted);
    for (final tag in tags) {
      if (_normalize(tag) == target) return tag;
    }
    return null;
  }

  // The first device language that has a table: the full tag (pt-BR), then the language alone (pt).
  static String? _tableFor(PaywallConfig config, List<Locale> locales) {
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
    return _matchTag(tags, config.defaultLocale);
  }
}
