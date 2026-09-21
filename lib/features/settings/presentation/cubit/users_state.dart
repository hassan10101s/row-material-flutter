import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../auth/domain/user.dart';

@immutable
class UsersState extends Equatable {
  final bool loading;
  final bool busy;
  final String? error;
  final List<User> users;

  const UsersState({
    this.loading = true,
    this.busy = false,
    this.error,
    this.users = const [],
  });

  UsersState copyWith({
    bool? loading,
    bool? busy,
    String? error,
    List<User>? users,
  }) =>
      UsersState(
        loading: loading ?? this.loading,
        busy: busy ?? this.busy,
        error: error ?? this.error,
        users: users ?? this.users,
      );

  @override
  List<Object?> get props => [loading, busy, error, users];
}