import 'package:dop_collect/assistant/answer.dart';
import 'package:dop_collect/assistant/lang.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('language detection by script', () {
    expect(langOf('aaj ke defaulters'), 'en');
    expect(langOf('आज के डिफॉल्टर'), 'hi');
    expect(isHindiText('Ramesh ka account'), isFalse);
    expect(isHindiText('रमेश का खाता'), isTrue);
  });

  test('canned lines follow the stamped language', () {
    final en = AssistantAnswer(
        label: 'Defaulters', kind: AnswerKind.list, rows: const [], source: 'local');
    expect(en.speakText(), contains('Nothing found'));

    final hi = en.withLang('hi');
    expect(hi.speakText(), contains('कुछ नहीं मिला'));
  });

  test('not-understood is localized', () {
    expect(AssistantAnswer.notUnderstood(lang: 'en').error, contains("didn't"));
    expect(AssistantAnswer.notUnderstood(lang: 'hi').error, contains('समझ'));
  });

  test('withLang preserves the payload', () {
    final a = AssistantAnswer(
        label: 'X',
        kind: AnswerKind.count,
        rows: const [
          {'n': 5}
        ],
        source: 'local');
    final b = a.withLang('hi');
    expect(b.lang, 'hi');
    expect(b.scalar, 5);
    expect(b.label, 'X');
  });
}
