import 'package:flutter/material.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

import 'paywall_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The only setup: the publishable key from the Gemicore dashboard. A pk_test_ key uses the store
  // sandboxes, or the Gemicore test store when no store is available (a simulator, an emulator).
  // Apple Pay and Google Pay inside the app are optional: add the gemicore_flutter_stripe package and
  // pass its sheet as nativePaySheet, then sell physical goods with Gemicore.instance.payWithSheet.
  await Gemicore.configure(apiKey: const String.fromEnvironment('GEMICORE_KEY'));
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(title: 'Gemicore example', home: StorePage());
}

class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  List<GemicoreProduct> _products = const [];
  CustomerInfo? _customer;
  String? _message;

  @override
  void initState() {
    super.initState();
    _customer = Gemicore.instance.cachedCustomerInfo;
    // Renewals, refunds and purchases from other devices arrive here without polling.
    Gemicore.instance.customerInfoStream.listen((info) => setState(() => _customer = info));
    _load();
  }

  Future<void> _load() async {
    try {
      final products = await Gemicore.instance.getProducts();
      setState(() => _products = products);
    } on GemicoreException catch (error) {
      setState(() => _message = error.message);
    }
  }

  Future<void> _buy(GemicoreProduct product) async {
    try {
      final result = await Gemicore.instance.purchase(product);
      setState(() {
        _message = switch (result.status) {
          PurchaseResultStatus.completed => 'Thanks for your purchase',
          PurchaseResultStatus.cancelled => null,
          PurchaseResultStatus.pending => 'Waiting for approval',
        };
      });
    } on GemicoreException catch (error) {
      setState(() => _message = error.message);
    }
  }

  Future<void> _payByCard(GemicoreProduct product) async {
    // Card, Apple Pay and Google Pay are for physical goods and services only.
    final result = await Gemicore.instance.payWithCard(product, email: 'buyer@example.com');
    setState(() => _message = result.isCompleted ? 'Paid' : 'Payment not finished');
  }

  // A placement is a named spot in the app. The dashboard decides which offering it shows each
  // customer (rules by country, app version or attributes, or an experiment); an unknown name shows
  // the current offering.
  Future<void> _showPlacementPaywall() async {
    final result = await presentPaywall(context, placement: 'onboarding');
    if (!mounted) return;
    setState(() => _message = 'Placement paywall: ${result.outcome.name}');
  }

  // Shown only when the dashboard switched the Customer Center on; it never cancels anything itself,
  // the store does.
  Future<void> _showCustomerCenter() async {
    try {
      final shown = await presentCustomerCenter(context);
      if (!mounted || shown) return;
      setState(() => _message = 'The Customer Center is not enabled in the dashboard');
    } on GemicoreException catch (error) {
      if (mounted) setState(() => _message = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPro = _customer?.hasEntitlement('pro') ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(isPro ? 'Pro unlocked' : 'Free plan'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const PaywallScreen())),
            child: const Text('Paywall'),
          ),
          TextButton(
            onPressed: () async {
              final info = await Gemicore.instance.restorePurchases();
              setState(() => _customer = info);
            },
            child: const Text('Restore'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_message != null) ListTile(title: Text(_message!)),
          ListTile(
            title: const Text('Paywall for the onboarding placement'),
            onTap: _showPlacementPaywall,
          ),
          ListTile(title: const Text('Customer Center'), onTap: _showCustomerCenter),
          for (final product in _products)
            ListTile(
              title: Text(product.title),
              subtitle: Text(product.priceString ?? product.description ?? ''),
              trailing: product.card != null
                  ? TextButton(onPressed: () => _payByCard(product), child: const Text('Pay'))
                  : TextButton(onPressed: () => _buy(product), child: const Text('Buy')),
            ),
        ],
      ),
    );
  }
}
