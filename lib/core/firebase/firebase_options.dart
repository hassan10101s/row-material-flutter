import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Runtime Firebase configuration.
///
/// Values are resolved, in order, from:
///  1. `--dart-define` flags (release builds, see `tool/firebase/README.md`).
///  2. `assets/firebase/firebase.local.json` (developer machine / local build).
///  3. Nothing ⇒ [FirebaseConfig.isConfigured] is `false` and the UI shows the
///     configuration screen instead of crashing at first `runApp`.
class FirebaseConfig {
  const FirebaseConfig({
    this.apiKey = '',
    this.appId = '',
    this.messagingSenderId = '',
    this.projectId = '',
    this.authDomain = '',
    this.storageBucket = '',
    this.googleWebClientId = '',
    this.googleDesktopClientId = '',
    this.googleAndroidClientId = '',
    this.source = FirebaseConfigSource.missing,
  });

  final String apiKey;
  final String appId;
  final String messagingSenderId;
  final String projectId;
  final String authDomain;
  final String storageBucket;
  final String googleWebClientId;

  /// OAuth client id of the **Desktop app** client. This is the one the Windows
  /// loopback flow needs; [googleWebClientId] is kept only as a fallback so
  /// older config files keep resolving.
  final String googleDesktopClientId;

  /// OAuth client id of the **Android** client.
  ///
  /// Kept separate because on Android `GoogleSignIn(clientId:)` is *ignored*:
  /// Play Services resolves the id from `google-services.json`. The value is
  /// therefore only used to decide whether the flow can work at all, and
  /// [googleClientIdFor] deliberately returns the **Desktop** id on Windows and
  /// an empty string on Android so no caller can accidentally hand a Desktop id
  /// to the mobile SDK.
  final String googleAndroidClientId;
  final FirebaseConfigSource source;

  static const String localConfigAsset = 'assets/firebase/firebase.local.json';

  /// Keys required for `initializeApp` to succeed.
  static const List<String> requiredKeys = [
    'FIREBASE_API_KEY',
    'FIREBASE_APP_ID',
    'FIREBASE_MESSAGING_SENDER_ID',
    'FIREBASE_PROJECT_ID',
    'FIREBASE_AUTH_DOMAIN',
  ];

  bool get isConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty &&
      authDomain.isNotEmpty;

  /// The OAuth client id that is meaningful for [platform], or `''` when the
  /// platform resolves its own.
  ///
  /// Windows needs a Desktop client id because `google_sign_in_dartio` drives
  /// the loopback redirect itself. Android resolves the id from
  /// `google-services.json`, so returning the Desktop id there would be a lie
  /// that only surfaces as a confusing auth failure.
  String googleClientIdFor(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return '';
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return googleDesktopClientId.isNotEmpty
            ? googleDesktopClientId
            : googleWebClientId;
      case TargetPlatform.fuchsia:
        return googleWebClientId;
    }
  }

  /// True when Google sign-in has a chance of working on [platform].
  ///
  /// This used to be a flat `googleClientId.isNotEmpty`, which reported
  /// "configured" on a phone purely because a *Desktop* client id existed.
  bool hasGoogleClientIdFor(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return googleAndroidClientId.isNotEmpty;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return googleClientIdFor(platform).isNotEmpty;
    }
  }

  bool get hasGoogleClientId => hasGoogleClientIdFor(defaultTargetPlatform);

  /// Names of the missing values, shown by the configuration screen.
  List<String> get missingKeys {
    final values = <String, String>{
      'FIREBASE_API_KEY': apiKey,
      'FIREBASE_APP_ID': appId,
      'FIREBASE_MESSAGING_SENDER_ID': messagingSenderId,
      'FIREBASE_PROJECT_ID': projectId,
      'FIREBASE_AUTH_DOMAIN': authDomain,
      'FIREBASE_STORAGE_BUCKET': storageBucket,
      'GOOGLE_DESKTOP_CLIENT_ID': googleDesktopClientId.isNotEmpty
          ? googleDesktopClientId
          : googleWebClientId,
      'GOOGLE_ANDROID_CLIENT_ID': googleAndroidClientId,
    };
    return [
      for (final entry in values.entries)
        if (entry.value.isEmpty) entry.key,
    ];
  }

  FirebaseOptions toOptions() => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: messagingSenderId,
        projectId: projectId,
        authDomain: authDomain,
        storageBucket: storageBucket,
      );

  Map<String, String> toRedactedMap() => {
        'FIREBASE_API_KEY': _redact(apiKey),
        'FIREBASE_APP_ID': appId,
        'FIREBASE_MESSAGING_SENDER_ID': messagingSenderId,
        'FIREBASE_PROJECT_ID': projectId,
        'FIREBASE_AUTH_DOMAIN': authDomain,
        'FIREBASE_STORAGE_BUCKET': storageBucket,
        'GOOGLE_DESKTOP_CLIENT_ID': _redact(googleDesktopClientId),
        'GOOGLE_ANDROID_CLIENT_ID': _redact(googleAndroidClientId),
      };

  static String _redact(String value) {
    if (value.isEmpty) return '<missing>';
    if (value.length <= 10) return '***';
    return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
  }

  factory FirebaseConfig.fromMap(Map<String, dynamic> map, {FirebaseConfigSource source = FirebaseConfigSource.localFile}) =>
      FirebaseConfig(
        apiKey: '${map['apiKey'] ?? map['FIREBASE_API_KEY'] ?? ''}',
        appId: '${map['appId'] ?? map['FIREBASE_APP_ID'] ?? ''}',
        messagingSenderId:
            '${map['messagingSenderId'] ?? map['FIREBASE_MESSAGING_SENDER_ID'] ?? ''}',
        projectId: '${map['projectId'] ?? map['FIREBASE_PROJECT_ID'] ?? ''}',
        authDomain: '${map['authDomain'] ?? map['FIREBASE_AUTH_DOMAIN'] ?? ''}',
        storageBucket: '${map['storageBucket'] ?? map['FIREBASE_STORAGE_BUCKET'] ?? ''}',
        googleWebClientId:
            '${map['googleWebClientId'] ?? map['GOOGLE_WEB_CLIENT_ID'] ?? ''}',
        googleDesktopClientId: '${map['googleDesktopClientId'] ?? map['GOOGLE_DESKTOP_CLIENT_ID'] ?? ''}',
        googleAndroidClientId: '${map['googleAndroidClientId'] ?? map['GOOGLE_ANDROID_CLIENT_ID'] ?? ''}',
        source: source,
      );

  /// Build the effective configuration: dart-defines win over the local file.
  static Future<FirebaseConfig> load({AssetBundle? bundle}) async {
    final env = _fromDefines();
    if (env.isConfigured) return env;

    final loader = bundle ?? rootBundle;
    try {
      final raw = await loader.loadString(localConfigAsset);
      if (raw.trim().isEmpty) return env;
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return env;
      final fromFile = FirebaseConfig.fromMap(Map<String, dynamic>.from(parsed));
      if (fromFile.isConfigured) return fromFile;
      return fromFile.source == FirebaseConfigSource.localFile ? fromFile : env;
    } catch (error) {
      if (kDebugMode) debugPrint('[firebase] no local config asset: $error');
      return env;
    }
  }

  static FirebaseConfig _fromDefines() {
    String v(String key) => _lookup(key) ?? '';

    return FirebaseConfig(
      apiKey: v('FIREBASE_API_KEY'),
      appId: v('FIREBASE_APP_ID'),
      messagingSenderId: v('FIREBASE_MESSAGING_SENDER_ID'),
      projectId: v('FIREBASE_PROJECT_ID'),
      authDomain: v('FIREBASE_AUTH_DOMAIN'),
      storageBucket: v('FIREBASE_STORAGE_BUCKET'),
      googleWebClientId: v('GOOGLE_WEB_CLIENT_ID'),
      googleDesktopClientId: v('GOOGLE_DESKTOP_CLIENT_ID'),
      googleAndroidClientId: v('GOOGLE_ANDROID_CLIENT_ID'),
      source: FirebaseConfigSource.dartDefine,
    );
  }
}

enum FirebaseConfigSource { dartDefine, localFile, missing }

/// `--dart-define` readers. `String.fromEnvironment` needs compile-time
/// constant keys, so every value is read explicitly.
String? _lookup(String key) {
  switch (key) {
    case 'FIREBASE_API_KEY':
      return const String.fromEnvironment('FIREBASE_API_KEY');
    case 'FIREBASE_APP_ID':
      return const String.fromEnvironment('FIREBASE_APP_ID');
    case 'FIREBASE_MESSAGING_SENDER_ID':
      return const String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    case 'FIREBASE_PROJECT_ID':
      return const String.fromEnvironment('FIREBASE_PROJECT_ID');
    case 'FIREBASE_AUTH_DOMAIN':
      return const String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
    case 'FIREBASE_STORAGE_BUCKET':
      return const String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
    case 'GOOGLE_WEB_CLIENT_ID':
      return const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
    case 'GOOGLE_DESKTOP_CLIENT_ID':
      return const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
    case 'GOOGLE_ANDROID_CLIENT_ID':
      return const String.fromEnvironment('GOOGLE_ANDROID_CLIENT_ID');
    default:
      return null;
  }
}

/// Thrown when the app is started without a usable Firebase configuration.
class MissingFirebaseConfig implements Exception {
  MissingFirebaseConfig(this.missingKeys);

  final List<String> missingKeys;

  @override
  String toString() =>
      'MissingFirebaseConfig(${missingKeys.join(', ')}). '
      'Pass --dart-define values or add $FirebaseConfig.localConfigAsset.';
}
