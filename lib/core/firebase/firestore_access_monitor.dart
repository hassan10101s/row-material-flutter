import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../auth/access_monitor.dart';
import '../auth/permissions.dart';
import '../auth/session_source.dart';

/// Three narrow metadata listeners replace repeated identity reads on every
/// page. They run only while the application is in the foreground.
class FirestoreAccessMonitor implements AccessMonitor {
  FirestoreAccessMonitor({
    required this.firestore,
    required this.source,
    required this.onChanged,
    this.onError,
  });
  final FirebaseFirestore firestore;
  final SessionSource source;
  final Future<void> Function() onChanged;
  final void Function(Object)? onError;
  Timer? _expiry;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _processing = false;
  int _generation = 0;

  @override
  void start() {
    stop();
    final actor = source.session;
    if (!actor.isSignedIn || !actor.hasOrganization) return;
    final generation = _generation;
    void watch(String path, bool Function(Map<String, dynamic>) changed) {
      final subscription = firestore
          .doc(path)
          .snapshots()
          .listen(
            (snapshot) {
              if (generation != _generation || snapshot.metadata.isFromCache) {
                return;
              }
              if (!snapshot.exists || changed(snapshot.data()!)) {
                unawaited(_changed(generation));
              }
            },
            onError: (Object error) {
              if (error is FirebaseException &&
                  const [
                    'permission-denied',
                    'unauthenticated',
                  ].contains(error.code)) {
                unawaited(_changed(generation));
              }
            },
          );
      _subscriptions.add(subscription);
    }

    watch(
      'users/${actor.uid}',
      (d) =>
          d['organizationId'] != actor.organizationId ||
          d['status'] != actor.status ||
          AppRoles.normalizeRoles(
                d['roles'],
                fallbackRole: '${d['role']}',
              ).join('|') !=
              actor.rolesKey,
    );
    watch(
      'organizations/${actor.organizationId}',
      (d) =>
          d['status'] != actor.organizationStatus ||
          (d['manuallyActivated'] == true) != actor.manuallyActivated ||
          (d['trialEndsAt'] is Timestamp &&
              (d['trialEndsAt'] as Timestamp)
                      .toDate()
                      .toUtc()
                      .millisecondsSinceEpoch !=
                  DateTime.tryParse(
                    actor.trialEndsAt ?? '',
                  )?.toUtc().millisecondsSinceEpoch),
    );
    watch(
      'organizations/${actor.organizationId}/devices/${actor.deviceId}',
      (d) =>
          d['uid'] != actor.uid ||
          d['status'] != 'active' ||
          (d['readOnly'] == true || rolesAreReadOnly(actor.effectiveRoles)) !=
              actor.readOnlyDevice,
    );
    if (actor.organizationStatus == 'trial' && !actor.manuallyActivated) {
      final end = DateTime.tryParse(actor.trialEndsAt ?? '');
      if (end != null) {
        final delay = end.difference(DateTime.now().toUtc());
        _expiry = Timer(
          delay.isNegative ? Duration.zero : delay,
          () => unawaited(_changed(generation)),
        );
      }
    }
  }

  Future<void> _changed(int generation) async {
    if (_processing || generation != _generation) return;
    _processing = true;
    stop();
    try {
      await onChanged();
    } catch (error) {
      onError?.call(error);
    } finally {
      _processing = false;
    }
  }

  @override
  void stop() {
    _generation++;
    _expiry?.cancel();
    _expiry = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}
