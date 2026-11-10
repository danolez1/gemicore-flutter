import 'package:url_launcher/url_launcher.dart';

/// Opens the hosted checkout. An in-app browser view (SFSafariViewController, Custom Tabs) is used
/// because both support Apple Pay and Google Pay on the gateway's page, which a web view does not.
abstract interface class CheckoutOpener {
  Future<bool> open(Uri url);
}

/// An opener that can also hand a page to the system: the browser app, the App Store or Play Store
/// app, the mail app. The Customer Center uses it for store pages and mailto links when the opener
/// passed to configure implements it; otherwise it falls back to [CheckoutOpener.open].
abstract interface class ExternalUrlOpener {
  Future<bool> openExternal(Uri url);
}

class InAppBrowserCheckoutOpener implements CheckoutOpener, ExternalUrlOpener {
  const InAppBrowserCheckoutOpener();

  @override
  Future<bool> open(Uri url) => launchUrl(url, mode: LaunchMode.inAppBrowserView);

  @override
  Future<bool> openExternal(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);
}
