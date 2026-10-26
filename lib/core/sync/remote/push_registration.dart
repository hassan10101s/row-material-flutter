abstract interface class PushRegistration {
  Future<void> register({
    required String organizationId,
    required String uid,
    required String deviceId,
    required String token,
  });
  Future<void> unregister({
    required String organizationId,
    required String uid,
    required String token,
  });
}
