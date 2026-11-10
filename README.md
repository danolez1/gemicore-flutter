# gemicore_flutter

Sell subscriptions and one-time purchases through the App Store and Google Play, show paywalls designed in the dashboard, apply promotional offers, take one-time card, Apple Pay and Google Pay payments, and check what each customer may use, with Gemicore as the backend. The SDK is set up with one value, the app's publishable key; the rest lives in the Gemicore dashboard.

## Install

```sh
flutter pub add gemicore_flutter
```

It needs iOS 15 or higher and Android `minSdk` 24. The Apple Pay and Google Pay sheet adds a few more native steps, listed under [Apple Pay and Google Pay inside the app](#apple-pay-and-google-pay-inside-the-app).

## Quickstart

```dart
await Gemicore.configure(apiKey: 'pk_live_...');

final products = await Gemicore.instance.getProducts();
final result = await Gemicore.instance.purchase(products.first);

if (await Gemicore.instance.hasEntitlement('pro')) {
  // unlock
}
```

That is all the code needs. The key decides the mode: a `pk_test_` key works with the App Store sandbox, TestFlight, Google Play license testers and the Gemicore test store; a `pk_live_` key with production.

## What you set in the dashboard, not in code

- **Store credentials.** App Store: the In-App Purchase key (`.p8`), its key id, the issuer id, the bundle id and the numeric Apple app id. Google Play: the service account JSON and the package name. Gemicore verifies every purchase and receives the stores' server notifications with these.
- **The notification URLs** the dashboard shows, pasted into App Store Connect (Version 2) and into the Pub/Sub push subscription of your Play Console topic.
- **The product catalog.** One identifier per product (for example `pro_monthly`), its App Store and Google Play product ids, the entitlements it unlocks (for example `pro`), and for one-time products an optional card price. The app asks for products by identifier and never hard codes store ids.
- **Offerings and paywalls.** Which packages (monthly, annual, lifetime, ...) to show together, which offering is current, and the paywall design of each one.
- **Promotional offers.** The discounts a product carries and who may use them.
- **Refund reviews and the Apple Pay merchant id**, if you use them.

## API

| Call | What it does |
|---|---|
| `Gemicore.configure(apiKey:)` | Creates or reloads this device's customer, starts listening to the store so interrupted and Ask to Buy purchases are recorded later. Optional: `appUserId`, `baseUrl` (self hosting), `logLevel`. |
| `getProducts()` | The dashboard catalog with this store's localized prices. |
| `getOfferings()`, `currentOffering` | The offerings with their packages, each package's product priced by this store. |
| `purchase(product)`, `purchasePackage(package)` | Store sheet, then server verification, then the store transaction is finished. A closed sheet is `PurchaseResult.cancelled`. Optional `offer:` applies a promotional offer. |
| `getEligibleOffers(product)` | The discounts this customer may use on a product. |
| `presentPaywall(context)`, `GemicorePaywall` | The paywall from the dashboard, full screen or inline. |
| `getOfferings(placement:)`, `presentPaywall(context, placement:)` | The offering a placement shows this customer, chosen by the dashboard's rules or experiment. |
| `setAttributes(map)`, `setEmail`, `setDisplayName`, `setPhoneNumber` | Customer attributes that placements and experiments can target by. |
| `presentCustomerCenter(context)`, `GemicoreCustomerCenter`, `getCustomerCenter()` | The Customer Center configured in the dashboard. |
| `setConsumptionConsent(bool)` | Records whether Apple may be sent usage data when the customer asks for a refund. |
| `restorePurchases()` | Required by App Store Review Guideline 3.1.1 behind a Restore button. |
| `payWithCard(product, email:)` | One-time card, Apple Pay or Google Pay payment on your gateway's hosted page in an in-app browser. |
| `payWithSheet(product, email:)` | The same payment on the Apple Pay or Google Pay sheet inside the app. Needs the native setup below. |
| `getCustomerInfo()`, `hasEntitlement(id)`, `customerInfoStream` | Access checks; cached for offline starts and refreshed when the app returns to the foreground. |
| `logIn(appUserId)`, `logOut()` | Tie purchases to your own user id. Purchases made while anonymous move to the logged in user. |

Errors are `GemicoreException` with the API's error `code` (see `GemicoreErrorCode`).

A purchase the store completed but the server could not take yet (offline, a 5xx) is kept and sent again after 30 seconds, when the app comes back to the foreground and after `logIn`; the store transaction is only finished once the server has it. `restorePurchases()` called twice at once runs once. `payWithCard` and `payWithSheet` take an optional `cancel:` future to stop waiting (for example when the buyer closes the browser) and throw `GemicoreErrorCode.paymentFailed` when the payment failed, expired or was refunded. `hasEntitlement` treats an entitlement whose expiry has passed as inactive even when the cached copy still says active, unless a purchase of that product is in its grace period.

## Verified identity

By default any client may link a customer to an app user id. If you set the identity mode to verified in the dashboard, linking has to be proven with the user's Gemicore access token, which your backend issues. Pass a provider; the SDK calls it just before it creates a customer for `appUserId` or runs `logIn`, and sends the result as `x-user-token`:

```dart
await Gemicore.configure(
  apiKey: 'pk_live_...',
  appUserId: user.id,
  userTokenProvider: () async => await myBackend.gemicoreUserToken(),
);
```

Return null when there is no signed in user. The API key stays the only required setting; leave the provider out when the mode is not verified. If the provider throws, the call fails with `GemicoreErrorCode.identityUnverified`.

## Offerings and paywalls

An offering is a set of packages the dashboard says to sell together; the current one is what a paywall shows by default. `getOfferings()` answers from memory for five minutes, keeps a copy on the device, and falls back to that copy when the network is down, so a paywall can still show on an offline start.

```dart
final offering = (await Gemicore.instance.getOfferings()).current;
final annual = offering?.annual;                       // also monthly, weekly, lifetime, package(id)
if (annual != null) await Gemicore.instance.purchasePackage(annual);
```

`Package.product` is the same `GemicoreProduct` that `getProducts()` returns, with this store's price merged in.

To show the paywall designed in the dashboard:

```dart
final result = await presentPaywall(context);          // the current offering, full screen
switch (result.outcome) {
  case PaywallOutcome.purchased:
  case PaywallOutcome.restored:
    // result.customerInfo or result.purchase has the new state; check hasEntitlement
  case PaywallOutcome.pending:                         // Ask to Buy: access arrives later
  case PaywallOutcome.cancelled:
  case PaywallOutcome.error:                           // result.error has the reason
}
```

`GemicorePaywall(offering: offering, onPurchase: ..., onRestore: ..., onError: ...)` draws the same paywall inside your own screen. Both need an offering with a published paywall; without one `presentPaywall` returns `PaywallOutcome.error` with `GemicoreErrorCode.paywallNotAvailable` and shows nothing.

How the paywall behaves:

- **Nodes.** `stack`, `text`, `image`, `package_list`, `purchase_button`, `restore_button`, `legal_links`, `spacer` and `divider`, with the theme's colors, corner radius and font scale. The config is data: a node type this SDK does not know, a node missing a field it needs, or a line whose text cannot be found is left out and the rest is drawn. A config that cannot be read at all draws nothing. Nothing throws.
- **Strings.** Picked by the device's language (`pt-BR`, then `pt`), falling back to the config's `defaultLocale`, key by key. Pass `locale:` to override the device.
- **Variables.** `{{package.price}}`, `{{package.period}}`, `{{package.trial}}` and `{{package.pricePerMonth}}` are filled from the store details of the package the customer has selected. A text line that uses a variable the store cannot supply (a one-time product has no period, a product without a trial has no trial, a device without a store has no price) is left out instead of showing a hole in a sentence; a button label just drops it. Period words are built in for English, German, French, Spanish, Italian, Portuguese and Dutch; for other languages pass `periodLabeler:`. The strings may define `terms` and `privacy` for the legal link labels.
- **Free trials.** `{{package.trial}}` shows the free trial the store product carries. The store decides at purchase time whether this customer gets it. On iOS the trial is read through a StoreKit 1 product request (the StoreKit 2 side of the Flutter plugin does not expose introductory offers). On Android it is the trial of the product's default offer (see "The Android default offer" below), shown only when Play lists that offer for this customer.
- **Accessibility.** Text follows the system text scale, buttons and package cards carry semantics (the selected card is announced as selected), and layouts mirror in right to left languages.
- **Images** load over https only and show a placeholder when they fail. **Legal links** open through the SDK's opener (an in-app browser); pass `urlOpener:` to change it.

## Promotional offers

```dart
final offers = await Gemicore.instance.getEligibleOffers(product);   // filtered for this customer
await Gemicore.instance.purchase(product, offer: offers.first);
```

- **App Store.** A promotional offer is signed by Gemicore (the signing key stays on the server) and handed to StoreKit; a win-back offer is passed by id and StoreKit checks it. Offer codes are redeemed in the App Store, so `purchase` throws `GemicoreErrorCode.offerNotSupported` for one.
- **Google Play.** The base plan offer whose id the catalog names is bought. If Play does not list it for this customer the call throws `GemicoreErrorCode.productNotAvailable` and nothing starts.
- **Introductory offers** follow the store's own eligibility by default, which is authoritative on the device. `purchase(product, useServerIntroEligibility: true)` makes Gemicore decide from its own purchase records instead and signs that answer for StoreKit. It is off by default because those records can be incomplete (purchases made before the SDK was added, for example); turn it on only when you know they are complete.

## Placements and attributes

A placement is a named spot in your app ("onboarding", "settings"). In the dashboard you decide which offering each placement shows: rules by country, platform, app version, customer attributes, customer age or purchase history, a default offering, or an A/B experiment between offerings.

```dart
final offerings = await Gemicore.instance.getOfferings(placement: 'onboarding');
offerings.current;                       // the offering the placement chose for this customer
offerings.placement?.source;             // experiment, rule, defaultOffering or current
await presentPaywall(context, placement: 'onboarding');
```

- An experiment needs no extra call: the server enrolls the customer when the placement is read, and keeps the variant for good. `Offerings.placement.experiment` names the experiment and variant.
- A name the server does not know, or refuses, gives the app's current offering and no error; targeting never stands between a customer and the paywall. Each placement has its own five minute memory copy and its own copy on the device for an offline start; a placement never read before falls back to the app's saved offerings when offline. The copies belong to the customer they were read for: `logIn`, `logOut` and `setAttributes` drop them, and a copy saved for another customer is never shown. An explicit `offering:` passed to `presentPaywall` wins over `placement:`.
- Every request carries `x-gemicore-app-version` (read with `package_info_plus`, left out when that fails), `x-gemicore-country` (the device locale's country code, left out when there is none) and `x-gemicore-platform`, which the rules use. Nothing is configured for this; pass `appVersionProvider` to `configure` only to replace the lookup. The default lookup runs in the background, so the first requests of a launch can go out without the version header.

Attributes let a rule target your own data:

```dart
await Gemicore.instance.setAttributes({'plan_hint': 'family', 'beta': null});   // null deletes
await Gemicore.instance.setEmail('ada@example.com');
```

Keys match `^[A-Za-z$][A-Za-z0-9_.$-]{0,39}$`, values are at most 256 characters, one call carries at most 50 keys, and a key starting with `$` must be `$email`, `$displayName`, `$phoneNumber`, `$pushToken`, `$campaign` or `$mediaSource`. A break of these throws `GemicoreErrorCode.invalidAttributes` before a request is made. Values are customer data: the SDK never logs them and no error carries one.

## The Android default offer

Mark one Google offer of a product as its default in the dashboard (a free trial, usually). A purchase with no explicit `offer:` then buys that offer when Play lists it for the product's base plan, and the plain base plan otherwise; Play lists only the offers the customer is eligible for, so a customer who already used the trial buys the base plan. `{{package.trial}}` in paywalls shows the trial of the offer that will be bought. The displayed price stays the base plan's regular price. An explicit `offer:` always wins. iOS is unchanged: the App Store decides introductory offer eligibility.

## Customer Center

Switch the Customer Center on and configure it in the dashboard (support email or https url, which buttons to show, a cancel survey, retention offers, strings by locale), then:

```dart
final shown = await presentCustomerCenter(context);   // false, and nothing shown, while it is off
```

or draw it inside your own screen with `GemicoreCustomerCenter()`. It shows:

- a summary of the active entitlements and subscriptions (renewal or end date, the store that bills it, a billing problem);
- **Manage subscription**: opens the store page that manages the subscription, outside the app when the opener can (pass `urlOpener:` to change it);
- **Restore purchases**;
- **Get help with a purchase**: Apple's Report a Problem page (`https://reportaproblem.apple.com`) or Google's order history (`https://play.google.com/store/account/orderhistory`), by the store of the purchase, and by this device's store when there is none;
- **Contact support**: the support url, or a mailto link to the support email;
- **Cancel subscription** for a store subscription that will renew: the survey (and "Other" with a text field when the config allows it) is recorded with `POST /v1/purchases/customer-center/feedback`, an eligible retention offer is shown first and bought through the normal promotional offer path when accepted (App Store subscriptions only: Google Play refuses a plain purchase of a subscription the customer already holds, and the replacement purchase it needs is not built yet; a purchase that is pending approval says so and is not counted as accepted), and otherwise the store's management page opens.

The app cannot cancel a store subscription and the Customer Center never claims it did: it says the subscription is cancelled in the store and stays active until then. The survey answer is sent in the background, so losing it or a slow network never blocks the customer. The screen follows the system text scale, dark and light themes and right to left layouts, labels carry semantics, and every label has built in English text (`customerCenterEnglish`) that the config's strings can override per locale, key by key; a survey option label can be translated with a `survey_option.<key>` string. `presentCustomerCenter` throws a `GemicoreException` when the config cannot be loaded.

## Refund review consent

If you turn on refund reviews in the dashboard, Gemicore answers Apple's consumption request for you, but only for customers who agreed to share usage data. Ask in your own UI, then record the answer:

```dart
await Gemicore.instance.setConsumptionConsent(true);
Gemicore.instance.cachedCustomerInfo?.consumptionConsent;   // the stored answer
```

## Apple Pay and Google Pay inside the app

`payWithCard` opens the gateway's hosted page and needs nothing beyond the key. `payWithSheet` shows the Apple Pay or Google Pay sheet inside the app instead, on Stripe's payment sheet (`flutter_stripe` ^14.2.0, which this package depends on). The sheet is the default, so there is nothing to pass to `configure`:

```dart
await Gemicore.configure(apiKey: 'pk_live_...');
final result = await Gemicore.instance.payWithSheet(product, email: 'buyer@example.com');
```

The Stripe publishable key, the merchant country and the Apple Pay merchant id come from the Gemicore server with each payment, so none of them goes in the app. `payWithSheet` asks Gemicore for a payment intent at the catalog price, shows the sheet, and then waits for the payment to settle the same way `payWithCard` does. A closed sheet is `PurchaseResult.cancelled`; a failed payment throws `GemicoreErrorCode.nativePayFailed` (its message holds only short codes such as `Failed, card_declined`, never Stripe's own text or the client secret) or `paymentFailed`. The sheet shows the app's name from `NativePayRequest.merchantDisplayName` and falls back to the product name when it is empty. To use another sheet, implement `NativePaySheet` and pass it as `nativePaySheet`.

**Read this first: what card payments are for.** `payWithSheet` and `payWithCard` are for **physical goods and real-world services only**: deliveries, tickets, bookings, rides. App Store Review Guideline 3.1.1 and the Google Play payments policy require digital goods, features, content and subscriptions to be sold with the store's own billing, which is `Gemicore.instance.purchase`. Selling a digital good through the sheet can get your app rejected or removed, and Gemicore cannot tell what a product is. A card price must be declared in the dashboard as physical goods or a real-world service; for one that is not, both calls throw `GemicoreErrorCode.cardSaleNotDeclared`.

### What you set up in the dashboards

1. In Gemicore, add the app's **own** Stripe credentials, the secret key and the publishable key, and set a card price on the product. The platform's account is never used for the sheet: without the app's publishable key the intent route answers with a not-configured error. The merchant country is read from that Stripe account.
2. For Apple Pay, enter your Apple Pay merchant id in the app's store settings in Gemicore. Without one the sheet leaves Apple Pay out and still offers Google Pay and cards.
3. In Stripe, add the Apple Pay certificate for that merchant id (Stripe dashboard, Settings, Payment methods, Apple Pay). Apple Pay will not complete without it.

### What you set up in the app

#### iOS

- Deployment target iOS 15.0 or higher: `platform :ios, '15.0'` in `ios/Podfile` and the same in Xcode. This is what `stripe_ios` 14.2.0 declares in its podspec; the flutter_stripe README still says 13.
- Create a merchant id in the Apple Developer account (Certificates, Identifiers & Profiles, Identifiers, Merchant IDs), for example `merchant.com.example.app`.
- In Xcode, select the Runner target, Signing & Capabilities, add the **Apple Pay** capability and tick that merchant id. This writes the `com.apple.developer.in-app-payments` entitlement.
- Use the same merchant id in the Gemicore dashboard (step 2 above). It is passed to `Stripe.merchantIdentifier` for you.
- Optional: card scanning needs `NSCameraUsageDescription` in `Info.plist`.

#### Android

- `minSdk` 24 or higher (`in_app_purchase_android` needs 24; `stripe_android` alone would allow 21) and `compileSdk` 36 (what `stripe_android` 14.2.0 declares), Java 17, Kotlin 1.8 or higher, Android Gradle plugin 8 or higher.
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

#### Both

Rebuild the app after native changes; hot reload does not pick them up. If the sheet fails with a `PlatformException`, the message names the type only: check the Activity base class and the theme first.

### Testing the sheet

`GemicoreStripePaySheet` takes an optional `StripePaymentSheetApi`, a four-method interface over the static Stripe calls. Pass a fake in your own tests so no platform channel is needed:

```dart
GemicoreStripePaySheet(api: MyFakeStripe())
```

`flutter test` in this package covers the outcome mapping, the keys, the Apple Pay and Google Pay parameters and the secret handling against such a fake. **Nothing here has run on a device, with Stripe's real SDK, or against Apple Pay or Google Pay.** Try a test payment with a `pk_test_` key and a test card on a real iOS device and a real Android device before you ship.

### Sheet notes

- The sheet shows the product's name where Stripe puts the business name (`merchantDisplayName`), because the request carries no business name yet.
- `NativePayRequest.amount` is not passed to Stripe: the payment sheet takes the total from the payment intent, which the server priced.
- Apple Pay is offered only when the server returns a merchant id; Google Pay and cards are always offered.
- Stripe's static settings (`Stripe.publishableKey`, `Stripe.merchantIdentifier`) are set on every payment. If your app also uses `flutter_stripe` itself with another Stripe account, set them again before your own calls.

## Card, Apple Pay and Google Pay

`payWithCard` is only for physical goods and services used outside the app (deliveries, tickets, bookings). App Store Review Guideline 3.1.1 and the Google Play payments policy require digital goods, features and subscriptions to be sold with `purchase`. The payment runs on the hosted checkout of the gateway the app has in Gemicore (Stripe, Paystack or Flutterwave), which shows Apple Pay and Google Pay where the gateway and the device support them. No merchant id or Apple Pay certificate is needed in the app.

## Platform notes

- **iOS 13 or later.** StoreKit 2 (iOS 15 or later) is what the plugin uses and what Gemicore verifies. Add the In-App Purchase capability in Xcode.
- **Android API 24 or later.** Google Play Billing Library 9.1 comes with `in_app_purchase_android`.
- The customer token is kept in the Keychain or the Android Keystore through `flutter_secure_storage`.
- Purchases are linked to the Gemicore customer through Apple's `appAccountToken` and Google's obfuscated account id, both set to the customer id.

## Testing

`flutter test` runs the SDK tests with fake transport, storage, store and payment sheet; nothing in them reaches the network. With a `pk_test_` key and no store available (a simulator without a StoreKit configuration, an emulator without Play), `purchase` uses the Gemicore test store, so the whole flow runs with no store account. Pass `useTestStore: false` to `configure` to turn that off, or `true` to force it on a test key.

Nothing in this package has been run on a device, or against a real App Store, Google Play, Stripe account or Gemicore production server: the Customer Center, placements, the Android default offer and the context headers are tested against fakes only.
