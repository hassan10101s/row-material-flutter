import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class LabState extends Equatable {
  final int tab;
  final int historyTick;

  const LabState({this.tab = 0, this.historyTick = 0});

  LabState copyWith({int? tab, int? historyTick}) =>
      LabState(tab: tab ?? this.tab, historyTick: historyTick ?? this.historyTick);

  @override
  List<Object?> get props => [tab, historyTick];
}