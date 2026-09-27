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
  });

  final CreateMode mode;
  final String name;
  final String inviteCode;
  final bool busy;
  final String? error;

  CreateOrganizationState copyWith({
    CreateMode? mode,
    String? name,
    String? inviteCode,
    bool? busy,
    String? error,
  }) =>
      CreateOrganizationState(
        mode: mode ?? this.mode,
        name: name ?? this.name,
        inviteCode: inviteCode ?? this.inviteCode,
        busy: busy ?? this.busy,
        error: error,
      );

  @override
  List<Object?> get props => [mode, name, inviteCode, busy, error];
}
