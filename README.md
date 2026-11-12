# gemicore_flutter

`gemicore_flutter` sells subscriptions and one-time purchases through the App Store and Google Play, with Gemicore as the backend. The code needs only the app's publishable key, and the dashboard holds the rest. The package also shows dashboard paywalls, applies promotional offers, takes one-time card, Apple Pay and Google Pay payments, and checks what each customer may use.

## Install

```sh
flutter pub add gemicore_flutter
```

It needs iOS 15 or higher and Android `minSdk` 24. The Apple Pay and Google Pay sheet adds a few native steps, listed under [Apple Pay and Google Pay inside the app](#apple-pay-and-google-pay-inside-the-app).

## Quickstart

```dart
await Gemicore.configure(apiKey: 'pk_live_...');

final products = await Gemicore.instance.getProducts();
final result = await Gemicore.instance.purchase(products.first);

if (await Gemicore.instance.hasEntitlement('pro')) {
  // pro features
}
```

A `pk_test_` key works with the App Store sandbox, TestFlight, Google Play license testers and the Gemicore test store. A `pk_live_` key works with production.

## What you set in the dashboard

- **Store credentials**, for verifying purchases and receiving the stores' server notifications.
  - The App Store needs the In-App Purchase key (`.p8`), its key id, the issuer id, the bundle id and the numeric Apple app id.
  - Google Play needs the service account JSON and the package name.
- **The notification URLs** the dashboard shows. Paste them into App Store Connect (Version 2) and into the Pub/Sub push subscription of your Play Console topic.
- **The product catalog.** The app asks for products by identifier and hard codes no store ids.
  - Each product has an identifier (for example `pro_monthly`), its store product ids and the entitlements it grants (for example `pro`).
  - A one-time product can also have a card price.
- **Offerings and paywalls**: the packages (monthly, annual, lifetime, ...) that show together, the current offering and each paywall's design.
- **Promotional offers**, **refund reviews** and the **Apple Pay merchant id**, if you use them.

## API

| Call | What it does |
|---|---|
| `Gemicore.configure(apiKey:)` | Creates or reloads this device's customer and starts listening to the store. |
| `getProducts()` | The dashboard catalog with this store's localized prices. |
| `getOfferings()`, `currentOffering` | The offerings with their packages, each priced by this store. |
| `purchase(product)`, `purchasePackage(package)` | Store sheet, server verification, then the store transaction is finished. |
| `getEligibleOffers(product)` | The discounts this customer may use on a product. |
| `presentPaywall(context)`, `GemicorePaywall` | The dashboard paywall, full screen or inline. |
| `getOfferings(placement:)`, `presentPaywall(context, placement:)` | The offering a placement shows this customer, chosen by the dashboard's rules or experiment. |
| `setAttributes(map)`, `setEmail`, `setDisplayName`, `setPhoneNumber` | Customer attributes that placements and experiments can target. |
| `presentCustomerCenter(context)`, `GemicoreCustomerCenter`, `getCustomerCenter()` | The Customer Center configured in the dashboard. |
| `setConsumptionConsent(bool)` | Records whether Apple may receive usage data when the customer asks for a refund. |
| `restorePurchases()` | Required by App Store Review Guideline 3.1.1 behind a Restore button. |
| `payWithCard(product, email:)` | One-time card, Apple Pay or Google Pay payment on your gateway's hosted page in an in-app browser. |
| `payWithSheet(product, email:)` | The same payment on the Apple Pay or Google Pay sheet inside the app. Needs the native setup below. |
| `getCustomerInfo()`, `hasEntitlement(id)`, `customerInfoStream` | Access checks, cached for offline starts and refreshed when the app returns to the foreground. |
| `logIn(appUserId)`, `logOut()` | Tie purchases to your own user id. Purchases made while anonymous move to the logged in user. |

Errors are `GemicoreException` with the API's error `code` (see `GemicoreErrorCode`).

A few calls have details worth knowing.

`Gemicore.configure` listens to the store, and that lets it record interrupted and Ask to Buy purchases later. The optional arguments are `appUserId`, `baseUrl` (self hosting) and `logLevel`.

`purchase` returns `PurchaseResult.cancelled` for a closed sheet, and the optional `offer:` applies a promotional offer. A purchase the store completed but the server could not take (offline, a 5xx) is kept. It is sent again after 30 seconds, when the app returns to the foreground and after `logIn`. The store transaction is finished only once the server has it.

`restorePurchases()` called twice at once runs once.

`payWithCard` and `payWithSheet` take an optional `cancel:` future to stop waiting, for example when the buyer closes the browser. They throw `GemicoreErrorCode.paymentFailed` when the payment failed, expired or was refunded.

`hasEntitlement` treats an entitlement whose expiry has passed as inactive, even when the cached copy is marked active. A purchase of that product in its grace period is the exception.

## Verified identity

By default any client may link a customer to an app user id. If you set the identity mode to verified in the dashboard, linking must be proven with the user's Gemicore access token. Your backend issues that token.

Pass a provider, and the SDK calls it just before it creates a customer for `appUserId` or runs `logIn`. The result goes out as `x-user-token`:

```dart
await Gemicore.configure(
  apiKey: 'pk_live_...',
  appUserId: user.id,
  userTokenProvider: () async => await myBackend.gemicoreUserToken(),
);
```

Return null when no user is signed in. If the provider throws, the call fails with `GemicoreErrorCode.identityUnverified`.

## Offerings and paywalls

An offering is a set of packages the dashboard says to sell together, and the current one is what a paywall shows by default. `getOfferings()` answers from memory for five minutes and keeps a copy on the device for an offline start.

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

`GemicorePaywall(offering: offering, onPurchase: ..., onRestore: ..., onError: ...)` draws the same paywall inside your own screen. Both need an offering with a published paywall. Without one, `presentPaywall` shows nothing and returns `PaywallOutcome.error` with `GemicoreErrorCode.paywallNotAvailable`.

The paywall behaves as follows:

- **Nodes**: `stack`, `text`, `image`, `package_list`, `purchase_button`, `restore_button`, `legal_links`, `spacer` and `divider`, drawn with the theme's colors, corner radius and font scale.
  - An unknown node type, a node missing a needed field or a line whose text cannot be found is left out, and the rest is drawn.
  - A config that cannot be read draws nothing and throws nothing.
- **Strings** are picked by the device's language (`pt-BR`, then `pt`), falling back to the config's `defaultLocale` key by key.
  - Pass `locale:` to override the device.
  - Define `terms` and `privacy` in the strings for the legal link labels.
- **Variables.** `{{package.price}}`, `{{package.period}}`, `{{package.trial}}` and `{{package.pricePerMonth}}` are filled from the store details of the selected package.
  - A text line whose variable the store cannot supply is left out, and no sentence is left with a hole.
  - That happens when a one-time product has no period, a product has no trial, or a device has no store price.
  - A button label drops the variable.
- **Period words** are built in for English, German, French, Spanish, Italian, Portuguese and Dutch. For other languages pass `periodLabeler:`.
- **Free trials.** `{{package.trial}}` shows the free trial the store product has, and the store decides at purchase time whether this customer gets it.
  - On iOS the trial is read through a StoreKit 1 product request, because the StoreKit 2 side of the Flutter plugin does not expose introductory offers.
  - On Android it is the trial of the product's default offer (see "The Android default offer" below), shown only when Play lists that offer for this customer.
- **Accessibility.** Text follows the system text scale and layouts mirror in right to left languages. Buttons and package cards have semantics, and the selected card is announced as selected.
- **Images** load over https only and show a placeholder on failure. **Legal links** open in an in-app browser, and `urlOpener:` changes that.

## Promotional offers

```dart
final offers = await Gemicore.instance.getEligibleOffers(product);   // filtered for this customer
await Gemicore.instance.purchase(product, offer: offers.first);
```

- **App Store.** Gemicore signs a promotional offer and hands it to StoreKit, and the signing key stays on the server.
  - A win-back offer is passed by id, and StoreKit checks it.
  - Offer codes are redeemed in the App Store, and `purchase` throws `GemicoreErrorCode.offerNotSupported` for one.
- **Google Play.** The base plan offer with the id given in the catalog is bought. If Play does not list it for this customer, the call throws `GemicoreErrorCode.productNotAvailable` and nothing starts.
- **Introductory offers** follow the store's own eligibility.
  - `purchase(product, useServerIntroEligibility: true)` makes Gemicore decide from its own purchase records and sign that answer for StoreKit.
  - The option is off by default, because those records can be incomplete, for example for purchases made before the SDK was added.

## Placements and attributes

A placement is a named spot in your app ("onboarding", "settings"). In the dashboard you decide which offering each placement shows. The choices are rules (by country, platform, app version, customer attributes, customer age or purchase history), a default offering, or an A/B experiment between offerings.

```dart
final offerings = await Gemicore.instance.getOfferings(placement: 'onboarding');
offerings.current;                       // the offering the placement chose for this customer
offerings.placement?.source;             // experiment, rule, defaultOffering or current
await presentPaywall(context, placement: 'onboarding');
```

- An experiment needs no extra call. The server enrolls the customer when the placement is read and keeps the variant, and `Offerings.placement.experiment` names the experiment and variant.
- When the server does not know a name or refuses it, the app receives its current offering and no error. Targeting never blocks the paywall.
- Each placement has its own five minute memory copy and its own copy on the device for an offline start. `logIn`, `logOut` and `setAttributes` drop these copies.
- An explicit `offering:` passed to `presentPaywall` wins over `placement:`.
- Every request includes `x-gemicore-app-version`, `x-gemicore-country` and `x-gemicore-platform` for the rules to use.
  - `x-gemicore-app-version` is read with `package_info_plus` in the background and left out when that fails. The first requests of a launch can go without it. Pass `appVersionProvider` to `configure` to replace the lookup.
  - `x-gemicore-country` is the device locale's country code, left out when there is none.

Attributes let a rule target your own data:

```dart
await Gemicore.instance.setAttributes({'plan_hint': 'family', 'beta': null});   // null deletes
await Gemicore.instance.setEmail('ada@example.com');
```

Attributes have these limits:

- Keys match `^[A-Za-z$][A-Za-z0-9_.$-]{0,39}$`.
- Values are at most 256 characters.
- One call can include at most 50 keys.
- A key starting with `$` must be `$email`, `$displayName`, `$phoneNumber`, `$pushToken`, `$campaign` or `$mediaSource`.

A broken limit throws `GemicoreErrorCode.invalidAttributes` before any request. Values are customer data, and the SDK never logs them or puts one in an error.

## The Android default offer

Mark one Google offer of a product as its default in the dashboard, usually a free trial. Without an explicit `offer:`, the SDK buys that offer when Play lists it for the product's base plan, and the plain base plan otherwise. Play lists only the offers the customer is eligible for. A customer who already used the trial buys the base plan.

`{{package.trial}}` in paywalls shows the trial of the offer that will be bought, and the displayed price stays the base plan's regular price. An explicit `offer:` always wins. On iOS the default offer has no effect, because the App Store decides introductory offer eligibility.

## Customer Center

Switch the Customer Center on in the dashboard and configure it there. You set a support email or https url, the buttons to show, a cancel survey, retention offers and strings by locale. Then show it from the app:

```dart
final shown = await presentCustomerCenter(context);   // false, and nothing shown, while it is off
```

`GemicoreCustomerCenter()` draws it inside your own screen. The screen contains:

- A summary of the active entitlements and subscriptions, with the renewal or end date, the billing store and any billing problem.
- **Manage subscription** opens the store page for the subscription outside the app when the opener can (pass `urlOpener:` to change it).
- **Restore purchases**.
- **Get help with a purchase** opens Apple's Report a Problem page (`https://reportaproblem.apple.com`) or Google's order history (`https://play.google.com/store/account/orderhistory`). The purchase's store picks the page, and this device's store applies when there is no purchase.
- **Contact support** opens the support url or a mailto link to the support email.
- **Cancel subscription**, for a store subscription that will renew.
  - The survey (and "Other" with a text field when the config allows it) is recorded with `POST /v1/purchases/customer-center/feedback`.
  - An eligible retention offer is shown first and bought through the normal promotional offer path when accepted. Otherwise the store's management page opens.

Retention offers work for App Store subscriptions only. Google Play refuses a plain purchase of a subscription the customer already holds, and the replacement purchase it needs is not built. When a purchase is pending approval, the screen says so and does not count it as accepted.

The app cannot cancel a store subscription, and the Customer Center never claims it did. The screen says the subscription is cancelled in the store and stays active until then.

- The survey answer is sent in the background and never blocks the customer.
- The screen follows the system text scale, dark and light themes and right to left layouts, and labels have semantics.
- Every label has built in English text (`customerCenterEnglish`) that the config's strings can override per locale, key by key. A survey option label is translated with a `survey_option.<key>` string.
- `presentCustomerCenter` throws a `GemicoreException` when the config cannot be loaded.

## Refund review consent

If you turn on refund reviews in the dashboard, Gemicore answers Apple's consumption request for you, but only for customers who agreed to share usage data. Ask in your own UI, then record the answer:

```dart
await Gemicore.instance.setConsumptionConsent(true);
Gemicore.instance.cachedCustomerInfo?.consumptionConsent;   // the stored answer
```

## Apple Pay and Google Pay inside the app

`payWithCard` opens the gateway's hosted page and needs only the key. `payWithSheet` shows the Apple Pay or Google Pay sheet inside the app, on Stripe's payment sheet (`flutter_stripe` ^14.2.0, a dependency of this package).

The sheet is the default, and `configure` needs nothing extra:

```dart
await Gemicore.configure(apiKey: 'pk_live_...');
final result = await Gemicore.instance.payWithSheet(product, email: 'buyer@example.com');
```

The Stripe publishable key, the merchant country and the Apple Pay merchant id come from the Gemicore server with each payment, and the app sets none of them.

`payWithSheet` asks Gemicore for a payment intent at the catalog price, shows the sheet, and waits for the payment to settle the same way `payWithCard` does. The outcomes are:

- A closed sheet is `PurchaseResult.cancelled`.
- A failed payment throws `GemicoreErrorCode.nativePayFailed` or `paymentFailed`. The `nativePayFailed` message is made of short codes such as `Failed, card_declined` and never includes Stripe's own text or the client secret.
- The sheet shows the app's name from `NativePayRequest.merchantDisplayName`, and the product name when that is empty.
- To use another sheet, implement `NativePaySheet` and pass it as `nativePaySheet`.

**What card payments are for.** `payWithSheet` and `payWithCard` are for **physical goods and real-world services only**: deliveries, tickets, bookings, rides. App Store Review Guideline 3.1.1 and the Google Play payments policy require digital goods, features, content and subscriptions to be sold with the store's own billing (`Gemicore.instance.purchase`). A digital good sold through the sheet can get your app rejected or removed, and Gemicore cannot tell what a product is.

Declare each card price in the dashboard as physical goods or a real-world service. Both calls throw `GemicoreErrorCode.cardSaleNotDeclared` for an undeclared price.

### What you set up in the dashboards

1. In Gemicore, add the app's **own** Stripe credentials (the secret key and the publishable key) and set a card price on the product. The platform's account is never used for the sheet.
   - Without the app's publishable key the intent route answers with a not-configured error.
   - The merchant country is read from that Stripe account.
2. For Apple Pay, enter your Apple Pay merchant id in the app's store settings in Gemicore. Without one the sheet leaves Apple Pay out and offers Google Pay and cards.
3. In Stripe, add the Apple Pay certificate for that merchant id (Stripe dashboard, Settings, Payment methods, Apple Pay). Apple Pay will not complete without it.

### What you set up in the app

#### iOS

- Set the deployment target to iOS 15.0 or higher: `platform :ios, '15.0'` in `ios/Podfile` and the same in Xcode. `stripe_ios` 14.2.0 declares this in its podspec, and the flutter_stripe README says 13.
- Create a merchant id in the Apple Developer account (Certificates, Identifiers & Profiles, Identifiers, Merchant IDs), for example `merchant.com.example.app`.
- In Xcode, select the Runner target, Signing & Capabilities, add the **Apple Pay** capability and tick that merchant id. Xcode writes the `com.apple.developer.in-app-payments` entitlement.
- Use the same merchant id in the Gemicore dashboard (step 2 above). The SDK passes it to `Stripe.merchantIdentifier` for you.
- For card scanning, add `NSCameraUsageDescription` to `Info.plist`.

#### Android

- Use `minSdk` 24 or higher, `compileSdk` 36, Java 17, Kotlin 1.8 or higher, and Android Gradle plugin 8 or higher. `in_app_purchase_android` needs 24 (`stripe_android` alone would allow 21), and `stripe_android` 14.2.0 declares `compileSdk` 36.
- `MainActivity` must extend **`FlutterFragmentActivity`** (`FlutterActivity` is the wrong base class):

  ```kotlin
  import io.flutter.embedding.android.FlutterFragmentActivity

  class MainActivity : FlutterFragmentActivity()
  ```

- The activity's theme must descend from `Theme.AppCompat` (for example `Theme.AppCompat.Light.NoActionBar`) in `res/values/styles.xml`, and in `res/values-night/styles.xml` if you have one. With a plain `Theme.Material` or `Theme.DeviceDefault` theme the sheet crashes or fails to open.
- If you minify release builds, add the ProGuard rules from the flutter_stripe README to `android/app/proguard-rules.pro`:

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

  This line comes from Stripe's Google Pay documentation. Neither plugin ships it, and it could not be checked from this repository.
- Google Pay runs in its test environment with a `pk_test_` key and in production with a live key.
  - Production needs Google's approval of your integration in the Google Pay & Wallet Console, with screenshots of the flow.

#### Both

Rebuild the app after native changes, because hot reload does not pick them up. If the sheet fails with a `PlatformException`, the message gives only the type. Check the Activity base class and the theme first.

### Testing the sheet

`GemicoreStripePaySheet` takes an optional `StripePaymentSheetApi`, a four-method interface over the static Stripe calls. Pass a fake in your own tests so no platform channel is needed:

```dart
GemicoreStripePaySheet(api: MyFakeStripe())
```

`flutter test` in this package covers the outcome mapping, the keys, the Apple Pay and Google Pay parameters and the secret handling against such a fake.

**Nothing here has run on a device, with Stripe's real SDK, or against Apple Pay or Google Pay.** Try a test payment with a `pk_test_` key and a test card on a real iOS device and a real Android device before you ship.

### Sheet notes

- The sheet shows the product's name where Stripe puts the business name (`merchantDisplayName`), because the request has no business name yet.
- `NativePayRequest.amount` is not passed to Stripe, since the payment sheet takes the total from the payment intent the server priced.
- Apple Pay is offered only when the server returns a merchant id. Google Pay and cards are always offered.
- Stripe's static settings (`Stripe.publishableKey`, `Stripe.merchantIdentifier`) are set on every payment. If your app also uses `flutter_stripe` itself with another Stripe account, set them again before your own calls.

## Card, Apple Pay and Google Pay

`payWithCard` runs on the hosted checkout of the gateway the app has in Gemicore (Stripe, Paystack or Flutterwave), and the same limit applies: physical goods and services used outside the app, with digital goods sold through `purchase`. That checkout shows Apple Pay and Google Pay where the gateway and the device support them, and the app needs no merchant id or Apple Pay certificate.

## Platform notes

- **iOS 15 or later.** The plugin uses StoreKit 2, the version Gemicore verifies. Add the In-App Purchase capability in Xcode.
- **Android API 24 or later.** Google Play Billing Library 9.1 comes with `in_app_purchase_android`.
- The customer token is kept in the Keychain or the Android Keystore through `flutter_secure_storage`.
- Purchases are linked to the Gemicore customer through Apple's `appAccountToken` and Google's obfuscated account id, both set to the customer id.

## Testing

`flutter test` runs the SDK tests with a fake transport, storage, store and payment sheet, and none of them reaches the network.

With a `pk_test_` key and no store available (a simulator without a StoreKit configuration, an emulator without Play), `purchase` uses the Gemicore test store and the whole flow runs with no store account. Pass `useTestStore: false` to `configure` to turn that off, or `true` to force it on a test key.

Nothing in this package has been run on a device, or against a real App Store, Google Play, Stripe account or Gemicore production server. The Customer Center, placements, the Android default offer and the context headers are tested against fakes only.
