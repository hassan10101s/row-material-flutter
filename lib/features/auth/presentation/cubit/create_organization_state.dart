import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

enum CreateMode { create, invite }

@immutable
class CreateOrganizationState extends Equatable {
  const CreateOrganizationState({
    this.mode = CreateMode.create,
    this.name = '',
    this.inviteCode = '',
    this.busy = false,
    this.error,
    this.emailVerified,
    this.verificationBusy = false,
    this.notice,
  });

  final CreateMode mode;
  final String name;
  final String inviteCode;
  final bool busy;
  final String? error;

  /// Null while unknown (the first check has not completed): the screen then
  /// renders no gate banner yet. False shows the verification banner — the
  /// server rules refuse company genesis / invite reads without it.
  final bool? emailVerified;
  final bool verificationBusy;

  /// Transient confirmation such as "verification link re-sent"; cleared with
  /// any error or new notice. All copyWith arguments are nullable on purpose.
  final String? notice;

  CreateOrganizationState copyWith({
    CreateMode? mode,
    String? name,
    String? inviteCode,
    bool? busy,
    String? error,
    bool? emailVerified,
    bool? verificationBusy,
    String? notice,
  }) => CreateOrganizationState(
    mode: mode ?? this.mode,
    name: name ?? this.name,
    inviteCode: inviteCode ?? this.inviteCode,
    busy: busy ?? this.busy,
    error: error,
    emailVerified: emailVerified ?? this.emailVerified,
    verificationBusy: verificationBusy ?? this.verificationBusy,
    notice: notice,
  );

  @override
  List<Object?> get props => [
    mode,
    name,
    inviteCode,
    busy,
    error,
    emailVerified,
    verificationBusy,
    notice,
  ];
}
