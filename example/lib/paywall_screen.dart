import 'package:flutter/material.dart';
import 'package:gemicore_flutter/gemicore_flutter.dart';

/// Shows the current offering. When the dashboard has published a paywall for it, that paywall is
/// drawn with [GemicorePaywall]; otherwise the packages are listed with a plain buy button.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  Offering? _offering;
  String? _message;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      // Cached for five minutes, and kept on the device for an offline start.
      final offerings = await Gemicore.instance.getOfferings();
      if (!mounted) return;
      setState(() {
        _offering = offerings.current;
        _message = offerings.current == null ? 'No current offering is set in the dashboard' : null;
      });
    } on GemicoreException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(String message) => setState(() => _message = message);

  Future<void> _presentFullScreen() async {
    // The same paywall as a full screen page; the result says how the customer left it.
    final result = await presentPaywall(context, offering: _offering);
    if (!mounted) return;
    _show(switch (result.outcome) {
      PaywallOutcome.purchased => 'Purchased',
      PaywallOutcome.restored =>
        result.customerInfo!.hasEntitlement('pro') ? 'Restored' : 'Nothing to restore',
      PaywallOutcome.pending => 'Waiting for approval',
      PaywallOutcome.cancelled => 'Closed',
      PaywallOutcome.error => result.error?.message ?? 'Something went wrong',
    });
  }

  Future<void> _buy(Package package) async {
    try {
      final result = await Gemicore.instance.purchasePackage(package);
      _show(switch (result.status) {
        PurchaseResultStatus.completed => 'Thanks for your purchase',
        PurchaseResultStatus.cancelled => 'Cancelled',
        PurchaseResultStatus.pending => 'Waiting for approval',
      });
    } on GemicoreException catch (error) {
      _show(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offering = _offering;
    final config = offering?.paywall?.config;
    return Scaffold(
      appBar: AppBar(
        title: Text(offering?.displayName ?? 'Offerings'),
        actions: [
          if (config != null)
            TextButton(onPressed: _presentFullScreen, child: const Text('Full screen')),
        ],
      ),
      body: Column(
        children: [
          if (_message != null) ListTile(title: Text(_message!)),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : offering == null
                ? Center(
                    child: TextButton(onPressed: _load, child: const Text('Try again')),
                  )
                : config != null
                ? GemicorePaywall(
                    offering: offering,
                    onPurchase: (result) => _show(
                      result.isCompleted
                          ? 'Thanks for your purchase'
                          : result.isPending
                          ? 'Waiting for approval'
                          : 'Cancelled',
                    ),
                    onRestore: (info) =>
                        _show(info.hasEntitlement('pro') ? 'Restored' : 'Nothing to restore'),
                    onError: (error) => _show(error.message),
                  )
                : ListView(
                    children: [
                      for (final package in offering.packages)
                        ListTile(
                          title: Text(package.displayName ?? package.product.title),
                          subtitle: Text(package.product.priceString ?? ''),
                          trailing: TextButton(
                            onPressed: () => _buy(package),
                            child: const Text('Buy'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
