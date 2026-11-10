import 'dart:ui';

import 'package:flutter/widgets.dart' show Axis, BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'fakes.dart';

Map<String, Object?> configWith(Object? root, {Object? theme, Object? strings}) => {
  ...samplePaywallConfig(),
  'root': root,
  'theme': ?theme,
  'strings': ?strings,
};

void main() {
  test('the canonical sample parses into every node type', () {
    final config = PaywallConfig.tryParse(samplePaywallConfig())!;
    expect(config.defaultLocale, 'en');
    expect(config.strings.keys, ['en', 'de']);
    final root = config.root as StackNode;
    expect(root.direction, Axis.vertical);
    expect(root.spacing, 16);
    expect(root.padding, 24);
    expect(root.align, PaywallAlign.stretch);
    expect(root.children.map((n) => n.runtimeType), [
      ImageNode,
      TextNode,
      TextNode,
      PackageListNode,
      TextNode,
      TextNode,
      TextNode,
      PurchaseButtonNode,
      RestoreButtonNode,
      DividerNode,
      SpacerNode,
      LegalLinksNode,
    ]);
    final image = root.children[0] as ImageNode;
    expect(image.url, 'https://example.com/paywall-hero.png');
    expect(image.aspect, 1.6);
    expect(image.fit, BoxFit.cover);
    final title = root.children[1] as TextNode;
    expect(title.style, PaywallTextStyle.title);
    expect(title.align, PaywallAlign.center);
    expect((root.children[3] as PackageListNode).selected, isNull);
    expect((root.children[10] as SpacerNode).size, 8);
    expect((root.children[11] as LegalLinksNode).privacyUrl, 'https://example.com/privacy');
  });

  group('theme', () {
    test('reads colors with alpha last, as the web writes them', () {
      final theme = PaywallConfig.tryParse(
        configWith(
          {'type': 'divider'},
          theme: {
            'background': '#102030',
            'foreground': '#ffffff80',
            'accent': '#ff0000',
            'accentForeground': '#00000000',
            'cornerRadius': 20,
            'fontScale': 1.25,
          },
        ),
      )!.theme;
      expect(theme.background, const Color(0xFF102030));
      expect(theme.foreground, const Color(0x80FFFFFF));
      expect(theme.accent, const Color(0xFFFF0000));
      expect(theme.accentForeground, const Color(0x00000000));
      expect(theme.cornerRadius, 20);
      expect(theme.fontScale, 1.25);
    });

    test('a bad value falls back to the default and numbers stay inside their range', () {
      final theme = PaywallConfig.tryParse(
        configWith(
          {'type': 'divider'},
          theme: {
            'background': 'red',
            'foreground': '#12345',
            'accent': 42,
            'cornerRadius': 9000,
            'fontScale': 0.01,
          },
        ),
      )!.theme;
      const base = PaywallTheme();
      expect(theme.background, base.background);
      expect(theme.foreground, base.foreground);
      expect(theme.accent, base.accent);
      expect(theme.accentForeground, base.accentForeground);
      expect(theme.cornerRadius, 64);
      expect(theme.fontScale, 0.5);
    });

    test('a missing theme is the default theme', () {
      final json = samplePaywallConfig()..remove('theme');
      expect(PaywallConfig.tryParse(json)!.theme.cornerRadius, 12);
    });
  });

  group('a config that cannot be shown', () {
    test('is null, never an exception', () {
      expect(PaywallConfig.tryParse(null), isNull);
      expect(PaywallConfig.tryParse('paywall'), isNull);
      expect(PaywallConfig.tryParse(<Object?>[]), isNull);
      expect(PaywallConfig.tryParse({}), isNull);
      expect(PaywallConfig.tryParse({...samplePaywallConfig(), 'version': 2}), isNull);
      expect(PaywallConfig.tryParse({...samplePaywallConfig(), 'version': '1'}), isNull);
      expect(PaywallConfig.tryParse({...samplePaywallConfig(), 'root': null}), isNull);
      expect(PaywallConfig.tryParse({...samplePaywallConfig(), 'root': 'x'}), isNull);
    });

    test('strings of the wrong shape are dropped and the rest is kept', () {
      final config = PaywallConfig.tryParse(
        configWith(
          {'type': 'divider'},
          strings: {
            'en': {'ok': 'fine', 'bad': 42},
            'de': 'not a table',
          },
        ),
      )!;
      expect(config.strings['en'], {'ok': 'fine'});
      expect(config.strings['de'], isEmpty);
    });
  });

  group('nodes that cannot be shown become nodes that render nothing', () {
    PaywallNode child(Object? node) {
      final config = PaywallConfig.tryParse(
        configWith({
          'type': 'stack',
          'direction': 'column',
          'spacing': 0,
          'padding': 0,
          'align': 'start',
          'children': [node],
        }),
      )!;
      return (config.root as StackNode).children.single;
    }

    test('an unknown type keeps its name', () {
      final node = child({'type': 'carousel', 'items': []});
      expect(node, isA<UnknownNode>());
      expect((node as UnknownNode).type, 'carousel');
    });

    test('a node that is not an object, or has no type', () {
      expect(child('text'), isA<UnknownNode>());
      expect(child(null), isA<UnknownNode>());
      expect(child({'stringKey': 'title'}), isA<UnknownNode>());
      expect(child({'type': 7}), isA<UnknownNode>());
    });

    test('a node missing the field it cannot work without', () {
      expect(child({'type': 'text', 'style': 'title'}), isA<UnknownNode>());
      expect(child({'type': 'text', 'stringKey': ''}), isA<UnknownNode>());
      expect(child({'type': 'image', 'aspect': 1}), isA<UnknownNode>());
      expect(child({'type': 'purchase_button'}), isA<UnknownNode>());
      expect(child({'type': 'restore_button'}), isA<UnknownNode>());
      expect(child({'type': 'legal_links', 'termsUrl': 'https://a.test'}), isA<UnknownNode>());
    });

    test('layout fields that are missing or wrong take defaults and stay in range', () {
      final stack = child({
        'type': 'stack',
        'direction': 'diagonal',
        'spacing': 'wide',
        'padding': 1000,
        'align': 'middle',
        'children': 'none',
      }) as StackNode;
      expect(stack.direction, Axis.vertical);
      expect(stack.spacing, 0);
      expect(stack.padding, 64);
      expect(stack.align, PaywallAlign.stretch);
      expect(stack.children, isEmpty);
      final text = child({'type': 'text', 'stringKey': 'title'}) as TextNode;
      expect(text.style, PaywallTextStyle.body);
      expect(text.align, PaywallAlign.start);
      expect((child({'type': 'spacer', 'size': 1e9}) as SpacerNode).size, 200);
      expect((child({'type': 'spacer', 'size': double.nan}) as SpacerNode).size, 0);
      final image = child({
        'type': 'image',
        'url': 'https://a.test/i.png',
        'aspect': 0,
        'fit': 'zoom',
      }) as ImageNode;
      expect(image.aspect, 0.1);
      expect(image.fit, BoxFit.cover);
    });
  });

  group('limits', () {
    PaywallNode nested(int levels) {
      Object? node = {'type': 'divider'};
      for (var i = 0; i < levels; i++) {
        node = {
          'type': 'stack',
          'direction': 'column',
          'spacing': 0,
          'padding': 0,
          'align': 'start',
          'children': [node],
        };
      }
      return PaywallConfig.tryParse(configWith(node))!.root;
    }

    int depthOf(PaywallNode node) =>
        node is StackNode && node.children.isNotEmpty ? 1 + depthOf(node.children.first) : 1;

    test('a tree deeper than 8 levels is cut, not followed', () {
      final root = nested(40);
      expect(depthOf(root), lessThanOrEqualTo(9));
      var node = root;
      while (node is StackNode && node.children.isNotEmpty) {
        node = node.children.first;
      }
      expect(node, isA<UnknownNode>());
    });

    test('a tree of exactly 8 levels is whole', () {
      var node = nested(7);
      var levels = 1;
      while (node is StackNode) {
        node = node.children.first;
        levels++;
      }
      expect(levels, 8);
      expect(node, isA<DividerNode>());
    });

    test('nodes beyond 200 are dropped', () {
      final root =
          PaywallConfig.tryParse(
                configWith({
                  'type': 'stack',
                  'direction': 'column',
                  'spacing': 0,
                  'padding': 0,
                  'align': 'start',
                  'children': [
                    for (var i = 0; i < 500; i++) {'type': 'divider'},
                  ],
                }),
              )!.root
              as StackNode;
      expect(root.children.whereType<DividerNode>(), hasLength(199));
      expect(root.children.whereType<UnknownNode>(), hasLength(301));
    });
  });
}
