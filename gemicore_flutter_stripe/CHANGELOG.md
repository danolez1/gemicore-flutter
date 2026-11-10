## 0.1.0

- The payment sheet's merchant display name is `NativePayRequest.merchantDisplayName` (the app's name from the server), and the product name when that is empty.
- First release: `GemicoreStripePaySheet`, the `NativePaySheet` for `gemicore_flutter` on the Stripe payment sheet (`flutter_stripe` 14.2.0), with Apple Pay and Google Pay. A closed sheet is canceled, any failure carries only short codes and never the client secret.
