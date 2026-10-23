import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/trial_policy.dart';

/// One-time 30-day trial truth table, including the hard guarantee:
/// a manually activated company is NEVER blocked again.
void main() {
  final created = DateTime.utc(2026, 1, 1, 12);
  final endsAt = TrialPolicy.endsAtFor(created).toIso8601String();

  group('TrialPolicy.endsAtFor', () {
    test('adds exactly 30 days', () {
      expect(
        TrialPolicy.endsAtFor(created),
        DateTime.utc(2026, 1, 31, 12),
      );
    });
  });

  group('shouldBlock (client gate)', () {
    test('trial inside window is not blocked', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 15),
        ),
        isFalse,
      );
    });

    test('trial one second before expiry is not blocked', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 31, 11, 59, 59),
        ),
        isFalse,
      );
    });

    test('trial at/after expiry is blocked', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 31, 12),
        ),
        isTrue,
      );
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 3, 1),
        ),
        isTrue,
      );
    });

    test('suspended is always blocked', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.suspended,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 2),
        ),
        isTrue,
      );
    });

    test('active trial-window org is not blocked', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.active,
          manuallyActivated: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 2),
        ),
        isFalse,
      );
    });

    // ── THE HARD GUARANTEE ──────────────────────────────────────────
    test('manually activated org is never blocked, even after 100 days', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.active,
          manuallyActivated: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 4, 11, 12), // endsAt + 70 days
        ),
        isFalse,
      );
    });

    test('manually activated org is never blocked, even after a year', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.active,
          manuallyActivated: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 6, 1),
        ),
        isFalse,
      );
    });

    test('manuallyActivated wins even with a suspended status label', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.suspended,
          manuallyActivated: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 6, 1),
        ),
        isFalse,
      );
    });

    test('legacy trial without dates is not blocked by a parse error', () {
      expect(
        TrialPolicy.shouldBlock(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialEndsAt: null,
          now: DateTime.utc(2026, 6, 1),
        ),
        isFalse,
      );
    });
  });

  group('shouldSuspend (server cron)', () {
    test('suspends an expired untouched trial', () {
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialConsumed: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 2, 1),
        ),
        isTrue,
      );
    });

    test('does not suspend inside the window', () {
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialConsumed: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2026, 1, 15),
        ),
        isFalse,
      );
    });

    test('never suspends an active org', () {
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.active,
          manuallyActivated: false,
          trialConsumed: false,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 1, 1),
        ),
        isFalse,
      );
    });

    test('never suspends a manually activated org', () {
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.active,
          manuallyActivated: true,
          trialConsumed: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 1, 1),
        ),
        isFalse,
      );
    });

    test('never re-suspends a consumed trial (idempotent retry)', () {
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.suspended,
          manuallyActivated: false,
          trialConsumed: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 1, 1),
        ),
        isFalse,
      );
      expect(
        TrialPolicy.shouldSuspend(
          status: OrgStatus.trial,
          manuallyActivated: false,
          trialConsumed: true,
          trialEndsAt: endsAt,
          now: DateTime.utc(2027, 1, 1),
        ),
        isFalse,
      );
    });
  });
}
