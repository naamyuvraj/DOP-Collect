import 'dart:convert';

import '../util/format.dart';

/// `detail` renders one customer's full profile card (all v_accounts columns
/// must be selected so an [RdAccount] can be rebuilt from the row).
enum AnswerKind { list, count, sum, detail, none }

/// The result of one assistant question. Rows are raw `v_accounts` maps; the
/// UI renders them and [speakText] builds a short local summary — no data ever
/// goes back to the cloud.
class AssistantAnswer {
  AssistantAnswer({
    required this.label,
    required this.kind,
    required this.rows,
    required this.source, // 'local' | 'groq' | 'groq-chat'
    this.error,
    this.message,
    this.lang = 'en',
  });
  final String label;
  final AnswerKind kind;
  final List<Map<String, Object?>> rows;
  final String source;
  final String? error;

  /// 'hi' or 'en' — the language the user asked in, so canned lines + voice
  /// match. Free-text (message) answers already come back in the right language
  /// from the model.
  final String lang;

  bool get _hi => lang == 'hi';

  /// Same answer, stamped with the question's language.
  AssistantAnswer withLang(String lang) => AssistantAnswer(
        label: label,
        kind: kind,
        rows: rows,
        source: source,
        error: error,
        message: message,
        lang: lang,
      );

  /// Free-text reply for general (non-account) questions — DOP schemes,
  /// interest rates, procedures. Rendered as prose, not a data card.
  final String? message;

  bool get isError => error != null;
  bool get isEmpty => rows.isEmpty;
  bool get isMessage => message != null && message!.trim().isNotEmpty;

  /// The single scalar for count/sum answers (0 if missing).
  num get scalar {
    if (rows.isEmpty) return 0;
    final v = rows.first.values.isEmpty ? 0 : rows.first.values.first;
    return (v as num?) ?? 0;
  }

  String get _nothing => _hi ? 'कुछ नहीं मिला' : 'Nothing found';

  /// Short line shown as the assistant reply and read aloud by TTS, in the
  /// user's language.
  String speakText() {
    if (isError) return error!;
    if (isMessage) return message!;
    switch (kind) {
      case AnswerKind.count:
        return '$label: ${scalar.toInt()}';
      case AnswerKind.sum:
        return '$label: ${inr(scalar)}';
      case AnswerKind.list:
        if (rows.isEmpty) return '$label — $_nothing';
        final n = rows.length;
        return _hi
            ? '$label — $n ${n == 1 ? "खाता" : "खाते"}'
            : '$label — $n ${n == 1 ? "account" : "accounts"}';
      case AnswerKind.detail:
        if (rows.isEmpty) return '$label — $_nothing';
        final r = rows.first;
        final name = (r['customer_name'] as String?) ?? '';
        final den = (r['denomination_amount'] as num?)?.toInt() ?? 0;
        final behind = (r['months_behind'] as num?)?.toInt() ?? 0;
        final state = _hi
            ? (behind >= 1
                ? '$behind महीने बाकी'
                : behind == 0
                    ? 'इस महीने due'
                    : 'जमा हो चुका')
            : (behind >= 1
                ? '$behind month${behind > 1 ? 's' : ''} behind'
                : behind == 0
                    ? 'due this month'
                    : 'paid ahead');
        return '$name — ${inr(den)}, $state';
      case AnswerKind.none:
        return _hi
            ? 'समझ नहीं आया। नीचे दिए सुझाव आज़माएँ।'
            : "Sorry, I didn't understand. Try a suggestion below.";
    }
  }

  /// A general free-text answer (DOP knowledge, not a data query).
  factory AssistantAnswer.text(String message, {String source = 'groq-chat'}) =>
      AssistantAnswer(
        label: 'Assistant',
        kind: AnswerKind.none,
        rows: const [],
        source: source,
        message: message,
      );

  // --- Persistence (chat history survives closing the assistant) -----------

  Map<String, Object?> toJson() => {
        'label': label,
        'kind': kind.name,
        // Cap stored rows so history stays small.
        'rows': rows.take(50).toList(),
        'source': source,
        'error': error,
        'message': message,
      };

  factory AssistantAnswer.fromJson(Map<String, Object?> j) => AssistantAnswer(
        label: (j['label'] as String?) ?? 'Result',
        kind: AnswerKind.values
            .firstWhere((k) => k.name == j['kind'], orElse: () => AnswerKind.none),
        rows: ((j['rows'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, Object?>())
            .toList(),
        source: (j['source'] as String?) ?? 'local',
        error: j['error'] as String?,
        message: j['message'] as String?,
      );

  String encode() => jsonEncode(toJson());
  static AssistantAnswer decode(String s) =>
      AssistantAnswer.fromJson(jsonDecode(s) as Map<String, Object?>);

  factory AssistantAnswer.notUnderstood({String lang = 'en'}) => AssistantAnswer(
        label: lang == 'hi' ? 'समझ नहीं आया' : 'Not understood',
        kind: AnswerKind.none,
        rows: const [],
        source: 'local',
        lang: lang,
        error: lang == 'hi'
            ? 'समझ नहीं आया — नीचे दिए गए सुझाव आज़माएँ।'
            : "Sorry, I didn't understand — try a suggestion below.",
      );

  factory AssistantAnswer.offline({String lang = 'en'}) => AssistantAnswer(
        label: 'Offline',
        kind: AnswerKind.none,
        rows: const [],
        source: 'local',
        lang: lang,
        error: lang == 'hi'
            ? 'इंटरनेट नहीं है। सुझाए गए सवाल ऑफलाइन चलते हैं।'
            : 'No internet. The suggested questions work offline.',
      );
}
