import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../assistant/answer.dart';
import '../assistant/assistant_service.dart';
import '../assistant/collect_action.dart';
import '../assistant/voice_service.dart';
import '../data/account_repository.dart';
import '../data/collection_repository.dart';
import '../data/database.dart';
import '../models/rd_account.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'portfolio_screen.dart';

/// One line in the chat transcript.
class _Msg {
  _Msg.user(this.text)
      : isUser = true,
        answer = null;
  _Msg.reply(this.answer)
      : isUser = false,
        text = '';
  final bool isUser;
  final String text;
  final AssistantAnswer? answer;
}

/// The AI assistant chat screen. Ask about customers / accounts / dues in
/// English or Hindi; answers come from the offline intent engine first, then
/// the Groq free-tier text-to-SQL fallback. No customer data leaves the device.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.repo, this.collections});

  /// When provided, answer rows become tappable and open the account.
  final AccountRepository? repo;

  /// When provided too, the assistant can RECORD a collection — always as a
  /// card he confirms, never on its own. Without it the screen is read-only,
  /// which is what the web preview gets.
  final CollectionRepository? collections;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  late final AssistantService _svc = AssistantService(
    AppDatabase.instance,
    actions: (widget.repo != null && widget.collections != null)
        ? CollectActions(
            accounts: widget.repo!, collections: widget.collections!)
        : null,
  );
  final _voice = VoiceService();
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  bool _busy = false;
  bool _listening = false;
  bool _speak = true; // read answers aloud
  String _micLang = 'en_IN'; // mic dictation language (toggle EN / हि)

  static const _historyKey = 'assistant_chat_v1';

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) _voice.initTts();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final restored = <_Msg>[];
      for (final j in list) {
        if (j.containsKey('u')) {
          restored.add(_Msg.user(j['u'] as String));
        } else if (j['a'] != null) {
          restored.add(_Msg.reply(
              AssistantAnswer.fromJson((j['a'] as Map).cast<String, Object?>())));
        }
      }
      if (!mounted || restored.isEmpty) return;
      setState(() => _messages
        ..clear()
        ..addAll(restored));
      _scrollToEnd();
    } catch (_) {/* corrupt history — start fresh */}
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep only the last 40 turns so storage stays small.
      final tail =
          _messages.length > 40 ? _messages.sublist(_messages.length - 40) : _messages;
      final data = tail
          .map((m) => m.isUser ? {'u': m.text} : {'a': m.answer!.toJson()})
          .toList();
      await prefs.setString(_historyKey, jsonEncode(data));
    } catch (_) {/* best effort */}
  }

  Future<void> _clearHistory() async {
    setState(_messages.clear);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (_) {}
  }

  static const _chips = <String>[
    'Aaj kitna collect hua',
    'Aaj kisse paisa liya',
    'Aaj ke defaulters',
    'Is mahine pending',
    'Kaunsi list submit nahi hui',
    'Kitne total accounts',
    'About to freeze',
  ];

  @override
  void dispose() {
    _voice.stop();
    _voice.shutUp();
    _svc.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    if (kIsWeb) return;
    if (_listening) {
      await _voice.stop();
      setState(() => _listening = false);
      return;
    }
    await _voice.shutUp();
    final ok = await _voice.listen(
      localeId: _micLang, // dictate in the chosen language, not always Hindi
      onResult: (text) => setState(() => _controller.text = text),
      onFinal: (text) {
        setState(() => _listening = false);
        if (text.trim().isNotEmpty) _ask(text);
      },
    );
    if (!mounted) return;
    setState(() => _listening = ok);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Mic uplabdh nahi hai (permission check karein)')));
    }
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _messages.add(_Msg.user(q));
      _busy = true;
      _controller.clear();
    });
    _saveHistory();
    _scrollToEnd();

    AssistantAnswer answer;
    if (kIsWeb) {
      answer = AssistantAnswer(
        label: 'Assistant',
        kind: AnswerKind.none,
        rows: const [],
        source: 'local',
        error: 'Assistant needs the on-device database — run on Android.',
      );
    } else {
      answer = await _svc.ask(q);
    }

    if (!mounted) return;
    setState(() {
      _messages.add(_Msg.reply(answer));
      _busy = false;
    });
    _saveHistory();
    _scrollToEnd();
    if (_speak && !kIsWeb) _voice.speak(answer.speakText());
  }

  /// Swap a message for its outcome, if it is still the one that was tapped.
  ///
  /// Clearing the chat mid-await would otherwise leave the index pointing past
  /// the end of the list — a crash on the screen that just took his money.
  void _replace(int index, AssistantAnswer was, AssistantAnswer now) {
    if (index >= _messages.length || _messages[index].answer != was) return;
    setState(() => _messages[index] = _Msg.reply(now));
    _saveHistory();
  }

  /// He tapped Confirm on a proposed action. The proposal is replaced by the
  /// result, so the card can never be tapped twice and write the money twice.
  Future<void> _confirm(int index, AssistantAnswer proposal) async {
    final action = proposal.action;
    if (_busy || action == null) return;
    setState(() => _busy = true);
    final result = await _svc.confirm(action);
    if (!mounted) return;
    setState(() => _busy = false);
    _replace(index, proposal, result);
    if (_speak && !kIsWeb) _voice.speak(result.speakText());
  }

  /// He tapped No — the proposal becomes a plain line of transcript.
  void _cancel(int index, AssistantAnswer proposal) => _replace(
        index,
        proposal,
        AssistantAnswer.text('Cancelled — nothing recorded.', source: 'local'),
      );

  /// Take back a write, from the message that made it.
  Future<void> _undo(int index, AssistantAnswer done, int entryId) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await _svc.undo(entryId);
    if (!mounted) return;
    setState(() => _busy = false);
    _replace(index, done, result);
  }

  /// Open one account from an answer row — makes lists/details actionable
  /// instead of dead ends.
  void _openAccount(String? accountNumber) {
    final acc = accountNumber?.trim() ?? '';
    if (acc.isEmpty || widget.repo == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PortfolioScreen(repo: widget.repo!, accountNumber: acc),
    ));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: Column(
            children: [
              _header(),
              Expanded(
                child: _messages.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                        itemCount: _messages.length + (_busy ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == _messages.length) return _thinking();
                          return _bubble(_messages[i], i);
                        },
                      ),
              ),
              _inputBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2E3A8C), Color(0xFF6D3BD6)],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Assistant', style: AppTheme.display(19)),
                  Text('Accounts, dues aur customers ke sawaal',
                      style: AppTheme.body(12, color: AppTheme.inkMuted)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(_speak
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded),
              tooltip: 'Awaaz',
              onPressed: () {
                if (_speak) _voice.shutUp();
                setState(() => _speak = !_speak);
              },
            ),
            if (_messages.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Chat clear karein',
                onPressed: _clearHistory,
              ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      );

  Widget _emptyState() => ListView(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 16),
        children: [
          Icon(Icons.forum_rounded,
              size: 44, color: AppTheme.inkFaint.withValues(alpha: 0.7)),
          const SizedBox(height: 14),
          Center(
            child: Text('Kuch bhi poochhein',
                style: AppTheme.display(18, color: AppTheme.ink)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'Jaise "aaj kitna collect hua" ya "Ramesh ka account".\n'
              'Paisa mile to bol dein — "Ramesh se 500 le liya".',
              textAlign: TextAlign.center,
              style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
            ),
          ),
          const SizedBox(height: 22),
          _chipWrap(),
        ],
      );

  Widget _chipWrap() => Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: _chips
            .map((c) => GestureDetector(
                  onTap: () => _ask(c),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: AppTheme.card(radius: 20),
                    child: Text(c,
                        style: AppTheme.body(13, weight: FontWeight.w600)),
                  ),
                ))
            .toList(),
      );

  Widget _bubble(_Msg m, int index) {
    if (m.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: const BoxDecoration(
            color: AppTheme.black,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(m.text,
              style: AppTheme.body(14, color: Colors.white, height: 1.3)),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: _answerCard(m.answer!, index),
    );
  }

  Widget _answerCard(AssistantAnswer a, int index) {
    final action = a.action;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.card(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.isError ? 'Assistant' : a.label,
              style: AppTheme.display(15)),
          const SizedBox(height: 8),
          if (a.isError)
            Text(a.error!,
                style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.35))
          else if (action != null)
            _actionBody(action, a, index)
          else ...[
            _answerBody(a),
            if (a.undoEntryId case final id?) _undoRow(index, a, id),
          ],
        ],
      ),
    );
  }

  /// A proposed write, and the two taps that resolve it.
  ///
  /// The money and the customer are stated in full before either button, so
  /// confirming is a decision rather than a reflex — this is the only place in
  /// the app where a machine picked who gets credited.
  Widget _actionBody(CollectAction action, AssistantAnswer proposal, int index) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(action.title,
            style: AppTheme.body(15, weight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 4),
        Text(action.detail,
            style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _confirm(index, proposal),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: action.isUndo ? AppTheme.red : AppTheme.green,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(action.isUndo ? 'Undo it' : 'Yes, record it',
                      style: AppTheme.body(14.5,
                          weight: FontWeight.w800, color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _cancel(index, proposal),
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.line),
                ),
                child: Text('No',
                    style: AppTheme.body(14.5, weight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// An undo that stays put. A snackbar is gone in 1.4 seconds; a conversation
  /// he scrolls back through should still be able to take the entry away.
  Widget _undoRow(int index, AssistantAnswer done, int entryId) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GestureDetector(
        onTap: () => _undo(index, done, entryId),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.undo_rounded, size: 17, color: AppTheme.red),
            const SizedBox(width: 6),
            Text('Undo this entry',
                style: AppTheme.body(13,
                    weight: FontWeight.w700, color: AppTheme.red)),
          ],
        ),
      ),
    );
  }

  Widget _answerBody(AssistantAnswer a) {
    switch (a.kind) {
      case AnswerKind.count:
        return _bigNumber('${a.scalar.toInt()}', 'accounts');
      case AnswerKind.sum:
        return _bigNumber(inr(a.scalar), 'total');
      case AnswerKind.list:
        if (a.isEmpty) {
          return Text('Kuch nahi mila.',
              style: AppTheme.body(13.5, color: AppTheme.inkMuted));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${a.rows.length} results',
                style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
            const SizedBox(height: 8),
            ...a.rows.take(50).map(_resultTile),
            if (a.rows.length > 50)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('+ ${a.rows.length - 50} more',
                    style: AppTheme.body(12, color: AppTheme.inkFaint)),
              ),
          ],
        );
      case AnswerKind.detail:
        if (a.isEmpty) {
          return Text('Kuch nahi mila.',
              style: AppTheme.body(13.5, color: AppTheme.inkMuted));
        }
        return _customerCard(a.rows.first);
      case AnswerKind.none:
        return Text(a.speakText(),
            style: AppTheme.body(13.5, color: AppTheme.inkMuted));
    }
  }

  /// One customer's full profile. Rebuilds an [RdAccount] from the row so the
  /// derived figures (opening date, total deposited, maturity) are identical to
  /// the Accounts screen.
  Widget _customerCard(Map<String, Object?> row) {
    final RdAccount a;
    try {
      a = RdAccount.fromMap(row);
    } catch (_) {
      return Text('Details padh nahi paaya.',
          style: AppTheme.body(13.5, color: AppTheme.inkMuted));
    }
    final behind = (row['months_behind'] as num?)?.toInt() ?? 0;
    final (chipBg, chipFg, chipText) = behind >= 1
        ? (AppTheme.redSoft, AppTheme.red, '$behind month${behind > 1 ? 's' : ''} behind')
        : behind == 0
            ? (AppTheme.amberSoft, AppTheme.amber, 'Due this month')
            : (AppTheme.greenSoft, AppTheme.green, 'Paid ahead');

    final tappable = widget.repo != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a.customerName,
            style: AppTheme.display(17.5, weight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text('#${a.accountNumber}',
            style: AppTheme.body(12.5, color: AppTheme.inkFaint)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: AppTheme.panel(chipBg, radius: 8),
          child: Text(chipText,
              style: AppTheme.body(12,
                  weight: FontWeight.w700, color: chipFg)),
        ),
        const SizedBox(height: 12),
        _kv('Monthly RD', inr(a.denominationAmount)),
        _kv('Installments paid', '${a.monthsPaid}'),
        _kv('Total deposited', inr(a.depositedAmount)),
        _kv('Next due', a.dueDateLabel),
        _kv('Opened on', a.openingDateLabel),
        _kv('Maturity value', inr(a.maturityAmount)),
        _kv('Term', '${a.termYears} years'),
        _kv('Left to maturity', '${a.installmentsToMaturity} inst'),
        if (tappable) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _openAccount(a.accountNumber),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('Open account',
                  style: AppTheme.body(14,
                      weight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3.5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: AppTheme.body(13.5, color: AppTheme.inkMuted)),
            Text(v, style: AppTheme.body(14.5, weight: FontWeight.w700)),
          ],
        ),
      );

  Widget _bigNumber(String value, String unit) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(value, style: AppTheme.display(30, weight: FontWeight.w800)),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(unit, style: AppTheme.body(13, color: AppTheme.inkMuted)),
          ),
        ],
      );

  /// One row of a list answer.
  ///
  /// The same tile now serves three views, so it reads whichever columns are
  /// actually present instead of assuming an account row — a collection row
  /// has an `amount` and a time but no denomination, and a list row has no
  /// customer at all. Falling back on a missing column used to render every
  /// collection as "₹0".
  Widget _resultTile(Map<String, Object?> r) {
    final acc = (r['account_number'] as String?) ?? '';
    final den = (r['denomination_amount'] as num?)?.toInt() ?? 0;
    final amount = (r['amount'] as num?)?.toInt();
    final at = (r['collected_time'] as String?) ?? '';
    final due = (r['next_due'] as String?) ?? '';
    final bucket = (r['bucket'] as String?) ?? '';

    // A saved list, which has an id and a mode where a customer would be.
    if (r['item_count'] != null) return _lotTile(r);

    final name = (r['customer_name'] as String?) ?? '—';
    final (bg, fg) = _bucketColors(bucket);
    final tappable = widget.repo != null && acc.isNotEmpty;
    // Money taken beats money owed: when a row carries both, it came from the
    // ledger and the figure that matters is what he actually collected.
    final headline = amount ?? den;
    final subtitle = amount != null
        ? '#$acc${at.isEmpty ? '' : ' · $at'}'
        : '#$acc · ${inr(den)}${due.isEmpty ? '' : ' · due $due'}';
    return GestureDetector(
      onTap: tappable ? () => _openAccount(acc) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(14.5, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
                ],
              ),
            ),
            if (amount != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(inr(headline),
                    style: AppTheme.body(14, weight: FontWeight.w800)),
              ),
            if (bucket.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: AppTheme.panel(bg, radius: 8),
                child: Text(bucket,
                    style:
                        AppTheme.body(10.5, weight: FontWeight.w700, color: fg)),
              ),
            if (tappable)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.chevron_right_rounded,
                    size: 20, color: AppTheme.inkFaint),
              ),
          ],
        ),
      ),
    );
  }

  /// A saved list. No customer, so it leads with the money and says plainly
  /// whether it has actually reached the portal — a draft and a submitted list
  /// look identical otherwise, and only one of them is a receipt.
  Widget _lotTile(Map<String, Object?> r) {
    final total = (r['total_amount'] as num?)?.toInt() ?? 0;
    final count = (r['item_count'] as num?)?.toInt() ?? 0;
    final mode = (r['mode'] as String?) ?? '';
    final ref = (r['reference_number'] as String?) ?? '';
    final on = (r['created_on'] as String?) ?? '';
    final submitted = ref.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${inr(total)} · $count accounts',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(14.5, weight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('$mode${on.isEmpty ? '' : ' · $on'}'
                    '${submitted ? ' · $ref' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: AppTheme.panel(
                submitted ? AppTheme.greenSoft : AppTheme.amberSoft,
                radius: 8),
            child: Text(submitted ? 'submitted' : 'draft',
                style: AppTheme.body(10.5,
                    weight: FontWeight.w700,
                    color: submitted ? AppTheme.green : AppTheme.amber)),
          ),
        ],
      ),
    );
  }

  (Color, Color) _bucketColors(String bucket) {
    switch (bucket) {
      case 'defaulter':
        return (AppTheme.redSoft, AppTheme.red);
      case 'pending':
        return (AppTheme.amberSoft, AppTheme.amber);
      case 'deposited':
        return (AppTheme.greenSoft, AppTheme.green);
      default:
        return (AppTheme.surfaceSoft, AppTheme.inkMuted);
    }
  }

  Widget _thinking() => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: AppTheme.card(radius: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.inkMuted)),
              const SizedBox(width: 10),
              Text('Soch raha hoon…',
                  style: AppTheme.body(13, color: AppTheme.inkMuted)),
            ],
          ),
        ),
      );

  Widget _inputBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          14, 8, 14, MediaQuery.of(context).padding.bottom + 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Type row — full-width field with an inline send button.
          Container(
            decoration: AppTheme.card(radius: 26),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _ask,
                    style: AppTheme.body(15),
                    decoration: InputDecoration(
                      hintText: 'Sawaal likhein…',
                      hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _busy ? null : () => _ask(_controller.text),
                  child: Container(
                    margin: const EdgeInsets.all(5),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _busy ? AppTheme.inkFaint : AppTheme.black,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.arrow_upward_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
              ],
            ),
          ),
          // Voice is his best input method — make it the primary, labelled,
          // full-width control, with the dictation language beside it.
          if (!kIsWeb) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _micButton()),
                const SizedBox(width: 8),
                _langToggle(),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _micButton() {
    return GestureDetector(
      onTap: _busy ? null : _toggleMic,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _listening ? AppTheme.red : AppTheme.black,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(_listening ? 'Sun raha hoon… (roken)' : 'Bolkar poochhein',
                style: AppTheme.body(15,
                    weight: FontWeight.w700, color: Colors.white)),
          ],
        ),
      ),
    );
  }

  /// Dictation language — labelled so it's clear this sets what the MIC hears,
  /// not the answer language.
  Widget _langToggle() {
    final hi = _micLang == 'hi_IN';
    return GestureDetector(
      onTap: () => setState(() => _micLang = hi ? 'en_IN' : 'hi_IN'),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AppTheme.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('बोली',
                style: AppTheme.body(9.5,
                    weight: FontWeight.w600, color: AppTheme.inkMuted)),
            Text(hi ? 'हिंदी' : 'English',
                style: AppTheme.body(13, weight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}
