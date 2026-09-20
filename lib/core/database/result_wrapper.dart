/// Result wrapper used across repositories. Success carries data, failure
/// carries a user-safe message.
class AppResult<T> {
  final T? data;
  final String? error;
  const AppResult.ok(this.data) : error = null;
  const AppResult.fail(this.error) : data = null;

  bool get isOk => error == null;
  bool get isFail => error != null;

  T get value => data as T;

  AppResult<R> map<R>(R Function(T) fn) =>
      isOk ? AppResult.ok(fn(value)) : AppResult.fail(error);
}