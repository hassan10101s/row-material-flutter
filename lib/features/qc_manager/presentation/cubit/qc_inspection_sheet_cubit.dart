import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/utils/app_format.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_inspection.dart';
import '../../domain/qc_nc_capa.dart';
import '../../domain/qc_repositories.dart';
import '../../domain/qc_template.dart';

/// One item on the sheet, paired with whatever has been answered so far.
///
/// The pair is what every rule in this file is written against: [item] says
/// what is allowed, [response] says what was recorded. Keeping them together
/// means the screen cannot accidentally validate a value against a different
/// item's rules than the one it is displaying.
@immutable
class QcSheetItem extends Equatable {
  const QcSheetItem({required this.item, required this.response});

  final QcItem item;

  /// Never null on a live sheet - `createInspection` seeded one row per item.
  /// Null only for an item added to the template after the sheet was started,
  /// which the screen shows as unavailable rather than hiding.
  final QcResponse? response;

  bool get isRecorded => response?.isRecorded ?? false;
  bool get isFail => response?.isFail ?? false;
  bool get isNa => response?.isNa ?? false;
  bool get isCritical => item.isCritical;

  /// Whether submitting is allowed to proceed with this item untouched.
  ///
  /// `required` means the item must carry an explicit verdict, and N/A *is* a
  /// verdict - so `allowNa` widens the set of answers an item accepts rather than
  /// excusing it. Skipping a required question is what blocks; an optional one
  /// may always be left alone.
  bool get isBlocking => item.required && !isRecorded;

  @override
  List<Object?> get props => [item, response];
}

/// One section of the template with its items, in display order.
@immutable
class QcSheetSection extends Equatable {
  const QcSheetSection({required this.section, required this.items});

  final QcSection section;
  final List<QcSheetItem> items;

  int get answered => items.where((i) => i.isRecorded).length;
  int get failed => items.where((i) => i.isFail).length;
  int get total => items.length;

  bool get isComplete => total > 0 && answered == total;

  /// 0..1 for the section's progress bar.
  double get completion => total == 0 ? 0 : answered / total;

  @override
  List<Object?> get props => [section, items];
}

/// Progress over the whole sheet, and the rules that decide whether it may
/// leave the inspector's hands.
@immutable
class QcSheetProgress extends Equatable {
  const QcSheetProgress({
    this.total = 0,
    this.answered = 0,
    this.failed = 0,
    this.criticalFailed = 0,
    this.blocking = 0,
    this.missingEvidence = 0,
    this.maxScore = 0,
    this.earnedScore = 0,
  });

  final int total;
  final int answered;
  final int failed;
  final int criticalFailed;

  /// Items that must be answered and have not been.
  final int blocking;

  /// Failures missing the evidence the template demands.
  final int missingEvidence;

  /// Weight of answered items and of the passing ones among them. Weighted so a
  /// single critical item is not outvoted by twenty trivial ones.
  final int maxScore;
  final int earnedScore;

  double get completion => total == 0 ? 0 : answered / total;

  double get score => maxScore == 0 ? 0 : earnedScore / maxScore;

  bool get isComplete => total > 0 && answered == total;

  /// Whether the sheet is allowed to leave the inspector's hands.
  ///
  /// A critical failure is deliberately *not* here: a failed critical check is
  /// exactly what the reviewer and the 4-eyes rule exist for, so refusing to
  /// submit it would leave the sheet permanently in progress and the NC behind
  /// it permanently unreviewed. The verdict it produces is `Fail`, which is what
  /// blocks approval instead - see [QcInspection.hasCriticalNc].
  bool get canSubmit => blocking == 0 && missingEvidence == 0;

  /// Why it cannot be submitted, in the inspector's language.
  List<String> get blockers => [
    if (missingEvidence > 0)
      AppText.t(
        'ينقص إثبات لـ $missingEvidence بند غير مطابق',
        'Evidence missing on $missingEvidence failed item(s)',
      ),
    if (blocking > 0)
      AppText.t(
        'لم يتم الرد على $blocking بند مطلوب',
        '$blocking required item(s) not answered',
      ),
  ];

  /// Stated before submitting, but not a bar to it.
  ///
  /// A sheet carrying a critical failure goes to review as `Fail`; the inspector
  /// has to know that in advance rather than discover it from the receipt.
  List<String> get advisories => [
    if (criticalFailed > 0)
      AppText.t(
        'يوجد $criticalFailed بند حرج غير مطابق — سيُرسل الفحص للنتيجة «غير مطابق»',
        '$criticalFailed critical item(s) failed — this sheet will be submitted as Fail',
      ),
  ];

  @override
  List<Object?> get props => [
    total,
    answered,
    failed,
    criticalFailed,
    blocking,
    missingEvidence,
    maxScore,
    earnedScore,
  ];
}

@immutable
class QcInspectionSheetState extends Equatable {
  const QcInspectionSheetState({
    this.inspectionId = 0,
    this.inspection,
    this.template,
    this.sections = const [],
    this.responses = const [],
    this.findings = const [],
    this.progress = const QcSheetProgress(),
    this.loading = false,
    this.saving = false,
    this.submitting = false,
    this.error,
    this.notice,
    this.submitted = false,
  });

  final int inspectionId;

  /// Null if the sheet was soft-deleted out from under the open screen.
  final QcInspection? inspection;
  final QcTemplate? template;
  final List<QcSheetSection> sections;

  /// Flat, in `resp_id` order - what the answers are written back from.
  final List<QcResponse> responses;
  final List<QcFindingNc> findings;
  final QcSheetProgress progress;
  final bool loading;
  final bool saving;
  final bool submitting;
  final String? error;

  /// One-shot confirmations for the snackbar.
  final String? notice;

  /// Set once the sheet has been submitted, so the screen can pop itself.
  final bool submitted;

  bool get isEditable => inspection?.isEditable ?? false;

  QcInspectionSheetState copyWith({
    int? inspectionId,
    Object? inspection = _unset,
    Object? template = _unset,
    List<QcSheetSection>? sections,
    List<QcResponse>? responses,
    List<QcFindingNc>? findings,
    QcSheetProgress? progress,
    bool? loading,
    bool? saving,
    bool? submitting,
    Object? error = _unset,
    Object? notice = _unset,
    bool? submitted,
  }) => QcInspectionSheetState(
    inspectionId: inspectionId ?? this.inspectionId,
    inspection: identical(inspection, _unset)
        ? this.inspection
        : inspection as QcInspection?,
    template: identical(template, _unset)
        ? this.template
        : template as QcTemplate?,
    sections: sections ?? this.sections,
    responses: responses ?? this.responses,
    findings: findings ?? this.findings,
    progress: progress ?? this.progress,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    submitting: submitting ?? this.submitting,
    error: identical(error, _unset) ? this.error : error as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
    submitted: submitted ?? this.submitted,
  );

  @override
  List<Object?> get props => [
    inspectionId,
    inspection,
    template,
    sections,
    responses,
    findings,
    progress,
    loading,
    saving,
    submitting,
    error,
    notice,
    submitted,
  ];
}

const _unset = Object();

/// Drives one checklist sheet from start to submit.
///
/// Every write goes through the repository and is followed by a re-read of the
/// affected rows, so the score and verdict on screen are always the ones the
/// database recomputed rather than an optimistic guess. [QcInspectionRepo.answerResponse]
/// does the scoring in the same transaction as the answer precisely so the two
/// cannot drift.
class QcInspectionSheetCubit extends AppCubit<QcInspectionSheetState> {
  QcInspectionSheetCubit({
    required this.repo,
    required this.templates,
    required this.ncCapa,
    required int inspectionId,
  }) : super(QcInspectionSheetState(inspectionId: inspectionId, loading: true));

  final QcInspectionRepository repo;
  final QcTemplateRepository templates;

  /// Only used for the "raise an NC from this item" shortcut, which is the one
  /// action on a sheet that writes outside the inspection's own tables.
  final QcNcCapaRepository ncCapa;

  /// Guards against a load that resolves after a later one.
  int _token = 0;

  /// Drafts the inspector has typed but not yet saved, keyed by item id.
  ///
  /// Held outside the state so that typing never rebuilds the sheet: a
  /// 40-item checklist re-grouping its tree on every keystroke is exactly the
  /// jank this feature exists to avoid. The sheet only re-renders on a commit.
  final Map<int, String> _draftNotes = {};
  final Map<int, String> _draftValues = {};

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final inspection = await repo.getInspection(state.inspectionId);
      if (token != _token) return;
      if (inspection == null) {
        safeEmit(
          state.copyWith(
            loading: false,
            inspection: null,
            error: AppText.t('لم يتم العثور على الفحص', 'Inspection not found'),
          ),
        );
        return;
      }
      // The findings are a third query. A sheet whose NC list is unreadable is
      // still worth showing: the answers are the inspector's own work.
      List<QcFindingNc> findings = const [];
      try {
        findings = await repo.listFindings(state.inspectionId);
      } catch (_) {
        findings = const [];
      }
      if (token != _token) return;
      final responses = await repo.listResponses(state.inspectionId);
      if (token != _token) return;

      // The tree is looked up by the template the sheet was *started* against,
      // not the latest revision, so a template published mid-inspection cannot
      // change what the remaining questions mean.
      final tree = await templates.getTemplateTree(inspection.templateId);
      if (token != _token) return;

      final byItem = {for (final r in responses) r.itemId: r};
      final items = tree?.items ?? const <QcItem>[];
      final grouped = <int, List<QcSheetItem>>{};
      for (final item in items) {
        if (item.isDeleted || item.itemId == null) continue;
        (grouped[item.sectionId] ??= []).add(
          QcSheetItem(item: item, response: byItem[item.itemId]),
        );
      }
      final sections = <QcSheetSection>[];
      for (final section in tree?.sections ?? const <QcSection>[]) {
        if (section.isDeleted) continue;
        final rows = grouped[section.sectionId ?? 0] ?? const [];
        if (rows.isEmpty) continue;
        sections.add(QcSheetSection(section: section, items: rows));
      }
      // Items whose section vanished still have to be answerable, so they are
      // surfaced under an unnamed section instead of silently disappearing.
      final orphans =
          (grouped.keys.toSet()
                ..removeAll(sections.map((s) => s.section.sectionId ?? 0)))
              .map(
                (id) => QcSheetSection(
                  section: QcSection(
                    sectionId: id,
                    templateId: inspection.templateId,
                    title: AppText.t('بنود أخرى', 'Other items'),
                  ),
                  items: grouped[id]!,
                ),
              )
              .toList();
      sections.addAll(orphans);

      safeEmit(
        state.copyWith(
          inspection: inspection,
          template: tree?.template,
          sections: sections,
          responses: responses,
          findings: findings,
          progress: _progress(sections),
          loading: false,
        ),
      );
    } on AppError catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> refresh() => load();

  /// Records one answer.
  ///
  /// [value] is the measurement or free text; [result] is the inspector's
  /// verdict. Numeric items have their verdict *derived* from the bounds rather
  /// than asked for, so a reading of 12 on a 10±1 item cannot be filed as a
  /// pass by a mis-tap.
  ///
  /// Every other field is a partial update: whatever the caller leaves out falls
  /// back to what is already recorded, then to what the inspector has typed but
  /// not yet saved. Tapping "Fail" on an item that already carries a photo and a
  /// note therefore keeps them - otherwise the one-tap answer would quietly erase
  /// the evidence the template demanded, and a long evidence chain would have to
  /// be re-entered every time a verdict was corrected.
  Future<void> answer({
    required QcItem item,
    String result = QcResponseResult.pass,
    String? value,
    String? notes,
    String? defectCode,
    double? measuredValue,
    String? photosJson,
  }) async {
    final inspection = state.inspection;
    if (inspection == null) return;
    if (!inspection.isEditable) {
      _deny(AppText.t('هذا الفحص مقفل', 'This sheet is locked'));
      return;
    }
    final existing = _responseFor(item.itemId);
    if (existing?.respId == null) {
      _deny(
        AppText.t('لا يوجد سجل رد لهذا البند', 'This item has no response row'),
      );
      return;
    }
    final row = existing!;
    final itemId = item.itemId ?? 0;

    final stamp = nowIso();
    final na = QcResponseResult.isNa(result);
    // A staged draft is what the inspector has on screen right now, so it wins
    // over what is on disk; the disk value only matters when nothing was typed.
    final stagedValue = _draftValues[itemId];
    final stagedNotes = _draftNotes[itemId];
    final carriedValue = value ?? stagedValue ?? row.value;
    final carriedMeasured =
        measuredValue ??
        (double.tryParse(stagedValue?.trim().replaceAll(',', '.') ?? '') ??
            row.measuredValue);
    // The numeric verdict is derived from the band of whatever reading is being
    // recorded, so a value that is only staged still cannot pass out of band.
    final resolved = !na && item.isNumeric && carriedMeasured != null
        ? (item.accepts(carriedMeasured)
              ? QcResponseResult.pass
              : QcResponseResult.fail)
        : result;

    final response = QcResponse(
      respId: row.respId,
      inspectionId: inspection.inspectionId ?? state.inspectionId,
      itemId: itemId,
      sectionId: item.sectionId,
      result: na ? QcResponseResult.na : resolved,
      value: carriedValue,
      valueType: item.itemType,
      notes: notes ?? stagedNotes ?? row.notes,
      photosJson: photosJson ?? row.photosJson,
      signatureBase64: row.signatureBase64,
      // Always re-stamped: this write *is* the answer, so the recorded marker
      // has to move forward with it.
      measuredAt: stamp,
      measuredValue: carriedMeasured,
      defectCode: defectCode ?? row.defectCode,
      // The one thing that turns a failed item into a failed *sheet*: only a
      // critical item raises it, so a stray flag cannot fail an inspection.
      isCriticalFailure:
          QcResponseResult.isFail(resolved) && item.raisesCriticalNc,
      createdAt: row.createdAt,
      updatedAt: stamp,
    );

    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.answerResponse(response);
      _draftNotes.remove(itemId);
      _draftValues.remove(itemId);
      // Re-read rather than patch the state: the repository just recomputed
      // score, verdict and NC counts, and those are the numbers on screen.
      await _reloadAfterWrite();
      safeEmit(
        state.copyWith(saving: false, notice: AppText.t('تم الحفظ', 'Saved')),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Quick pass/fail for a boolean or pass/fail item, with no dialog.
  Future<void> markResult(QcItem item, String result) =>
      answer(item: item, result: result);

  /// Records a decline for an item that permits it.
  Future<void> markNotApplicable(QcItem item) async {
    if (!item.allowNa) {
      _deny(AppText.t('هذا البند لا يقبل N/A', 'This item cannot be N/A'));
      return;
    }
    await answer(item: item, result: QcResponseResult.na);
  }

  /// Attaches a photo as evidence for a failure.
  ///
  /// Written as a single answer rather than a second write on top of one: the
  /// evidence is part of the answer, and two writes would emit two audit rows
  /// for one tap.
  Future<void> attachPhoto(QcItem item, String path) async {
    final existing = _responseFor(item.itemId);
    if (existing == null) return;
    await answer(item: item, photosJson: jsonDumps([...existing.photos, path]));
  }

  /// Raises a non-conformance against a failed item.
  ///
  /// Severity defaults to the item's own criticality, so the common case - a
  /// critical item failed - produces the Critical NC the plan requires without
  /// the inspector having to choose.
  Future<void> raiseNc({
    required QcItem item,
    String description = '',
    String severity = '',
  }) async {
    final inspection = state.inspection;
    if (inspection == null) return;
    if (!inspection.isEditable) {
      _deny(AppText.t('هذا الفحص مقفل', 'This sheet is locked'));
      return;
    }
    final respId = _responseFor(item.itemId)?.respId;
    final stamp = nowIso();
    final finding = QcFindingNc(
      inspectionId: inspection.inspectionId ?? state.inspectionId,
      itemId: item.itemId,
      respId: respId,
      code: item.defectCode,
      severity: severity.isNotEmpty
          ? severity
          : (item.isCritical ? NcSeverity.critical : NcSeverity.major),
      description: description.isNotEmpty ? description : item.label,
      createdAt: stamp,
      updatedAt: stamp,
    );
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await ncCapa.createFinding(finding);
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t('تم تسجيل عدم المطابقة', 'Non-conformance logged'),
        ),
      );
      // Creating a finding recomputes the sheet's verdict, so the header has to
      // be re-read or the inspector would submit against a stale score.
      await _reloadAfterWrite();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Saves the inspector's remarks on the sheet header.
  Future<void> saveRemarks(String remarks) async {
    final inspection = state.inspection;
    if (inspection == null || !inspection.isEditable) return;
    if (inspection.remarks == remarks) return;
    final updated = inspection.copyWith(remarks: remarks, updatedAt: nowIso());
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.saveInspection(updated);
      safeEmit(state.copyWith(inspection: updated, saving: false));
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Records a failing answer together with its inline non-conformance.
  ///
  /// Simplified flow (plan §2): the reason + severity are typed directly under
  /// the failed item — no separate NCR window. The finding is logged with the
  /// same stamp so the sheet header and the NCR list agree.
  Future<void> answerFailWithNc({
    required QcItem item,
    String reason = '',
    String severity = '',
  }) async {
    final inspection = state.inspection;
    if (inspection == null || !inspection.isEditable) return;
    await answer(item: item, result: QcResponseResult.fail);
    final desc = reason.trim().isNotEmpty ? reason.trim() : item.label;
    await raiseNc(item: item, description: desc, severity: severity);
  }

  /// Final decision: approve the shipment directly (no review step by default).
  Future<void> approve({String notes = ''}) async {
    final inspection = state.inspection;
    if (inspection == null || !inspection.isEditable) return;
    final progress = _progress(state.sections);
    if (!progress.canSubmit) {
      safeEmit(state.copyWith(error: progress.blockers.join(' • ')));
      return;
    }
    final stamp = nowIso();
    final updated = inspection.copyWith(
      status: QcInspectionStatus.approved,
      resultOverall: QcOverallResult.pass,
      submittedAt: inspection.submittedAt.isEmpty ? stamp : inspection.submittedAt,
      reviewedAt: stamp,
      approvedAt: stamp,
      endAt: inspection.endAt.isEmpty ? stamp : inspection.endAt,
      reviewComments: notes.isNotEmpty ? notes : inspection.reviewComments,
      updatedAt: stamp,
    );
    safeEmit(state.copyWith(submitting: true, error: null));
    try {
      await repo.saveInspection(updated);
      safeEmit(
        state.copyWith(inspection: updated, submitting: false, submitted: true),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(submitting: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(submitting: false, error: '$e'));
    }
  }

  /// Final decision: reject the shipment with a single mandatory note.
  Future<void> reject({required String reason}) async {
    final inspection = state.inspection;
    if (inspection == null || !inspection.isEditable) return;
    if (reason.trim().isEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t('اكتب سبب الرفض', 'A rejection reason is required'),
        ),
      );
      return;
    }
    final stamp = nowIso();
    final updated = inspection.copyWith(
      status: QcInspectionStatus.rejected,
      resultOverall: QcOverallResult.fail,
      submittedAt: inspection.submittedAt.isEmpty ? stamp : inspection.submittedAt,
      rejectedAt: stamp,
      endAt: inspection.endAt.isEmpty ? stamp : inspection.endAt,
      rejectionReason: reason.trim(),
      updatedAt: stamp,
    );
    safeEmit(state.copyWith(submitting: true, error: null));
    try {
      await repo.saveInspection(updated);
      safeEmit(
        state.copyWith(inspection: updated, submitting: false, submitted: true),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(submitting: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(submitting: false, error: '$e'));
    }
  }

  /// Commits the sheet for review.
  ///
  /// Kept for backward compatibility (older sheets / reviewer flow). The
  /// simplified UI calls [approve]/[reject] directly instead.
  ///
  /// Refuses locally on anything [QcSheetProgress.canSubmit] flags, so the
  /// inspector gets an immediate, specific reason instead of a server error. A
  /// critical failure does not refuse it: the sheet is *supposed* to be
  /// submitted as `Fail` so a reviewer can see it, and approval is what the
  /// critical-NC rule closes off.
  Future<void> submit() async {
    final inspection = state.inspection;
    if (inspection == null || !inspection.isEditable) return;
    final progress = _progress(state.sections);
    if (!progress.canSubmit) {
      safeEmit(state.copyWith(error: progress.blockers.join(' • ')));
      return;
    }
    final stamp = nowIso();
    final updated = inspection.copyWith(
      status: QcInspectionStatus.submitted,
      submittedAt: stamp,
      endAt: inspection.endAt.isEmpty ? stamp : inspection.endAt,
      updatedAt: stamp,
    );
    safeEmit(state.copyWith(submitting: true, error: null));
    try {
      await repo.saveInspection(updated);
      safeEmit(
        state.copyWith(inspection: updated, submitting: false, submitted: true),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(submitting: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(submitting: false, error: '$e'));
    }
  }

  /// Stores a typed note without writing it, so typing does not rebuild the tree.
  void stageNotes(int itemId, String notes) => _draftNotes[itemId] = notes;

  /// Stores a typed measurement without writing it.
  void stageValue(int itemId, String value) => _draftValues[itemId] = value;

  /// The staged note for [itemId], falling back to what is persisted.
  String notesFor(QcSheetItem row) =>
      _draftNotes[row.item.itemId] ?? row.response?.notes ?? '';

  /// The staged measurement for [itemId], falling back to what is persisted.
  String valueFor(QcSheetItem row) =>
      _draftValues[row.item.itemId] ?? row.response?.value ?? '';

  /// Whether [itemId] has unsaved typing.
  bool isDirty(int itemId) =>
      _draftNotes.containsKey(itemId) || _draftValues.containsKey(itemId);

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearNotice() => safeEmit(state.copyWith(notice: null));

  void _deny(String message) => safeEmit(state.copyWith(error: message));

  /// The stored response for one item, or null when the template gained the
  /// item after this sheet was started.
  QcResponse? _responseFor(int? itemId) {
    for (final row in state.responses) {
      if (row.itemId == itemId) return row;
    }
    return null;
  }

  /// Re-reads the rows a write touches, without the full tree walk.
  Future<void> _reloadAfterWrite() async {
    final id = state.inspectionId;
    final responses = await repo.listResponses(id);
    final inspection = await repo.getInspection(id);
    final findings = await repo.listFindings(id);
    if (isClosed) return;
    final byItem = {for (final r in responses) r.itemId: r};
    final sections = [
      for (final s in state.sections)
        QcSheetSection(
          section: s.section,
          items: [
            for (final row in s.items)
              QcSheetItem(item: row.item, response: byItem[row.item.itemId]),
          ],
        ),
    ];
    safeEmit(
      state.copyWith(
        inspection: inspection,
        responses: responses,
        findings: findings,
        sections: sections,
        progress: _progress(sections),
      ),
    );
  }

  /// Recomputes progress and every submission rule from the current tree.
  ///
  /// Critical items carry three times the weight of ordinary ones, so a sheet
  /// cannot pass on a wall of trivially-passed questions while its one critical
  /// check sits unweighted with the rest.
  static const int criticalWeight = 3;

  QcSheetProgress _progress(List<QcSheetSection> sections) {
    var total = 0;
    var answered = 0;
    var failed = 0;
    var criticalFailed = 0;
    var blocking = 0;
    var missingEvidence = 0;
    var maxScore = 0;
    var earned = 0;
    for (final section in sections) {
      for (final row in section.items) {
        total++;
        final item = row.item;
        final weight = item.isCritical ? criticalWeight : 1;
        if (row.isRecorded) {
          answered++;
          // An N/A answer counts towards progress but towards neither side of
          // the score, matching `QcInspectionRepo.recompute` - otherwise the
          // percentage here would disagree with the inspection's own
          // `score_pct` after the header is re-read.
          if (!row.isNa) maxScore += weight;
          if (row.isFail) {
            failed++;
            // The same condition `answer` writes into `is_critical_failure`.
            // Counting plain criticality instead would flag a failure the
            // database never treats as critical, and since a critical failure is
            // announced as an advisory the sheet would cry wolf on it.
            if (item.raisesCriticalNc) criticalFailed++;
            if (item.needsEvidenceOnFail && !_hasEvidence(row.response)) {
              missingEvidence++;
            }
          } else if (!row.isNa) {
            earned += weight;
          }
        } else if (row.isBlocking) {
          blocking++;
        }
      }
    }
    return QcSheetProgress(
      total: total,
      answered: answered,
      failed: failed,
      criticalFailed: criticalFailed,
      blocking: blocking,
      missingEvidence: missingEvidence,
      maxScore: maxScore,
      earnedScore: earned,
    );
  }

  static bool _hasEvidence(QcResponse? response) =>
      response != null && response.hasEvidence;
}
