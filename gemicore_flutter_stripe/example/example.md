# Example

Pass the sheet to `Gemicore.configure`, then pay with it. The native setup (Apple Pay merchant id, Google Pay, `flutter_stripe` platform steps) is in the package README.

```dart
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter_stripe/gemicore_flutter_stripe.dart';

Future<void> main() async {
  await Gemicore.configure(
    apiKey: 'pk_test_...',
    nativePaySheet: GemicoreStripePaySheet(),
  );
  final products = await Gemicore.instance.getProducts();
  final product = products.firstWhere((p) => p.card != null);
  final result = await Gemicore.instance.payWithSheet(product, email: 'buyer@example.com');
  print(result.isCompleted ? 'paid' : 'not paid');
}
```
