import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter/widgets.dart' show Axis;

// Mirrors PaywallConfig in packages/contracts/src/purchases.ts. The config is data from the server and is
// parsed defensively: whatever does not parse becomes a node that renders nothing, never an exception.

const _maxNodes = 200;
const _maxDepth = 8;

enum PaywallAlign { start, center, end, stretch }

enum PaywallTextStyle { title, body, caption }

class PaywallTheme {
  const PaywallTheme({
    this.background = const Color(0xFFFFFFFF),
    this.foreground = const Color(0xFF111827),
    this.accent = const Color(0xFF4F46E5),
    this.accentForeground = const Color(0xFFFFFFFF),
    this.cornerRadius = 12,
    this.fontScale = 1,
  });

  factory PaywallTheme.fromJson(Object? json) {
    final map = _map(json);
    const base = PaywallTheme();
    return PaywallTheme(
      background: parseHexColor(map['background']) ?? base.background,
      foreground: parseHexColor(map['foreground']) ?? base.foreground,
      accent: parseHexColor(map['accent']) ?? base.accent,
      accentForeground: parseHexColor(map['accentForeground']) ?? base.accentForeground,
      cornerRadius: _number(map['cornerRadius'], 0, 64) ?? base.cornerRadius,
      fontScale: _number(map['fontScale'], 0.5, 2) ?? base.fontScale,
    );
  }

  final Color background;
  final Color foreground;
  final Color accent;
  final Color accentForeground;
  final double cornerRadius;
  final double fontScale;
}

/// Reads "#rrggbb" or "#rrggbbaa" (alpha last, as on the web). Anything else is null.
Color? parseHexColor(Object? value) {
  if (value is! String || !RegExp(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(value)) {
    return null;
  }
  final hex = value.substring(1);
  final rgb = int.parse(hex.substring(0, 6), radix: 16);
  final alpha = hex.length == 8 ? int.parse(hex.substring(6), radix: 16) : 0xFF;
  return Color((alpha << 24) | rgb);
}

sealed class PaywallNode {
  const PaywallNode();
}

final class StackNode extends PaywallNode {
  const StackNode({
    required this.direction,
    required this.spacing,
    required this.padding,
    required this.align,
    required this.children,
  });

  final Axis direction;
  final double spacing;
  final double padding;
  final PaywallAlign align;
  final List<PaywallNode> children;
}

final class TextNode extends PaywallNode {
  const TextNode({required this.stringKey, required this.style, required this.align});

  final String stringKey;
  final PaywallTextStyle style;
  final PaywallAlign align;
}

final class ImageNode extends PaywallNode {
  const ImageNode({required this.url, required this.aspect, required this.fit});

  final String url;
  final double aspect;
  final BoxFit fit;
}

final class PackageListNode extends PaywallNode {
  const PackageListNode({required this.layout, this.selected});

  final Axis layout;

  /// The package identifier selected at first, or null for the first package.
  final String? selected;
}

final class PurchaseButtonNode extends PaywallNode {
  const PurchaseButtonNode({required this.stringKey});

  final String stringKey;
}

final class RestoreButtonNode extends PaywallNode {
  const RestoreButtonNode({required this.stringKey});

  final String stringKey;
}

final class LegalLinksNode extends PaywallNode {
  const LegalLinksNode({required this.termsUrl, required this.privacyUrl});

  final String termsUrl;
  final String privacyUrl;
}

final class SpacerNode extends PaywallNode {
  const SpacerNode({required this.size});

  final double size;
}

final class DividerNode extends PaywallNode {
  const DividerNode();
}

/// A node type this SDK version does not know, or one whose fields are unusable. Renders nothing.
final class UnknownNode extends PaywallNode {
  const UnknownNode(this.type);

  final String? type;
}

class PaywallConfig {
  const PaywallConfig({
    required this.defaultLocale,
    required this.theme,
    required this.strings,
    required this.root,
  });

  /// Parses a config, or returns null when it cannot be shown at all: not an object, a version other
  /// than 1, or no root node. A paywall with a null config renders nothing.
  static PaywallConfig? tryParse(Object? json) {
    try {
      final map = _map(json);
      if (map['version'] != 1 || map['root'] is! Map) return null;
      final budget = _Budget();
      return PaywallConfig(
        defaultLocale: _string(map['defaultLocale']) ?? 'en',
        theme: PaywallTheme.fromJson(map['theme']),
        strings: _strings(map['strings']),
        root: _parseNode(map['root'], budget, 1),
      );
    } on Object {
      // A hostile or broken config must never take the host app down.
      return null;
    }
  }

  final String defaultLocale;
  final PaywallTheme theme;

  /// Locale tag to string key to text.
  final Map<String, Map<String, String>> strings;
  final PaywallNode root;
}

class _Budget {
  int nodes = 0;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

double? _number(Object? value, double min, double max) {
  if (value is! num || value.isNaN || value.isInfinite) return null;
  return value.toDouble().clamp(min, max);
}

Map<String, Map<String, String>> _strings(Object? value) {
  final result = <String, Map<String, String>>{};
  for (final entry in _map(value).entries) {
    final table = <String, String>{};
    for (final text in _map(entry.value).entries) {
      final v = text.value;
      if (v is String) table[text.key] = v;
    }
    result[entry.key] = table;
  }
  return result;
}

PaywallAlign _align(Object? value, PaywallAlign fallback) => switch (value) {
  'start' => PaywallAlign.start,
  'center' => PaywallAlign.center,
  'end' => PaywallAlign.end,
  'stretch' => PaywallAlign.stretch,
  _ => fallback,
};

PaywallNode _parseNode(Object? json, _Budget budget, int depth) {
  budget.nodes += 1;
  if (budget.nodes > _maxNodes || depth > _maxDepth || json is! Map) {
    return const UnknownNode(null);
  }
  final map = _map(json);
  final type = map['type'];
  switch (type) {
    case 'stack':
      final children = map['children'];
      return StackNode(
        direction: map['direction'] == 'row' ? Axis.horizontal : Axis.vertical,
        spacing: _number(map['spacing'], 0, 64) ?? 0,
        padding: _number(map['padding'], 0, 64) ?? 0,
        align: _align(map['align'], PaywallAlign.stretch),
        children: children is List
            ? [for (final child in children) _parseNode(child, budget, depth + 1)]
            : const [],
      );
    case 'text':
      final key = _string(map['stringKey']);
      if (key == null) return const UnknownNode('text');
      return TextNode(
        stringKey: key,
        style: switch (map['style']) {
          'title' => PaywallTextStyle.title,
          'caption' => PaywallTextStyle.caption,
          _ => PaywallTextStyle.body,
        },
        align: _align(map['align'], PaywallAlign.start),
      );
    case 'image':
      final url = _string(map['url']);
      if (url == null) return const UnknownNode('image');
      return ImageNode(
        url: url,
        aspect: _number(map['aspect'], 0.1, 10) ?? 1.6,
        fit: map['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover,
      );
    case 'package_list':
      return PackageListNode(
        layout: map['layout'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
        selected: _string(map['selected']),
      );
    case 'purchase_button':
      final key = _string(map['stringKey']);
      return key == null
          ? const UnknownNode('purchase_button')
          : PurchaseButtonNode(stringKey: key);
    case 'restore_button':
      final key = _string(map['stringKey']);
      return key == null ? const UnknownNode('restore_button') : RestoreButtonNode(stringKey: key);
    case 'legal_links':
      final terms = _string(map['termsUrl']);
      final privacy = _string(map['privacyUrl']);
      if (terms == null || privacy == null) return const UnknownNode('legal_links');
      return LegalLinksNode(termsUrl: terms, privacyUrl: privacy);
    case 'spacer':
      return SpacerNode(size: _number(map['size'], 0, 200) ?? 0);
    case 'divider':
      return const DividerNode();
    default:
      return UnknownNode(type is String ? type : null);
  }
}
