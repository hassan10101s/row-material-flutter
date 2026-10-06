import '../../../core/constants/app_errors.dart';
import '../../../core/utils/app_exceptions.dart';

/// The single definition of the two parameter kinds everything inherits from.
///
/// Chemical (التحليل الكيميائي) and physical (الفحص الظاهري) are disjoint
/// vocabularies: the reference tabs, the material editor, the lab analyses
/// and the material bounds all speak about the same two kinds. They used to
/// be scattered `'chemical'` / `'physical'` string literals with a silent
/// `?? 'physical'` fallback wherever a value was missing — which is how an
/// entire seed file of mixed elements ended up listed under physical.
///
/// Rules, in one place:
/// * writers are always explicit ([parse] throws on anything else);
/// * readers of legacy/dirty data use [ofDb], which never silently picks
///   physical — it matches [ReferenceRepository.upsertParameter]'s default.
enum ParameterType {
  chemical('chemical'),
  physical('physical');

  const ParameterType(this.value);

  /// The exact string stored in SQLite (`parameters.parameter_type`,
  /// `material_parameter_bounds.parameter_type`).
  final String value;

  bool get isChemical => this == ParameterType.chemical;
  bool get isPhysical => this == ParameterType.physical;

  String get labelAr => this == ParameterType.chemical ? 'كيميائي' : 'ظاهري';

  String get labelEn =>
      this == ParameterType.chemical ? 'Chemical' : 'Physical';

  /// Writer-side parser: only the two known values are accepted.
  static ParameterType parse(String raw) {
    final v = raw.trim().toLowerCase();
    for (final type in ParameterType.values) {
      if (type.value == v) return type;
    }
    throw ValidationError(AppErrors.parameterTypeInvalid);
  }

  /// Reader-side parser for legacy/dirty data: `null`, empty or unknown
  /// values read as [chemical], never as physical. A missing type must not
  /// quietly file a row under physical — that silent default is what hid
  /// the whole chemical vocabulary in the physical tab.
  static ParameterType ofDb(Object? raw) {
    final v = '${raw ?? ''}'.trim().toLowerCase();
    if (v == ParameterType.physical.value) return ParameterType.physical;
    return ParameterType.chemical;
  }

  /// Filter helper: keeps only rows whose `parameter_type` column (or key)
  /// equals this kind, tolerating dirty data through [ofDb].
  bool matches(Object? raw) => ofDb(raw) == this;
}
