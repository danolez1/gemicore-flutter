## 0.4.1

### Changed

- The README and the changelog are rewritten in plainer, shorter sentences.
- The Dart code is the same as in 0.4.0.

## 0.4.0

This release folds the payment sheet into the main package.

### Changed

- `gemicore_flutter` includes the Apple Pay and Google Pay sheet that shipped as `gemicore_flutter_stripe`.
- `GemicoreStripePaySheet` is exported and is the default for `payWithSheet`.
- `Gemicore.configure(apiKey: ...)` is the whole setup, and `nativePaySheet` is only for replacing the sheet.
- `flutter_stripe` ^14.2.0 is a dependency.
- Every app needs iOS 15 or higher and the Android settings in the README (`compileSdk` 36, Java 17).
- The Apple Pay capability, `FlutterFragmentActivity` and an AppCompat theme are needed only to show the sheet.

### Removed

- `GemicoreErrorCode.nativePayNotConfigured`, because a sheet is always present.

## 0.3.0

This release adds customer attributes, placements and the Customer Center.

### Added

- `setAttributes(Map<String, String?>)` sets customer attributes, and a null value deletes the key.
- `setEmail`, `setDisplayName` and `setPhoneNumber` are new customer attribute methods.
- Attribute limits are checked before the request and fail with `GemicoreErrorCode.invalidAttributes`: 50 keys per call, the key pattern, 256 characters, and only the reserved `$` names.
- The server's own refusal is `GemicoreErrorCode.attributesInvalid`. Values are never logged and never put in an error.
- `x-gemicore-app-version` is sent on every request, next to `x-gemicore-platform`.
- The version comes from `package_info_plus` or the new `appVersionProvider` of `configure`. The header is left out when the lookup fails, as under `flutter test` without a provider.
- `x-gemicore-country` goes out with every request. It is the device locale's two letter country code in upper case, and it is omitted when there is none.
- Both headers are sent without extra setup, because the API key is the only required setting.
- `getOfferings(placement:)` and `presentPaywall(context, placement:)` take a placement.
- `Offerings.placement` says how the server resolved it, as a `PlacementResolution` (identifier, source, and the experiment identifier and variant).
- Each placement has its own five minute memory copy and its own copy on the device.
- A placement the server does not know or rejects will give the app's current offering.
- Experiments need no extra call, because reading the placement enrolls the customer on the server.
- Android default offer: a Google subscription bought with no explicit offer buys the offer named by the product's `defaultGoogleOfferId`.
- That offer is bought if Play lists it for the base plan, and the plain base plan is bought otherwise. Play lists only the offers the customer is eligible for.
- `{{package.trial}}` on Android shows the trial of the default offer.
- `GemicoreProduct.defaultGoogleOfferId`, `defaultOfferDetails` and `ProductOffer.isDefault` are new fields.
- Customer Center data: `getCustomerCenter()`, `CustomerCenterView` and `CustomerCenterConfig`.
- `CustomerCenterConfig` holds strings by locale, with built in English for every label (see `customerCenterEnglish`).
- The `GemicoreCustomerCenter` widget and `presentCustomerCenter(context)` show the Customer Center.
- `presentCustomerCenter(context)` returns false without showing anything while the dashboard has the Customer Center off.
- The Customer Center summarizes the active entitlements and subscriptions and opens the store page that manages a subscription.
- It also restores purchases and reaches support.
- It opens the store's own refund help: Apple Report a Problem or Google order history, by the store of the purchase.
- The cancel flow runs a survey, then an eligible retention offer, then the store's management page.
- The retention offer goes through the normal promotional offer purchase.
- The Customer Center never cancels anything itself, because cancellation happens in the store.
- `sendCancelFeedback` posts the survey answer, and a failure there never blocks the customer.
- The survey answer is sent in the background, and not at all when the offer dialog is dismissed.
- Retention offers are shown for App Store subscriptions only, because a Google Play offer needs a replacement purchase that is not built yet.
- A pending purchase will show `retention_pending` and is sent as not accepted.
- The Customer Center screen reloads the server's view after an offer or a retry.
- The capitalised store name has its own key, `store_app_store_title`.
- A malformed support url will say `error_generic`.
- `ExternalUrlOpener` is implemented by the default opener.
- The Customer Center opens store pages and mailto links outside the app when the opener can.
- `Gemicore.openExternalUrl` takes an optional `opener`, and `Gemicore.platform` is new.
- `package_info_plus` is added as a dependency.

### Changed

- Offerings copies belong to the customer: `logIn`, `logOut` and `setAttributes` drop the memory copy.
- `setAttributes` also drops the device copy of what was read, and a device copy saved for another customer is ignored.
- An offline first read of a placement falls back to the app's saved offerings.
- The default app version lookup runs without holding `configure` and without checking `FLUTTER_TEST`.
- A provider passed to `configure` is awaited for up to three seconds.

## 0.2.0

This release adds offerings, paywalls, promotional offers and card sale declarations.

### Added

- `getOfferings()`, `currentOffering`, the `Offering` and `Package` models, and `purchasePackage(package)`.
- `getOfferings()` is cached in memory for five minutes and kept on the device for an offline start.
- The `Offering` and `Package` models have store prices merged in.
- The `GemicorePaywall` widget draws the paywall designed in the dashboard.
- It handles every node type, theme, and strings by device locale.
- It also handles store price variables, text scale, semantics, right to left, https images and an injectable link opener.
- Unknown or malformed nodes are left out and never throw.
- `presentPaywall(context)` shows the paywall full screen and returns a `PaywallResult`.
- `getEligibleOffers(product)` and `purchase(product, offer:)` cover App Store promotional and win-back offers and Google Play base plan offers.
- `useServerIntroEligibility` is an opt in for server side introductory offer eligibility.
- `setConsumptionConsent(bool)` answers refund reviews, and the answer is kept in `CustomerInfo.consumptionConsent`.
- Native pay: the `NativePaySheet` interface, the `nativePaySheet` parameter of `configure` and `payWithSheet(product, email:)`.
- The sheet itself is in the gemicore_flutter_stripe package.
- The `intl` dependency is new, for the per month price on paywalls.
- Verified identity: the optional `userTokenProvider` of `configure` sends `x-user-token` when a customer is linked to an app user id.
- `configure(appUserId:)` and `logIn` do the linking.
- Card sale declaration: the server refuses card checkout for a product whose card price was never declared as physical goods or a real world service.
- The response is 422 `PURCHASE_NOT_FOR_CARD`, reason `card_sale_kind_missing`.
- `payWithCard` and `payWithSheet` throw `GemicoreErrorCode.cardSaleNotDeclared` for it, with a message that says what to declare in the dashboard.
- A product with no card price at all will throw `notForCard`.
- `NativePayRequest.merchantDisplayName` is the app's name from the card intent, for the payment sheet.
- It is empty from a server that does not send it.
- Card and sheet polling takes an optional `cancel:` future.

### Changed

- Breaking for custom store bridges: `StoreBridge.buy` takes an optional `offer`.
- `StoreProductDetails` has `offerId`, `subscriptionPeriod` and `trialPeriod`.
- `basePlanId` is set on Google Play offer entries too, and the entry with no `offerId` is the plain base plan.
- Store updates are held until `configure` has the customer token.
- A purchase the server could not take is retried on a timer, on resume and after `logIn`.
- Polling for a card or a sheet emits no stream event and writes no cache for unchanged data.
- A failed, expired or refunded payment will throw `GemicoreErrorCode.paymentFailed` and return no cancelled result.
- `presentPaywall` keeps the paywall open and shows the message for a network error or a purchase already in progress.
- Hero images are decoded at the drawn width.

### Fixed

- A failed `configure` closes the instance it started, and a retry does not run two store listeners.
- A recorded purchase or a customer refresh succeeds when the cache write fails (locked Keychain).
- `hasEntitlement` reports an entitlement as inactive after its expiry, grace period aside.
- A store that was unavailable once is asked again.
- A failed availability check sends no test key to the test store.
- `restorePurchases()` called while a restore runs returns that restore.

## 0.1.0

This is the first release.

### Added

- `Gemicore.configure(apiKey:)` is the only setup.
- Anonymous customers, with log in and log out.
- The dashboard product catalog with store prices.
- App Store and Google Play purchases, recorded with Gemicore before the store transaction is finished.
- Restore of purchases.
- One-time card, Apple Pay and Google Pay payments through the app's gateway.
- Customer info with an offline cache and a change stream.
- The Gemicore test store for test keys.
