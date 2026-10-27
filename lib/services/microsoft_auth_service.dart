import 'package:msal_js/msal_js.dart';

class MicrosoftAuthService {
  MicrosoftAuthService._();

  static final PublicClientApplication instance = PublicClientApplication(
    Configuration()
      ..auth = (BrowserAuthOptions()
        ..clientId = '85ed0076-771e-42aa-9719-0d1d58dea06a'
        ..authority =
            'https://login.microsoftonline.com/1b811fde-cb38-4bcf-9ae4-abf62a0a84e9'
        ..redirectUri = Uri.base.resolve('/').toString()),
  );

  static Future<bool> handleRedirect() async {
    final result = await instance.handleRedirectFuture();
    if (result != null) instance.setActiveAccount(result.account);
    return instance.getActiveAccount() != null;
  }

  static Future<void> signIn() async {
    await instance.loginRedirect(
      RedirectRequest()..scopes = ['openid', 'profile', 'email'],
    );
  }

  static Future<String> currentUserId() async {
    final account = instance.getActiveAccount();
    if (account == null || account.localAccountId.isEmpty) {
      throw StateError('Please sign in with Microsoft again.');
    }
    return account.localAccountId;
  }

  static Future<String> acquireIdToken() async {
    final account = instance.getActiveAccount();
    if (account == null) {
      throw StateError('Please sign in with Microsoft again.');
    }
    final result = await instance.acquireTokenSilent(
      SilentRequest()
        ..account = account
        ..scopes = ['openid', 'profile', 'email'],
    );
    if (result.idToken.isEmpty) {
      throw StateError('Microsoft did not return an ID token.');
    }
    return result.idToken;
  }
}
