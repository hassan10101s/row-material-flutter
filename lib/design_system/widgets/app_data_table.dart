import 'package:flutter/material.dart';

/// Small, non-paginated tables share the register table's theme and states.
/// Callers own cells, selection and ordering; visual defaults live here.
class AppDataTable extends StatelessWidget {
  const AppDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.showCheckboxColumn = true,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.onSelectAll,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;
  final bool showCheckboxColumn;
  final int? sortColumnIndex;
  final bool sortAscending;
  final ValueChanged<bool?>? onSelectAll;

  @override
  Widget build(BuildContext context) => DataTable(
    columns: columns,
    rows: rows,
    showCheckboxColumn: showCheckboxColumn,
    sortColumnIndex: sortColumnIndex,
    sortAscending: sortAscending,
    onSelectAll: onSelectAll,
  );
}
