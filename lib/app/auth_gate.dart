import 'package:flutter/foundation.dart';

import '../features/auth/data/auth_repo.dart';
import '../features/auth/domain/user.dart';

/// Observable auth state used by the router to re-evaluate guards after
/// login/logout/restore.
class AuthGate extends ChangeNotifier {
  AuthGate(this.auth);

  final AuthRepo auth;

  User? get currentUser => auth.currentUser;

  void updated() => notifyListeners();
}