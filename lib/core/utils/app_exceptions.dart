import '../constants/app_strings.dart';

/// An error whose [userMessage] is already safe to show to a person.
///
/// Anything that is not marked this way must never reach the UI: its
/// `toString()` may carry driver internals (SQL, auth providers, stack data).
abstract interface class UserFacingError {
  String get userMessage;
}

/// A durably saved request that still needs a server decision. Presentation
/// should describe its pending state instead of presenting it as a failed save.
abstract interface class PendingOperation implements UserFacingError {}

class AppError implements Exception, UserFacingError {
  final String message;
  const AppError(this.message);
  @override
  String get userMessage => message;
  @override
  String toString() => message;

  /// A message for [error] that is safe to render, or a generic fallback.
  ///
  /// Cubits use this in their `catch` fallbacks so a raw driver exception can
  /// never be stored in state and end up on screen.
  static String friendly(Object error) {
    if (error is UserFacingError) {
      final text = error.userMessage.trim();
      if (text.isNotEmpty) return text;
    }
    return AppText.t(
      'حدث خطأ غير متوقع. حاول مرة أخرى.',
      'Something went wrong. Please try again.',
    );
  }
}

class ValidationError extends AppError {
  const ValidationError(super.message);
}

class AuthorizationError extends AppError {
  const AuthorizationError(super.message);
}

class NotFoundError extends AppError {
  const NotFoundError(super.message);
}
