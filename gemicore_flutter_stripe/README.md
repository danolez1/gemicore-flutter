# gemicore_flutter_stripe

The Apple Pay and Google Pay sheet for [`gemicore_flutter`](../gemicore_flutter), built on the Stripe payment sheet from `flutter_stripe` (pinned to `^14.2.0`, resolved to 14.2.0).

The core package stays free of a payment SDK. It defines the `NativePaySheet` interface and `Gemicore.payWithSheet`; this package supplies the sheet. Without it, `payWithCard` still works on the gateway's hosted page.

## Read this first: what card payments are for

`payWithSheet` is for **physical goods and real-world services only**: deliveries, tickets, bookings, rides. App Store Review Guideline 3.1.1 and the Google Play payments policy require digital goods, features, content and subscriptions to be sold with the store's own billing, which in Gemicore is `Gemicore.instance.purchase`. Selling a digital good through this sheet can get your app rejected or removed. The checks are yours; Gemicore cannot tell what a product is.

## Use

Neither package is on pub.dev yet (both are `publish_to: none`), and this package depends on `gemicore_flutter` by relative path, so it must be used from a checkout of this repository where the two folders sit side by side:

```yaml
dependencies:
  gemicore_flutter:
    path: ../gemicore/sdks/flutter/gemicore_flutter
  gemicore_flutter_stripe:
    path: ../gemicore/sdks/flutter/gemicore_flutter_stripe
```

A git dependency on `gemicore_flutter_stripe` does not resolve from outside the repository until `gemicore_flutter` is published and this package depends on it by version.

```dart
import 'package:gemicore_flutter/gemicore_flutter.dart';
import 'package:gemicore_flutter_stripe/gemicore_flutter_stripe.dart';

await Gemicore.configure(
  apiKey: 'pk_live_...',
  nativePaySheet: GemicoreStripePaySheet(),
);

final result = await Gemicore.instance.payWithSheet(product, email: 'buyer@example.com');
```

That one line is the whole Dart setup. The Stripe publishable key, the merchant country and the Apple Pay merchant id come from the Gemicore server with each payment, so none of them goes in the app. The price is the product's card price from the catalog; the sheet shows it but the charge is the server's.

The sheet shows the app's name as the merchant (`NativePayRequest.merchantDisplayName`, sent by the server) and falls back to the product name when it is empty. A product whose card price is not declared as physical goods or a real world service in the dashboard is refused by the server; the core package throws `GemicoreErrorCode.cardSaleNotDeclared`.

A closed sheet is `PurchaseResult.cancelled`. A failure throws `GemicoreException` with code `nativePayFailed`; its message holds only short codes (for example `Failed, card_declined`), never Stripe's own text or the client secret. After the sheet confirms, the core package waits for the payment to settle on the server (`payWithSheet` documents the timeout).

## What you set up in the dashboards

1. In Gemicore, add the app's **own** Stripe credentials, the secret key and the publishable key, and set a card price on the product. The platform's account is never used for the sheet: without the app's publishable key the intent route answers with a not-configured error. The merchant country is read from that Stripe account.
2. For Apple Pay, enter your Apple Pay merchant id in the app's store settings in Gemicore. Without one the sheet leaves Apple Pay out and still offers Google Pay and cards.
3. In Stripe, add the Apple Pay certificate for that merchant id (Stripe dashboard, Settings, Payment methods, Apple Pay). Apple Pay will not complete without it.

## What you set up in the app

### iOS

- Deployment target iOS 15.0 or higher: `platform :ios, '15.0'` in `ios/Podfile` and the same in Xcode. This is what `stripe_ios` 14.2.0 declares in its podspec; the flutter_stripe README still says 13.
- Create a merchant id in the Apple Developer account (Certificates, Identifiers & Profiles, Identifiers, Merchant IDs), for example `merchant.com.example.app`.
- In Xcode, select the Runner target, Signing & Capabilities, add the **Apple Pay** capability and tick that merchant id. This writes the `com.apple.developer.in-app-payments` entitlement.
- Use the same merchant id in the Gemicore dashboard (step 2 above). It is passed to `Stripe.merchantIdentifier` for you.
- Optional: card scanning needs `NSCameraUsageDescription` in `Info.plist`.

### Android

- `minSdk` 24 or higher (`in_app_purchase_android` in `gemicore_flutter` needs 24; `stripe_android` alone would allow 21) and `compileSdk` 36 (what `stripe_android` 14.2.0 declares), Java 17, Kotlin 1.8 or higher, Android Gradle plugin 8 or higher.
- `MainActivity` must extend **`FlutterFragmentActivity`**, not `FlutterActivity`:

  ```kotlin
  import io.flutter.embedding.android.FlutterFragmentActivity

  class MainActivity : FlutterFragmentActivity()
  ```

- The activity's theme must descend from `Theme.AppCompat` (for example `Theme.AppCompat.Light.NoActionBar`) in `res/values/styles.xml`, and in `res/values-night/styles.xml` if you have one. A plain `Theme.Material` or `Theme.DeviceDefault` theme makes the sheet crash or fail to open.
- Add the ProGuard rules from the flutter_stripe README to `android/app/proguard-rules.pro` if you minify release builds:

  ```proguard
  -dontwarn com.stripe.android.pushProvisioning.**
  -dontwarn com.google.android.gms.tapandpay.**
  -dontwarn kotlinx.parcelize.Parceler$DefaultImpls
  -dontwarn kotlinx.parcelize.Parceler
  -dontwarn kotlinx.parcelize.Parcelize
  -keep class com.stripe.** { *; }
  ```

- Enable Google Pay in `android/app/src/main/AndroidManifest.xml`, inside `<application>`:

  ```xml
  <meta-data
      android:name="com.google.android.gms.wallet.api.enabled"
      android:value="true" />
  ```

  This line comes from Stripe's Google Pay documentation; neither plugin ships it, and it could not be checked from this repository.
- Google Pay runs in its test environment while the app uses a `pk_test_` key and in production with a live key. Production needs Google's approval of your integration in the Google Pay & Wallet Console, with screenshots of the flow.

### Both

Rebuild the app after native changes; hot reload does not pick them up. If the sheet fails with a `PlatformException`, the message names the type only: check the Activity base class and the theme first.

## Testing

`GemicoreStripePaySheet` takes an optional `StripePaymentSheetApi`, a four-method interface over the static Stripe calls. Pass a fake in your own tests so no platform channel is needed:

```dart
GemicoreStripePaySheet(api: MyFakeStripe())
```

`flutter test` in this package covers the outcome mapping, the keys, the Apple Pay and Google Pay parameters and the secret handling against such a fake. **Nothing here has run on a device, with Stripe's real SDK, or against Apple Pay or Google Pay.** Try a test payment with a `pk_test_` key and a test card on a real iOS device and a real Android device before you ship.

## Notes

- The sheet shows the product's name where Stripe puts the business name (`merchantDisplayName`), because the request carries no business name yet.
- `NativePayRequest.amount` is not passed to Stripe: the payment sheet takes the total from the payment intent, which the server priced.
- Apple Pay is offered only when the server returns a merchant id; Google Pay and cards are always offered.
- Stripe's static settings (`Stripe.publishableKey`, `Stripe.merchantIdentifier`) are set on every payment. If your app also uses `flutter_stripe` itself with another Stripe account, set them again before your own calls.
