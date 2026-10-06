import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_repositories.dart';
import '../../domain/qc_template.dart';

/// How the template library is narrowed.
class QcTemplateFilters extends Equatable {
  const QcTemplateFilters({
    this.types = const {},
    this.dept = '',
    this.text = '',
    this.publishedOnly = false,
    this.includeArchived = false,
  });

  final Set<String> types;
  final String dept;

  /// Free text over name and code, applied in memory - the query has no such
  /// column and pretending otherwise would only move the surprise.
  final String text;

  /// The only mode that matters on the run floor: what can an inspection be
  /// started from right now.
  final bool publishedOnly;

  final bool includeArchived;

  bool get isEmpty =>
      types.isEmpty &&
      dept.isEmpty &&
      text.isEmpty &&
      !publishedOnly &&
      !includeArchived;

  QcTemplateFilters copyWith({
    Set<String>? types,
    String? dept,
    String? text,
    bool? publishedOnly,
    bool? includeArchived,
  }) => QcTemplateFilters(
    types: types ?? this.types,
    dept: dept ?? this.dept,
    text: text ?? this.text,
    publishedOnly: publishedOnly ?? this.publishedOnly,
    includeArchived: includeArchived ?? this.includeArchived,
  );

  @override
  List<Object?> get props => [
    (types.toList()..sort()),
    dept,
    text,
    publishedOnly,
    includeArchived,
  ];
}

class QcTemplateSummary extends Equatable {
  const QcTemplateSummary({
    this.total = 0,
    this.published = 0,
    this.drafts = 0,
    this.available = 0,
  });

  final int total;
  final int published;
  final int drafts;

  /// Published, in date, not archived - the templates an inspection can start
  /// from.
  final int available;

  factory QcTemplateSummary.from(List<QcTemplate> templates) =>
      QcTemplateSummary(
        total: templates.length,
        published: templates.where((t) => t.isPublished).length,
        drafts: templates.where((t) => !t.isPublished && !t.isArchived).length,
        available: templates.where((t) => t.isAvailable).length,
      );

  @override
  List<Object?> get props => [total, published, drafts, available];
}

@immutable
class QcTemplatesState extends Equatable {
  const QcTemplatesState({
    this.templates = const [],
    this.filters = const QcTemplateFilters(),
    this.summary = const QcTemplateSummary(),
    this.loading = false,
    this.saving = false,
    this.error,
  });

  final List<QcTemplate> templates;
  final QcTemplateFilters filters;
  final QcTemplateSummary summary;
  final bool loading;
  final bool saving;
  final String? error;

  QcTemplatesState copyWith({
    List<QcTemplate>? templates,
    QcTemplateFilters? filters,
    QcTemplateSummary? summary,
    bool? loading,
    bool? saving,
    Object? error = _unset,
  }) => QcTemplatesState(
    templates: templates ?? this.templates,
    filters: filters ?? this.filters,
    summary: summary ?? this.summary,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
  );

  @override
  List<Object?> get props => [
    templates,
    filters,
    summary,
    loading,
    saving,
    error,
  ];
}

const _unset = Object();

/// The checklist template library.
///
/// Publication rules belong to the guarded repository. What this cubit owns is
/// the *question* - may this tree be issued? - so the editor can say why a
/// publish button is disabled instead of letting the reader press it and be
/// refused.
class QcTemplatesCubit extends AppCubit<QcTemplatesState> {
  QcTemplatesCubit({required this.repo, QcTemplateFilters? initialFilters})
    : super(
        QcTemplatesState(
          filters: initialFilters ?? const QcTemplateFilters(),
          loading: true,
        ),
      );

  final QcTemplateRepository repo;
  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await _query(state.filters);
      if (token != _token) return;
      safeEmit(
        state.copyWith(
          templates: rows,
          summary: QcTemplateSummary.from(rows),
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

  Future<void> applyFilters(QcTemplateFilters filters) async {
    safeEmit(state.copyWith(filters: filters, templates: const []));
    await load();
  }

  Future<void> toggleType(String type) async {
    final next = {...state.filters.types};
    if (!next.remove(type)) next.add(type);
    await applyFilters(state.filters.copyWith(types: next));
  }

  Future<void> clearFilters() => applyFilters(const QcTemplateFilters());

  void clearError() => safeEmit(state.copyWith(error: null));

  Future<int?> createTemplate(QcTemplate template) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final id = await repo.createTemplate(template);
      safeEmit(state.copyWith(saving: false));
      await load();
      return id;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
    return null;
  }

  Future<void> deleteTemplate(int templateId) =>
      _guard(() async => repo.deleteTemplate(templateId));

  Future<void> archiveTemplate(int templateId) =>
      _guard(() async => repo.archiveTemplate(templateId));

  /// Copies a template into a fresh draft version.
  ///
  /// This is the only way a published checklist changes: the issued one stays
  /// frozen, because an inspection performed against it has to keep resolving
  /// the same questions.
  Future<int?> duplicateTemplate(
    int templateId,
    String newCode,
    String newName,
  ) async {
    if (newName.trim().isEmpty) {
      safeEmit(
        state.copyWith(error: AppText.t('الاسم مطلوب', 'A name is required')),
      );
      return null;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final id = await repo.duplicateTemplate(
        templateId,
        newCode.trim(),
        newName.trim(),
      );
      safeEmit(state.copyWith(saving: false));
      await load();
      return id;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
    return null;
  }

  Future<void> _guard(Future<void> Function() action) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await action();
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<List<QcTemplate>> _query(QcTemplateFilters filters) async {
    var rows = await repo.listTemplates(
      dept: filters.dept,
      publishedOnly: filters.publishedOnly,
    );
    // `listTemplates` filters department and publication but not type, archived
    // or free text, so the rest is applied here and said so.
    if (!filters.includeArchived) {
      rows = rows.where((t) => !t.isArchived).toList();
    }
    if (filters.types.isNotEmpty) {
      rows = rows.where((t) => filters.types.contains(t.type)).toList();
    }
    final needle = filters.text.trim().toLowerCase();
    if (needle.isNotEmpty) {
      rows = rows
          .where(
            (t) =>
                t.name.toLowerCase().contains(needle) ||
                t.code.toLowerCase().contains(needle),
          )
          .toList();
    }
    return rows;
  }
}

@immutable
class QcTemplateDetailState extends Equatable {
  const QcTemplateDetailState({
    this.templateId = 0,
    this.template,
    this.sections = const [],
    this.items = const [],
    this.loading = false,
    this.saving = false,
    this.dirty = false,
    this.error,
    this.notice,
  });

  final int templateId;
  final QcTemplate? template;

  /// Display order, as the repository returns it.
  final List<QcSection> sections;
  final List<QcItem> items;

  /// Set by any structural edit, cleared by a save. Drives the "unsaved changes"
  /// affordance and stops a reader walking away from a tree they just edited.
  final bool dirty;

  final bool loading;
  final bool saving;
  final String? error;
  final String? notice;

  /// A published template is frozen: its tree changes by becoming a new draft
  /// version, not by editing this one.
  bool get isFrozen => template?.isPublished ?? false;

  /// Whether an inspection may be started from this template right now.
  bool get canStartInspection => template?.isAvailable ?? false;

  /// Live items of a section, in display order.
  ///
  /// Tombstones are kept in [items] but not offered here: an item the reader
  /// just removed is gone from the editor, while the row stays in state so the
  /// tree still knows what happened to it before the next save.
  List<QcItem> itemsFor(int sectionId) =>
      items.where((i) => i.sectionId == sectionId && !i.isDeleted).toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  /// Live sections, in display order - the same tombstone rule as [itemsFor].
  List<QcSection> get liveSections =>
      sections.where((s) => !s.isDeleted).toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  /// Everything that would make publication a lie, stated in the reader's terms.
  ///
  /// The repository refuses these too. Listing them here is what turns a disabled
  /// button into an explained one.
  List<String> get blockers {
    final problems = <String>[];
    if (sections.isEmpty) {
      problems.add(
        AppText.t('لا توجد أقسام', 'The checklist has no sections yet'),
      );
    }
    if (items.isEmpty) {
      problems.add(AppText.t('لا توجد بنود', 'The checklist has no items yet'));
    }
    for (final section in sections) {
      if (itemsFor(section.sectionId ?? 0).isEmpty) {
        problems.add(
          AppText.t(
            'القسم "${section.title}" بلا بنود',
            'Section "${section.title}" has no items',
          ),
        );
      }
    }
    for (final item in items) {
      if (item.label.trim().isEmpty) {
        problems.add(
          AppText.t('يوجد بند بلا نص', 'There is an item with no label'),
        );
      }
      if ((item.itemType == QcItemType.dropdown ||
              item.itemType == QcItemType.multiSelect) &&
          item.options.isEmpty) {
        problems.add(
          AppText.t(
            'بند قائمة بدون خيارات: ${item.label}',
            'A list item has no options: ${item.label}',
          ),
        );
      }
    }
    return problems;
  }

  bool get canPublish => blockers.isEmpty && !isFrozen;

  QcTemplateDetailState copyWith({
    int? templateId,
    Object? template = _unset,
    List<QcSection>? sections,
    List<QcItem>? items,
    bool? dirty,
    bool? loading,
    bool? saving,
    Object? error = _unset,
    Object? notice = _unset,
  }) => QcTemplateDetailState(
    templateId: templateId ?? this.templateId,
    template: identical(template, _unset)
        ? this.template
        : template as QcTemplate?,
    sections: sections ?? this.sections,
    items: items ?? this.items,
    dirty: dirty ?? this.dirty,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
  );

  @override
  List<Object?> get props => [
    templateId,
    template,
    sections,
    items,
    dirty,
    loading,
    saving,
    error,
    notice,
  ];
}

/// One template and the tree that makes it a checklist.
///
/// Edits are held in memory and written as one `saveTemplateTree`, because the
/// repository replaces the whole tree in a single transaction: a half-saved
/// checklist is not a checklist anyone can sign.
class QcTemplateDetailCubit extends AppCubit<QcTemplateDetailState> {
  QcTemplateDetailCubit({
    required this.repo,
    required this.library,
    required int templateId,
  }) : super(QcTemplateDetailState(templateId: templateId, loading: true));

  final QcTemplateRepository repo;

  /// The library cubit, so publishing or retiring here shows up in the list
  /// behind it instead of needing a second refresh call nobody remembers.
  final QcTemplatesCubit library;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final tree = await repo.getTemplateTree(state.templateId);
      if (token != _token) return;
      if (tree == null) {
        safeEmit(
          state.copyWith(
            loading: false,
            template: null,
            error: AppText.t(
              'القالب غير موجود',
              'This template no longer exists',
            ),
          ),
        );
        return;
      }
      safeEmit(
        state.copyWith(
          loading: false,
          template: tree.template,
          sections: tree.sections,
          items: tree.items,
          dirty: false,
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

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearNotice() => safeEmit(state.copyWith(notice: null));

  void addSection(String title) {
    final template = state.template;
    if (template == null || title.trim().isEmpty) return;
    final section = QcSection(
      sectionId: -state.sections.length - 1,
      templateId: state.templateId,
      title: title.trim(),
      orderIndex: state.sections.length,
    );
    safeEmit(
      state.copyWith(sections: [...state.sections, section], dirty: true),
    );
  }

  void updateSection(int sectionId, QcSection section) {
    safeEmit(
      state.copyWith(
        sections: [
          for (final s in state.sections)
            if (s.sectionId == sectionId) section else s,
        ],
        dirty: true,
      ),
    );
  }

  /// Retires a section, and everything under it.
  ///
  /// A tombstone, not a delete: an inspection performed last quarter still
  /// points at these items and has to be able to render the question it asked.
  void removeSection(int sectionId) {
    final exists = state.sections.any((s) => s.sectionId == sectionId);
    if (!exists) {
      safeEmit(
        state.copyWith(error: AppText.t('القسم غير موجود', 'No such section')),
      );
      return;
    }
    safeEmit(
      state.copyWith(
        sections: [
          for (final s in state.sections)
            if (s.sectionId == sectionId)
              s.copyWith(deletedAt: nowIso())
            else
              s,
        ],
        items: [
          for (final i in state.items)
            if (i.sectionId == sectionId)
              i.copyWith(deletedAt: nowIso())
            else
              i,
        ],
        dirty: true,
      ),
    );
  }

  /// New items get a negative id so they are addressable while the tree is
  /// still in memory; `saveTemplateTree` replaces the tree and the database
  /// hands back real ids.
  void addItem(int sectionId) {
    final template = state.template;
    if (template == null) return;
    final siblings = state.itemsFor(sectionId);
    final item = QcItem(
      itemId: -(state.items.length + 1),
      sectionId: sectionId,
      templateId: state.templateId,
      label: '',
      orderIndex: siblings.length,
    );
    safeEmit(state.copyWith(items: [...state.items, item], dirty: true));
  }

  void updateItem(int itemId, QcItem item) {
    safeEmit(
      state.copyWith(
        items: [
          for (final i in state.items)
            if (i.itemId == itemId) item else i,
        ],
        dirty: true,
      ),
    );
  }

  /// Retires one item, leaving the rest of the section alone.
  void removeItem(int itemId) {
    safeEmit(
      state.copyWith(
        items: [
          for (final i in state.items)
            if (i.itemId == itemId) i.copyWith(deletedAt: nowIso()) else i,
        ],
        dirty: true,
      ),
    );
  }

  /// Writes template, sections and items in one transaction.
  Future<void> save() async {
    final template = state.template;
    if (template == null) return;
    if (state.isFrozen) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'القالب المنشور غير قابل للتعديل - أنشئ نسخة جديدة',
            'A published template cannot be edited - make a new version',
          ),
        ),
      );
      return;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.saveTemplateTree(
        template,
        state.sections.where((s) => !s.isDeleted).toList(),
        state.items.where((i) => !i.isDeleted).toList(),
      );
      safeEmit(state.copyWith(saving: false, dirty: false));
      await load();
      await library.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> publish({String effectiveDate = ''}) async {
    // A frozen template is not "publishable but already published": issuing it
    // again would bump nothing and leave the reader thinking the revision
    // changed. It goes through `duplicate` instead.
    if (state.isFrozen) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'القالب المنشور لا يُنشر مرة أخرى - أنشئ نسخة جديدة',
            'A published template is not published again - make a new version',
          ),
        ),
      );
      return;
    }
    final blockers = state.blockers;
    if (blockers.isNotEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'لا يمكن النشر قبل معالجة المشكلات',
            'Fix these before publishing',
          ),
        ),
      );
      return;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.publishTemplate(
        state.templateId,
        effectiveDate: effectiveDate,
      );
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t('تم نشر القالب', 'The template was published'),
        ),
      );
      await load();
      await library.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> archive() async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.archiveTemplate(state.templateId);
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t('تمت أرشفة القالب', 'The template was archived'),
        ),
      );
      await load();
      await library.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Opens the next draft version, leaving the issued one untouched.
  Future<int?> duplicate({String newCode = '', String newName = ''}) async {
    final template = state.template;
    if (template == null) return null;
    final name = newName.trim().isEmpty
        ? '${template.name} (${template.version + 1})'
        : newName.trim();
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final id = await repo.duplicateTemplate(
        state.templateId,
        newCode.trim(),
        name,
      );
      safeEmit(state.copyWith(saving: false));
      await library.refresh();
      return id;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
    return null;
  }
}
