import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

void main() {
  test(
    'organization name is escaped and appears below the logo in report templates',
    () {
      for (final file in Directory(
        'assets/templates',
      ).listSync().whereType<File>()) {
        if (!file.path.endsWith('.html')) continue;
        final template = file.readAsStringSync();
        if (!template.contains('report_logo_data_uri')) continue;
        final html = tinyJinjaRender(template, {
          'organization_name': 'مؤسسة <اختبار> & شركاؤها',
          'report_logo_data_uri': 'data:image/png;base64,test',
        });
        expect(
          html,
          contains('مؤسسة &lt;اختبار&gt; &amp; شركاؤها'),
          reason: file.path,
        );
        expect(
          html.indexOf('class="organization-name"'),
          greaterThan(html.indexOf('data:image/png;base64,test')),
          reason: file.path,
        );
        expect(
          html,
          isNot(contains('مؤسسة <اختبار>')),
          reason: 'Organization names are untrusted display text',
        );
      }
    },
  );
}
