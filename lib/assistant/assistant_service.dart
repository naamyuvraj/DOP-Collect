import 'dart:async';
import 'dart:convert';

import '../calc/po_calc.dart';
import '../data/database.dart';
import '../services/analytics.dart';
import '../util/format.dart';
import 'answer.dart';
import 'assistant_config.dart';
import 'calc_prompt.dart';
import 'general_prompt.dart';
import 'groq_client.dart';
import 'lang.dart';
import 'intent_engine.dart';
import 'schema_prompt.dart';
import 'sql_guard.dart';

/// Orchestrates the 3-tier answer flow:
///   1. Local intent engine (offline, instant, free) — handles the ~80% common.
///   2. Groq text-to-SQL (schema only leaves device) — the long tail.
///   3. Graceful "not understood / offline" fallback.
class AssistantService {
  AssistantService(this._db, {GroqClient? groq})
      : _groq = groq ?? GroqClient();
  final AppDatabase _db;
  final GroqClient _groq;

  /// Public entry: resolves the answer, then stamps it with the language the
  /// user asked in so the reply text and voice match (Hindi in -> Hindi out).
  Future<AssistantAnswer> ask(String question) async {
    final lang = langOf(question);
    final answer = await _resolve(question.trim(), lang);
    // Privacy: log only how it was answered — never the question text.
    unawaited(Analytics.track('assistant_query', {
      'source': answer.source,
      'kind': answer.kind.name,
      'lang': lang,
      'ok': !answer.isError,
    }));
    return answer.withLang(lang);
  }

  Future<AssistantAnswer> _resolve(String trimmed, String lang) async {
    if (trimmed.isEmpty) return AssistantAnswer.notUnderstood(lang: lang);

    // Tier 0 — an interest CALCULATION never touches the account database.
    // Routed locally (not by asking the model first) because text-to-SQL will
    // happily turn "9 lakh MIS" into a SUM over the agent's own accounts.
    if (AssistantConfig.cloudActive && looksLikeCalculation(trimmed)) {
      final calc = await _calcAnswer(trimmed);
      if (calc != null) return calc;
    }

    // Tier 1 — local, offline, instant.
    final local = IntentEngine.match(trimmed);
    if (local != null) {
      try {
        final rows = await _run(local.sql);
        // A name/number lookup that found nothing probably wasn't a customer at
        // all ("hello", "rd rate") — let the cloud try rather than dead-ending.
        if (!(local.isSearch && rows.isEmpty)) {
          // One hit -> full profile card; several -> a pickable list.
          final kind = local.kind == AnswerKind.detail && rows.length > 1
              ? AnswerKind.list
              : local.kind;
          return AssistantAnswer(
              label: local.label, kind: kind, rows: rows, source: 'local');
        }
      } catch (_) {
        // Local SQL shouldn't fail; if it does, fall through to cloud.
      }
    }

    // Tier 2 — Groq text-to-SQL. Only schema + question leave the device.
    if (AssistantConfig.cloudActive) {
      try {
        final content = await _groq.completeJson(
          system: SchemaPrompt.system,
          user: SchemaPrompt.user(trimmed),
        );
        final obj = jsonDecode(content) as Map<String, dynamic>;
        final sql = (obj['sql'] as String?)?.trim() ?? '';
        final kind = _kind(obj['kind'] as String?);
        final label = (obj['label'] as String?)?.trim() ?? 'Result';
        if (sql.isNotEmpty && kind != AnswerKind.none) {
          final safe = SqlGuard.sanitize(sql, maxRows: AssistantConfig.maxRows);
          final rows = await _run(safe);
          return AssistantAnswer(
              label: label, kind: kind, rows: rows, source: 'groq');
        }
        // Not an account query -> try an interest calculation, else general.
        return await _calcOrGeneral(trimmed, lang);
      } on GroqUnavailable {
        return AssistantAnswer.offline(lang: lang);
      } catch (_) {
        // Bad/failed SQL — try calculation, then a general answer.
        return await _calcOrGeneral(trimmed, lang);
      }
    }

    // Tier 3 — no local match and no cloud keys.
    return AssistantAnswer.notUnderstood(lang: lang);
  }

  // --- Calculation routing -------------------------------------------------

  static final _schemeWord = RegExp(
      r'\b(rd|recurring|td|term deposit|fd|mis|monthly income|scss|senior citizen'
      r'|nsc|kvp|kisan|mssc|mahila|ppf|provident|ssa|ssy|sukanya)\b',
      caseSensitive: false);
  static final _calcWord = RegExp(
      r'(maturity|milega|milenge|milta|kitna|byaj|byaaj|interest|calculate'
      r'|calculator|saal|years?\b|yrs|banega|hoga)',
      caseSensitive: false);
  // Wording that means "about MY customers" — those stay database questions.
  static final _accountWord = RegExp(
      r'(defaulter|pending|deposited|due|collection|customer|account number'
      r'|kitne account|mera total|my accounts|freeze|advance|aaj|is mahine'
      r'|this month|list)',
      caseSensitive: false);
  static final _hasDigit = RegExp(r'\d');

  /// True when the question is a hypothetical scheme calculation rather than a
  /// query over the agent's own accounts. Needs a number, a scheme and a
  /// calculation cue — and must not be phrased about their customers.
  static bool looksLikeCalculation(String question) {
    final q = question.toLowerCase();
    if (!_hasDigit.hasMatch(q)) return false;
    if (!_schemeWord.hasMatch(q)) return false;
    if (!_calcWord.hasMatch(q)) return false;
    return !_accountWord.hasMatch(q);
  }

  /// An interest calculation if the question is one, else general knowledge.
  Future<AssistantAnswer> _calcOrGeneral(String question, String lang) async =>
      await _calcAnswer(question) ?? await _generalAnswer(question, lang);

  /// Interest/maturity questions. The model only extracts the parameters —
  /// [PoCalc] does the arithmetic, so the figure is always exact.
  Future<AssistantAnswer?> _calcAnswer(String question) async {
    try {
      final content = await _groq.completeJson(
        system: CalcPrompt.system,
        user: CalcPrompt.user(question),
      );
      final obj = jsonDecode(content) as Map<String, dynamic>;
      final code = ((obj['scheme'] as String?) ?? '').trim();
      if (code.isEmpty || code.toUpperCase() == 'NONE') return null;
      final spec = PoCalc.byName(code);
      if (spec == null) return null;

      final amount = (obj['amount'] as num?)?.toDouble() ?? 0;
      if (amount <= 0) return null;
      final years = (obj['years'] as num?)?.toDouble();
      final rate = (obj['rate'] as num?)?.toDouble();

      final r = PoCalc.compute(spec.scheme,
          amount: amount, years: years, rate: rate);
      final usedRate = rate ?? spec.rate;
      final usedYears = years ?? spec.years;

      final b = StringBuffer()
        ..writeln('${spec.code} · ${spec.name}')
        ..write(inr(amount.round()));
      switch (spec.mode) {
        case DepositMode.monthly:
          b.write('/month');
        case DepositMode.yearly:
          b.write('/year');
        case DepositMode.lumpSum:
          break;
      }
      if (spec.scheme != PoScheme.kvp) b.write(' for ${_trim(usedYears)} years');
      b.writeln(' at $usedRate%');

      if (r.payout != null) {
        b.writeln('${r.payout}: ${inr((r.interest /
            (spec.scheme == PoScheme.mis ? usedYears * 12 : usedYears * 4))
            .round())}');
        b.writeln('Total income: ${inr(r.interest.round())}');
        b.writeln('Deposit returned at maturity: ${inr(r.maturity.round())}');
      } else {
        b.writeln('Maturity: ${inr(r.maturity.round())}');
        b.writeln('Deposited: ${inr(r.deposited.round())}  ·  '
            'Interest: ${inr(r.interest.round())}');
      }
      for (final row in r.rows) {
        b.writeln('${row.$1}: ${row.$2}');
      }
      return AssistantAnswer.text(b.toString().trim());
    } catch (_) {
      return null;
    }
  }

  String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  /// Tier 3 — general DOP/post-office knowledge (schemes, interest, rules).
  Future<AssistantAnswer> _generalAnswer(String question, String lang) async {
    try {
      final text = await _groq.completeText(
        system: GeneralPrompt.system,
        user: GeneralPrompt.user(question),
      );
      final t = text.trim();
      return t.isEmpty
          ? AssistantAnswer.notUnderstood(lang: lang)
          : AssistantAnswer.text(t);
    } on GroqUnavailable {
      return AssistantAnswer.offline(lang: lang);
    } catch (_) {
      return AssistantAnswer.notUnderstood(lang: lang);
    }
  }

  Future<List<Map<String, Object?>>> _run(String sql) async {
    final db = await _db.database;
    return db.rawQuery(sql); // read-only path
  }

  AnswerKind _kind(String? k) {
    switch (k) {
      case 'count':
        return AnswerKind.count;
      case 'sum':
        return AnswerKind.sum;
      case 'list':
        return AnswerKind.list;
      default:
        return AnswerKind.none;
    }
  }

  void dispose() => _groq.dispose();
}
