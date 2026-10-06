import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_templates_cubit.dart';

/// In-memory stand-in for [QcTemplateRepository].
///
/// It reproduces the two things that shape the cubit: `listTemplates` filters
/// department and publication but *not* type, archived or free text, and
/// `saveTemplateTree` replaces the whole tree in one go. Both are the reason the
/// filters fan out in memory and why a save is one call rather than a sequence.
class _FakeTemplates implements QcTemplateRepository {
  _FakeTemplates(this.templates);

  List<QcTemplate> templates;
  final Map<int, List<QcSection>> sections = {};
  final Map<int, List<QcItem>> items = {};

  final List<QcTemplate> created = [];
  final List<int> deleted = [];
  final List<int> archived = [];
  final List<({int templateId, String effectiveDate})> published = [];
  final List<({int templateId, String code, String name})> duplicated = [];

  /// Counts every `saveTemplateTree`, so a test can prove the cubit never
  /// half-writes a checklist.
  int saveCalls = 0;
  Object? failWith;

  @override
  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
  }) async {
    if (failWith != null) throw failWith!;
    var rows = templates.where((t) => t.deletedAt.isEmpty).toList();
    if (dept.isNotEmpty) rows = rows.where((t) => t.dept == dept).toList();
    if (publishedOnly) {
      rows = rows.where((t) => t.isPublished && !t.isArchived).toList();
    }
    return rows;
  }

  @override
  Future<QcTemplate?> getTemplate(int templateId) async =>
      templates.where((t) => t.templateId == templateId).firstOrNull;

  @override
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId) async {
    if (failWith != null) throw failWith!;
    final template = await getTemplate(templateId);
    if (template == null) return null;
    return (
      template: template,
      sections: sections[templateId] ?? const [],
      items: items[templateId] ?? const [],
    );
  }

  /// Copies a template the way the repository does on write: same fields, new
  /// identity. [QcTemplate] deliberately has no `copyWith` - its flags mean
  /// different things depending on why you are changing one, so each writer
  /// states the copy it means instead.
  QcTemplate _write(int templateId, {bool? published, bool? archived}) {
    final source = templates.firstWhere((t) => t.templateId == templateId);
    return QcTemplate(
      templateId: templateId,
      name: source.name,
      code: source.code,
      type: source.type,
      dept: source.dept,
      description: source.description,
      version: source.version,
      isPublished: published ?? source.isPublished,
      isArchived: archived ?? source.isArchived,
      publishedBy: published == true ? 'qa.manager' : source.publishedBy,
      publishedAt: published == true
          ? '2026-02-01T00:00:00Z'
          : source.publishedAt,

      effectiveDate: source.effectiveDate,
      createdAt: source.createdAt,
      updatedAt: '2026-02-01T00:00:00Z',
      deletedAt: source.deletedAt,
    );
  }

  @override
  Future<int> createTemplate(QcTemplate template) async {
    if (failWith != null) throw failWith!;
    created.add(template);
    final id = 100 + created.length;
    templates = [...templates, _withId(template, id)];
    return id;
  }

  /// `QcTemplate` has no `copyWith`, so a new id is stamped by rebuilding.
  static QcTemplate _withId(QcTemplate source, int id) => QcTemplate(
    templateId: id,
    name: source.name,
    code: source.code,
    type: source.type,
    dept: source.dept,
    description: source.description,
    version: source.version,
    createdAt: source.createdAt,
    updatedAt: source.updatedAt,
  );

  @override
  Future<void> saveTemplateTree(
    QcTemplate template,
    List<QcSection> newSections,
    List<QcItem> newItems,
  ) async {
    if (failWith != null) throw failWith!;
    saveCalls++;
    // The real repository assigns ids on the way in; mirroring it is what makes
    // "the tree reloads clean after a save" a meaningful assertion.
    sections[template.templateId ?? 0] = [
      for (var i = 0; i < newSections.length; i++)
        newSections[i].copyWith(sectionId: 900 + i),
    ];
    items[template.templateId ?? 0] = [
      for (var i = 0; i < newItems.length; i++)
        newItems[i].copyWith(itemId: 950 + i),
    ];
    final i = templates.indexWhere((t) => t.templateId == template.templateId);
    if (i >= 0) templates[i] = _write(template.templateId ?? 0);
  }

  @override
  Future<void> deleteTemplate(int templateId) async {
    deleted.add(templateId);
    final i = templates.indexWhere((t) => t.templateId == templateId);
    if (i >= 0) templates.removeAt(i);
  }

  @override
  Future<void> publishTemplate(
    int templateId, {
    String publishedBy = '',
    String effectiveDate = '',
  }) async {
    if (failWith != null) throw failWith!;
    published.add((templateId: templateId, effectiveDate: effectiveDate));
    final i = templates.indexWhere((t) => t.templateId == templateId);
    if (i >= 0) templates[i] = _write(templateId, published: true);
  }

  @override
  Future<void> archiveTemplate(int templateId) async {
    if (failWith != null) throw failWith!;
    archived.add(templateId);
    final i = templates.indexWhere((t) => t.templateId == templateId);
    if (i >= 0) templates[i] = _write(templateId, archived: true);
  }

  @override
  Future<int> duplicateTemplate(
    int templateId,
    String newCode,
    String newName,
  ) async {
    if (failWith != null) throw failWith!;
    duplicated.add((templateId: templateId, code: newCode, name: newName));
    final source = templates.firstWhere((t) => t.templateId == templateId);
    final id = 200 + duplicated.length;
    // A duplicate is a *draft* copy: copying the published flag would freeze a
    // version nobody has reviewed. The repository does this through
    // `asDraftVersion`, which is what this mirrors.
    templates = [
      ...templates,
      QcTemplate(
        templateId: id,
        name: newName,
        code: newCode,
        type: source.type,
        dept: source.dept,
        description: source.description,
        version: source.version + 1,
        createdAt: source.createdAt,
        updatedAt: source.updatedAt,
      ),
    ];
    sections[id] = sections[templateId] ?? const [];
    items[id] = items[templateId] ?? const [];
    return id;
  }
}

QcTemplate _template({
  int? id = 1,
  String code = 'CHK-001',
  String name = 'Incoming inspection',
  String type = QcTemplateType.incoming,
  String dept = 'Quality',
  bool published = false,
  bool archived = false,
  String effectiveDate = '',
  String expiryDate = '',
}) => QcTemplate(
  templateId: id,
  code: code,
  name: name,
  type: type,
  dept: dept,
  description: 'Receiving checks',
  version: 1,
  isPublished: published,
  isArchived: archived,
  effectiveDate: effectiveDate,
  expiryDate: expiryDate,
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);

QcSection _section({
  int id = 900,
  int templateId = 1,
  String title = 'Packaging',
}) => QcSection(
  sectionId: id,
  templateId: templateId,
  title: title,
  orderIndex: 0,
);

QcItem _item({
  int id = 950,
  int sectionId = 900,
  int templateId = 1,
  String label = 'Cartons intact',
  String itemType = QcItemType.passFail,
  List<String> options = const [],
}) => QcItem(
  itemId: id,
  sectionId: sectionId,
  templateId: templateId,
  label: label,
  itemType: itemType,
  orderIndex: 0,
  optionsJson: options.join(', '),
);

void main() {
  group('QcTemplatesCubit', () {
    late _FakeTemplates repo;

    setUp(() => repo = _FakeTemplates([_template()]));

    test('loads the library and summarises it', () async {
      repo.templates = [
        _template(),
        _template(
          id: 2,
          code: 'CHK-002',
          published: true,
          effectiveDate: '2026-01-01',
        ),
        _template(id: 3, code: 'CHK-003', type: QcTemplateType.inProcess),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.templates.length, 3);
      expect(cubit.state.summary.total, 3);
      expect(cubit.state.summary.published, 1);
      expect(cubit.state.summary.drafts, 2);
      expect(cubit.state.summary.available, 1);
    });

    test('archived templates stay hidden until they are asked for', () async {
      repo.templates = [
        _template(),
        _template(id: 2, code: 'CHK-002', published: true, archived: true),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.templates.length, 1);

      await cubit.applyFilters(const QcTemplateFilters(includeArchived: true));
      expect(cubit.state.templates.length, 2);
    });

    test(
      'type filter is applied in memory because the query cannot do it',
      () async {
        repo.templates = [
          _template(),
          _template(id: 2, code: 'CHK-002', type: QcTemplateType.inProcess),
        ];
        final cubit = QcTemplatesCubit(repo: repo);
        await cubit.load();

        await cubit.toggleType(QcTemplateType.inProcess);
        expect(cubit.state.templates.map((t) => t.code), ['CHK-002']);
      },
    );

    test('toggling the same type twice clears the filter', () async {
      repo.templates = [
        _template(),
        _template(id: 2, code: 'CHK-002', type: QcTemplateType.inProcess),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      await cubit.toggleType(QcTemplateType.inProcess);
      await cubit.toggleType(QcTemplateType.inProcess);
      expect(cubit.state.templates.length, 2);
      expect(cubit.state.filters.types, isEmpty);
    });

    test('free text searches name and code', () async {
      repo.templates = [
        _template(),
        _template(id: 2, code: 'CHK-002', name: 'Final release'),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      await cubit.applyFilters(const QcTemplateFilters(text: 'release'));
      expect(cubit.state.templates.single.code, 'CHK-002');

      await cubit.applyFilters(const QcTemplateFilters(text: 'chk-002'));
      expect(cubit.state.templates.single.code, 'CHK-002');
    });

    test('published-only is the "what can I inspect today" view', () async {
      repo.templates = [
        _template(),
        _template(
          id: 2,
          code: 'CHK-002',
          published: true,
          effectiveDate: '2026-01-01',
        ),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      await cubit.applyFilters(const QcTemplateFilters(publishedOnly: true));
      expect(cubit.state.templates.single.code, 'CHK-002');
    });

    test('clearFilters restores the unfiltered library', () async {
      repo.templates = [
        _template(),
        _template(id: 2, code: 'CHK-002', type: QcTemplateType.inProcess),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      await cubit.toggleType(QcTemplateType.inProcess);
      expect(cubit.state.templates.length, 1);

      await cubit.clearFilters();
      expect(cubit.state.templates.length, 2);
      expect(cubit.state.filters.isEmpty, isTrue);
    });

    test('create returns the new id and reloads the library', () async {
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      final id = await cubit.createTemplate(
        _template(id: null, code: 'CHK-100', name: 'New checklist'),
      );

      expect(id, 101);
      expect(repo.created.single.code, 'CHK-100');
      expect(cubit.state.templates.length, 2);
      expect(cubit.state.saving, isFalse);
    });

    test('a failed create reports the error and returns nothing', () async {
      repo.failWith = const AppError('Permission denied');
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      final id = await cubit.createTemplate(_template(id: null));

      expect(id, isNull);
      expect(cubit.state.error, 'Permission denied');
      expect(cubit.state.saving, isFalse);
    });

    test('archive and delete go through the repository', () async {
      repo.templates = [_template(), _template(id: 2, code: 'CHK-002')];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      await cubit.archiveTemplate(2);
      expect(repo.archived, [2]);
      expect(cubit.state.templates.length, 1);

      await cubit.deleteTemplate(1);
      expect(repo.deleted, [1]);
      expect(cubit.state.templates, isEmpty);
    });

    test('duplicating produces a draft, not another issued copy', () async {
      repo.templates = [
        _template(published: true, effectiveDate: '2026-01-01'),
      ];
      final cubit = QcTemplatesCubit(repo: repo);
      await cubit.load();

      final id = await cubit.duplicateTemplate(1, 'CHK-001-V2', 'Incoming v2');

      expect(id, 201);
      final copy = cubit.state.templates.firstWhere((t) => t.templateId == id);
      expect(copy.isPublished, isFalse);
      expect(copy.version, 2);
      expect(repo.duplicated.single.code, 'CHK-001-V2');
    });

    test(
      'duplicating without a name is refused before the repository',
      () async {
        final cubit = QcTemplatesCubit(repo: repo);
        await cubit.load();

        final id = await cubit.duplicateTemplate(1, 'CHK-001-V2', '   ');

        expect(id, isNull);
        expect(repo.duplicated, isEmpty);
        expect(cubit.state.error, isNotNull);
      },
    );
  });

  group('QcTemplateDetailCubit', () {
    late _FakeTemplates repo;
    late QcTemplatesCubit library;

    /// Seeds a valid one-section tree unless the test already staged its own -
    /// otherwise a test setting up "a section with no items" would be silently
    /// handed a valid tree back and pass for the wrong reason.
    Future<QcTemplateDetailCubit> detail({int id = 1}) async {
      repo.sections.putIfAbsent(id, () => [_section(templateId: id)]);
      repo.items.putIfAbsent(id, () => [_item(templateId: id)]);
      final cubit = QcTemplateDetailCubit(
        repo: repo,
        library: library,
        templateId: id,
      );
      await cubit.load();
      return cubit;
    }

    setUp(() async {
      repo = _FakeTemplates([_template(), _template(id: 2, code: 'CHK-002')]);
      library = QcTemplatesCubit(repo: repo);
      await library.load();
    });

    test('loads the tree', () async {
      final cubit = await detail();
      expect(cubit.state.template?.code, 'CHK-001');
      expect(cubit.state.sections.single.title, 'Packaging');
      expect(cubit.state.items.single.label, 'Cartons intact');
      expect(cubit.state.dirty, isFalse);
    });

    test(
      'a missing template says so rather than showing an empty tree',
      () async {
        final cubit = QcTemplateDetailCubit(
          repo: repo,
          library: library,
          templateId: 999,
        );
        await cubit.load();
        expect(cubit.state.template, isNull);
        expect(cubit.state.error, isNotNull);
      },
    );

    test('adding a section and an item marks the tree dirty', () async {
      final cubit = await detail();
      cubit.addSection('Labelling');
      expect(cubit.state.sections.length, 2);
      expect(cubit.state.dirty, isTrue);

      final newSection = cubit.state.sections.last;
      cubit.addItem(newSection.sectionId ?? 0);
      expect(cubit.state.items.length, 2);
      expect(cubit.state.dirty, isTrue);
    });

    test('a blank section title is ignored', () async {
      final cubit = await detail();
      cubit.addSection('   ');
      expect(cubit.state.sections.length, 1);
      expect(cubit.state.dirty, isFalse);
    });

    test('removing a section tombstones it and its items', () async {
      final cubit = await detail();
      cubit.removeSection(900);

      expect(cubit.state.sections.single.isDeleted, isTrue);
      expect(cubit.state.items.single.isDeleted, isTrue);
      // A tombstone, not a delete: last quarter's inspection still points here.
      expect(cubit.state.items.length, 1);
      expect(cubit.state.dirty, isTrue);
    });

    test('removing an item leaves the rest of the section alone', () async {
      final cubit = await detail();
      repo.items[1] = [_item(), _item(id: 951, label: 'Labels legible')];
      await cubit.load();

      cubit.removeItem(951);
      expect(cubit.state.items.length, 2);
      expect(cubit.state.itemsFor(900).single.label, 'Cartons intact');
    });

    test('removing a section that is not there reports it', () async {
      final cubit = await detail();
      cubit.removeSection(4242);
      expect(cubit.state.error, isNotNull);
      expect(cubit.state.dirty, isFalse);
    });

    test('save writes the whole tree once and comes back clean', () async {
      final cubit = await detail();
      cubit.addSection('Labelling');

      await cubit.save();

      expect(repo.saveCalls, 1);
      expect(cubit.state.dirty, isFalse);
      expect(cubit.state.error, isNull);
    });

    test('tombstones are not written back as live rows', () async {
      final cubit = await detail();
      cubit.removeSection(900);
      await cubit.save();

      // The save filters deleted rows; the reload then brings back the real tree.
      expect(cubit.state.sections.every((s) => !s.isDeleted), isTrue);
      expect(repo.saveCalls, 1);
    });

    test(
      'a failed save keeps the tree dirty so the work is not lost',
      () async {
        final cubit = await detail();
        cubit.addSection('Labelling');

        repo.failWith = const AppError('Disk full');
        await cubit.save();

        expect(cubit.state.dirty, isTrue);
        expect(cubit.state.saving, isFalse);
        expect(cubit.state.error, 'Disk full');
      },
    );

    test('publish refuses a tree with no items and explains why', () async {
      repo.items[1] = const [];
      final cubit = await detail();

      expect(cubit.state.canPublish, isFalse);
      await cubit.publish();

      expect(repo.published, isEmpty);
      expect(cubit.state.error, isNotNull);
      expect(cubit.state.saving, isFalse);
    });

    test('publish refuses a section with no items', () async {
      repo.sections[1] = [_section(), _section(id: 901, title: 'Labelling')];
      final cubit = await detail();

      expect(cubit.state.canPublish, isFalse);
      expect(cubit.state.blockers.single, contains('Labelling'));
    });

    test('publish refuses an unlabelled item', () async {
      repo.items[1] = [_item(label: '   ')];
      final cubit = await detail();

      expect(cubit.state.canPublish, isFalse);
      await cubit.publish();
      expect(repo.published, isEmpty);
    });

    test('a list item with no options is a blocker', () async {
      repo.items[1] = [_item(itemType: QcItemType.dropdown, options: const [])];
      final cubit = await detail();

      expect(cubit.state.blockers, isNotEmpty);
      expect(cubit.state.canPublish, isFalse);
    });

    test('a valid draft publishes and refreshes the library', () async {
      final cubit = await detail();
      expect(cubit.state.canPublish, isTrue);

      await cubit.publish(effectiveDate: '2026-03-01');

      expect(repo.published.single.templateId, 1);
      expect(repo.published.single.effectiveDate, '2026-03-01');
      expect(cubit.state.notice, isNotNull);
      expect(cubit.state.template?.isPublished, isTrue);
      // The library behind the editor now agrees with it.
      expect(library.state.templates.first.isPublished, isTrue);
    });

    test('a published template is frozen: no save, no publish', () async {
      repo.templates = [
        _template(published: true, effectiveDate: '2026-01-01'),
      ];
      final cubit = await detail();

      expect(cubit.state.isFrozen, isTrue);
      expect(cubit.state.canPublish, isFalse);

      await cubit.save();
      expect(repo.saveCalls, 0);
      expect(cubit.state.error, isNotNull);

      await cubit.publish();
      expect(repo.published, isEmpty);
    });

    test('archive retires the template and refreshes the library', () async {
      final cubit = await detail();
      await cubit.archive();

      expect(repo.archived, [1]);
      expect(cubit.state.notice, isNotNull);
      expect(library.state.templates.any((t) => t.templateId == 1), isFalse);
    });

    test('duplicating a published template leaves it frozen here', () async {
      repo.templates = [
        _template(published: true, effectiveDate: '2026-01-01'),
      ];
      repo.sections[1] = [_section()];
      repo.items[1] = [_item()];
      final cubit = QcTemplateDetailCubit(
        repo: repo,
        library: library,
        templateId: 1,
      );
      await cubit.load();

      final newId = await cubit.duplicate();

      expect(newId, 201);
      expect(cubit.state.isFrozen, isTrue);
      final copy = library.state.templates.firstWhere(
        (t) => t.templateId == newId,
      );
      expect(copy.isPublished, isFalse);
    });
  });
}
