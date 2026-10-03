import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../data/collection_repository.dart';
import '../../data/lot_repository.dart';
import '../../models/collection.dart';
import '../../models/collection_round.dart';
import '../../models/lot.dart';
import '../../models/lot_packing.dart';
import '../../models/rd_account.dart';
import '../../models/summaries.dart';
import '../../services/analytics.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/press.dart';
import 'list_builder_screen.dart';

/// Build a month's lists in one pass: choose WHO goes on a list, let the packer
/// work out how they divide into ₹20,000 lots, then read the proposal and file
/// it.
///
/// The manual builder ([ListBuilderScreen]) is the other half of the pair and is
/// unchanged. It exists for the job it has always been good at: one list, picked
/// deliberately, one customer at a time. This screen exists for the other job —
/// eighty accounts at month end that have to become six lists, where the picking
/// is easy and the *arithmetic* is what takes an hour and gets a total wrong.
///
/// The split of responsibility is the whole design, and it is what makes an
/// automatic path safe here when the old auto-build was not:
///
///   * The agent chooses the pool and prices every row. The screen seeds those
///     numbers from [CollectionRound.listInstallments] — the field ledger first,
///     the portal's arrears only where the ledger is silent — and every seed is
///     visible and editable before anything is packed.
///   * The packer only divides. It never adds a customer, never drops one, and
///     never changes an installment count.
///   * Nothing is saved until the proposal has been read on [_ReviewScreen],
///     which shows every list with every row on it. Backing out costs nothing,
///     because no account has been marked spoken-for yet.
///
/// Accounts already sitting on this cycle's lists are not offered at all — see
/// [LotPacking.listedThisCycle]. Re-listing money that is already on an
/// unsubmitted list is the one mistake an automatic path can make at scale.
class AutoListScreen extends StatefulWidget {
  const AutoListScreen({
    super.key,
    required this.accounts,
    required this.lots,
    required this.collections,
  });

  final AccountRepository accounts;
  final LotRepository lots;

  /// The field ledger. The manual builder deliberately does without it; this
  /// screen cannot, because seeding installment counts from what was actually
  /// collected is the correction that makes automatic grouping trustworthy.
  final CollectionRepository collections;

  @override
  State<AutoListScreen> createState() => _AutoListScreenState();
}

/// One offered account: the account, what it seeds to, and why.
class _Candidate {
  _Candidate({required this.account, required this.seed, required this.fromLedger});

  final RdAccount account;

  /// Installments this account starts at. Zero for a part-paid customer — the
  /// ledger has seen him but he has not completed a month, so he is shown and
  /// left unselected rather than listed for money still in his pocket.
  final int seed;

  /// True when the ledger priced this row, false when it fell back to the
  /// portal's arrears. Shown on the row so the agent can tell a figure he
  /// created from a figure the app guessed.
  final bool fromLedger;
}

class _AutoListScreenState extends State<AutoListScreen> {
  final _searchCtrl = TextEditingController();

  List<_Candidate>? _pool; // null while loading
  final Map<String, int> _selected = {}; // accountNumber -> installments
  final Map<String, RdAccount> _byNumber = {};

  String _query = '';
  AccountFilter? _standing;
  String _mode = 'Cash';
  bool get _isCheque => _mode.toLowerCase().contains('cheque');

  /// How many accounts this cycle's existing lists already hold — shown so the
  /// agent understands why a customer he expected is not in the pool.
  int _alreadyListed = 0;

  int get _count => _selected.length;
  int get _total => _selected.entries.fold(
      0, (s, e) => s + (_byNumber[e.key]?.denominationAmount ?? 0) * e.value);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final accounts = await widget.accounts.all();
    final lots = await widget.lots.all();
    final entries =
        await widget.collections.forCycle(Collection.cycleOf(now));

    final listed = LotPacking.listedThisCycle(lots, now);
    final progress = CollectionRound.progressByAccount(accounts, entries);

    final pool = <_Candidate>[];
    var blocked = 0;
    for (final a in accounts) {
      if (a.isClosed) continue; // run its term; nothing left to deposit
      if (listed.contains(a.accountNumber)) {
        blocked++;
        continue;
      }
      final p = progress[a.accountNumber];
      pool.add(_Candidate(
        account: a,
        seed: CollectionRound.listInstallments(a, p, now),
        fromLedger: (p?.collected ?? 0) > 0,
      ));
      _byNumber[a.accountNumber] = a;
    }
    pool.sort((x, y) => LotPacking.priorityCompare(x.account, y.account, now));

    if (!mounted) return;
    setState(() {
      _pool = pool;
      _alreadyListed = blocked;
      // Everything the seed could price starts selected — this is the "select
      // all the accounts they need" half of the job. A zero seed (part-paid)
      // stays out, visibly.
      for (final c in pool) {
        if (c.seed > 0) _selected[c.account.accountNumber] = c.seed;
      }
    });
  }

  // ---------------------------------------------------------------- filtering

  static const _standingFilters = <String, AccountFilter?>{
    'All': null,
    'Super late': AccountFilter.aboutToFreeze,
    'Late': AccountFilter.defaulters,
    'Due now': AccountFilter.toCollect,
    'Advance': AccountFilter.advancedPaid,
  };

  /// The rows currently on screen. Selection is never hidden by a filter or a
  /// search — the same rule the manual builder follows, for the same reason:
  /// something picked and then scrolled out of sight by a filter change is how
  /// a list gets filed with an account nobody meant to include.
  List<_Candidate> get _shown {
    final now = DateTime.now();
    final q = _query.trim().toLowerCase();
    return (_pool ?? const <_Candidate>[]).where((c) {
      if (_selected.containsKey(c.account.accountNumber)) return true;
      if (_standing != null && !_standing!.test(c.account, now)) return false;
      if (q.isEmpty) return true;
      return c.account.customerName.toLowerCase().contains(q) ||
          c.account.accountNumber.contains(q);
    }).toList();
  }

  void _selectAllShown() {
    setState(() {
      for (final c in _shown) {
        if (c.seed > 0) _selected[c.account.accountNumber] = c.seed;
      }
    });
  }

  void _clearAll() => setState(_selected.clear);

  void _setInstallments(RdAccount a, int value) {
    setState(() {
      if (value <= 0) {
        _selected.remove(a.accountNumber);
      } else {
        _selected[a.accountNumber] = value;
      }
    });
  }

  // ------------------------------------------------------------------ packing

  void _group() {
    final now = DateTime.now();
    final items = _selected.entries
        .map((e) => PackItem(
              account: _byNumber[e.key]!,
              installments: e.value,
            ))
        .toList();

    // Cheque lists have no rupee ceiling — only the row count binds — so the
    // cap is dropped rather than set high. Setting it high would still be a
    // ceiling, and a ₹40,000 cheque list is legitimate.
    final result = LotPacking.pack(
      items,
      now,
      amountCap: _isCheque ? null : ListBuilderScreen.lotCap,
      maxAccounts: ListBuilderScreen.maxAccounts,
    );

    unawaited(Analytics.track('lists_auto_grouped', {
      'accounts': result.accountCount,
      'lots': result.lotCount,
      'amount': result.totalAmount,
      'unplaceable': result.unplaceable.length,
      'mode': _mode,
    }));

    Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _ReviewScreen(
        result: result,
        mode: _mode,
        accounts: widget.accounts,
        lots: widget.lots,
      ),
    )).then((made) {
      if (made == true && mounted) Navigator.of(context).pop(true);
    });
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final pool = _pool;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-group lists')),
      body: pool == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _summaryBar(),
                _modeSelector(),
                _searchRow(),
                _filterBar(),
                _bulkBar(),
                Expanded(child: _list()),
              ],
            ),
      floatingActionButton: _count == 0
          ? null
          : FloatingActionButton.extended(
              onPressed: _group,
              icon: const Icon(Icons.auto_awesome_motion, size: 20),
              label: Text('Group $_count into lists'),
            ),
    );
  }

  /// What the agent has picked, and the honest floor on how many lists it will
  /// take. The floor is the arithmetic minimum — both ceilings applied to the
  /// totals — not a promise; the packer can need one more when the amounts do
  /// not divide cleanly. Called "at least" on the label for that reason.
  Widget _summaryBar() {
    final byAmount = _isCheque
        ? 0
        : (_total / ListBuilderScreen.lotCap).ceil();
    final byCount = (_count / ListBuilderScreen.maxAccounts).ceil();
    final floor = byAmount > byCount ? byAmount : byCount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _stat('Selected', '$_count'),
          _stat('Total', inr(_total)),
          _stat('Lists', floor == 0 ? '—' : 'at least $floor'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.body(12, color: AppTheme.inkMuted)),
          const SizedBox(height: 2),
          Text(value, style: AppTheme.display(17, weight: FontWeight.w600)),
        ],
      );

  Widget _modeSelector() {
    Widget chip(String label, String mode) {
      final active = _mode == mode;
      return Expanded(
        child: PressFace(
          onTap: () => setState(() => _mode = mode),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          rest: 0,
          pressedFace: 0,
          decoration: (_) => BoxDecoration(
            color: active ? AppTheme.black : AppTheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.line),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.body(12.5,
                  weight: FontWeight.w700,
                  color: active ? AppTheme.onAccent : AppTheme.ink)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 0, 13, 0),
      child: Row(
        children: [
          chip('Cash', 'Cash'),
          chip('DOP Cheque', 'DOP Cheque'),
          chip('Non-DOP', 'Non DOP Cheque'),
        ],
      ),
    );
  }

  Widget _searchRow() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: AppTheme.card(radius: 10),
          child: Row(
            children: [
              Icon(Icons.search, color: AppTheme.inkFaint, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  style: AppTheme.body(15),
                  cursorColor: AppTheme.accent,
                  decoration: InputDecoration(
                    hintText: 'Search name or account',
                    hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _filterBar() {
    final now = DateTime.now();
    final pool = _pool ?? const <_Candidate>[];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: _standingFilters.entries.map((e) {
          final on = _standing == e.value;
          final n = e.value == null
              ? pool.length
              : pool.where((c) => e.value!.test(c.account, now)).length;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PressFace(
              onTap: () => setState(() => _standing = e.value),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              rest: on ? 0 : AppTheme.faceOffset,
              decoration: (face) => on
                  ? AppTheme.panel(AppTheme.ink, radius: 20)
                  : AppTheme.card(radius: 20, offset: face),
              child: Text('${e.key}  $n',
                  style: AppTheme.body(13,
                      weight: FontWeight.w700,
                      color: on ? AppTheme.surface : AppTheme.inkMuted)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _bulkBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _selectAllShown,
            icon: const Icon(Icons.done_all, size: 18),
            label: const Text('Select all shown'),
          ),
          TextButton.icon(
            onPressed: _count == 0 ? null : _clearAll,
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Clear'),
          ),
          const Spacer(),
          if (_alreadyListed > 0)
            Flexible(
              child: Text('$_alreadyListed already listed',
                  textAlign: TextAlign.right,
                  style: AppTheme.body(12, color: AppTheme.inkMuted)),
            ),
        ],
      ),
    );
  }

  Widget _list() {
    final rows = _shown;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _alreadyListed > 0
                ? 'Every open account is already on a list this cycle.'
                : 'No accounts to list.',
            textAlign: TextAlign.center,
            style: AppTheme.body(14, color: AppTheme.inkMuted),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => _row(rows[i]),
    );
  }

  Widget _row(_Candidate c) {
    final a = c.account;
    final n = _selected[a.accountNumber] ?? 0;
    final on = n > 0;
    return Container(
      color: on ? AppTheme.greenSoft : AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      child: Row(
        children: [
          Checkbox(
            value: on,
            onChanged: (_) =>
                _setInstallments(a, on ? 0 : (c.seed > 0 ? c.seed : 1)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.customerName,
                    style: AppTheme.display(15, weight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                    '#${a.accountNumber} · ${inr(a.denominationAmount)} × $n = '
                    '${inr(a.denominationAmount * n)}',
                    style: AppTheme.body(12, color: AppTheme.inkMuted)),
                const SizedBox(height: 2),
                Text(_why(c),
                    style: AppTheme.body(11.5,
                        color: c.fromLedger ? AppTheme.green : AppTheme.inkFaint,
                        weight: FontWeight.w600)),
              ],
            ),
          ),
          _stepper(a, n),
        ],
      ),
    );
  }

  /// Where this row's number came from, in the agent's own terms. The
  /// distinction matters: a ledger figure is cash he has counted, an arrears
  /// figure is the app guessing from a due date.
  String _why(_Candidate c) {
    if (c.fromLedger) {
      return c.seed == 0
          ? 'Part-paid — no full month collected yet'
          : 'Collected ${c.seed} month${c.seed == 1 ? '' : 's'}';
    }
    final behind = AccountFilter.monthsBehind(c.account, DateTime.now());
    if (behind >= 1) return 'Owes $behind month${behind == 1 ? '' : 's'}';
    return 'Due this month';
  }

  Widget _stepper(RdAccount a, int n) => Row(
        children: [
          _circleBtn(Icons.remove, AppTheme.red, () => _setInstallments(a, n - 1)),
          SizedBox(
            width: 26,
            child: Text('$n',
                textAlign: TextAlign.center,
                style: AppTheme.body(15, weight: FontWeight.w700)),
          ),
          _circleBtn(Icons.add, AppTheme.green, () => _setInstallments(a, n + 1)),
        ],
      );

  Widget _circleBtn(IconData icon, Color color, VoidCallback onTap) => PressFace(
        onTap: onTap,
        width: 32,
        height: 32,
        rest: 0,
        pressedFace: 0,
        decoration: (_) => BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: AppTheme.onAccent, size: 18),
      );
}

/// Read the proposal before it becomes six filed documents.
///
/// This screen is the reason an automatic path is defensible at all. The old
/// auto-build wrote its lists straight to the database and told the agent how
/// many it had made; what was ON them he found out later, from the report, or
/// at the counter. Here every proposed list is open on screen with every row on
/// it, the arithmetic is shown per list, and nothing has been saved — backing
/// out costs him nothing because no account has been marked spoken-for yet.
///
/// Edits are deliberately limited to REMOVING a row. Adding an account here
/// would need the whole pool again, and moving one between lists by hand would
/// let him break the ₹20,000 ceiling the packer just satisfied. Removing can
/// only ever make a list smaller and legal, and [_regroup] re-packs what
/// remains when he wants the space closed up.
class _ReviewScreen extends StatefulWidget {
  const _ReviewScreen({
    required this.result,
    required this.mode,
    required this.accounts,
    required this.lots,
  });

  final PackResult result;
  final String mode;
  final AccountRepository accounts;
  final LotRepository lots;

  @override
  State<_ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<_ReviewScreen> {
  late List<PackedLot> _lots = [
    for (final l in widget.result.lots) PackedLot([...l.items])
  ];
  bool _saving = false;

  bool get _isCheque => widget.mode.toLowerCase().contains('cheque');

  int get _accountCount => _lots.fold(0, (s, l) => s + l.count);
  int get _totalAmount => _lots.fold(0, (s, l) => s + l.total);

  /// Rows the agent has taken off a list. Held rather than forgotten so the
  /// count can be shown — "6 removed" is the difference between a deliberate
  /// edit and a proposal that quietly lost people.
  final List<PackItem> _removed = [];

  void _remove(PackedLot lot, PackItem item) {
    setState(() {
      lot.items.remove(item);
      _removed.add(item);
      // A list emptied of every row is not a list. Drop it rather than filing
      // a document with a zero total.
      _lots.removeWhere((l) => l.items.isEmpty);
    });
  }

  /// Re-pack what is left, closing up the gaps the removals opened.
  ///
  /// Not automatic on every removal: rows would jump between lists under his
  /// thumb while he was still reading, and he would lose his place. He asks for
  /// it when he is done editing.
  void _regroup() {
    final items = [for (final l in _lots) ...l.items];
    final result = LotPacking.pack(
      items,
      DateTime.now(),
      amountCap: _isCheque ? null : ListBuilderScreen.lotCap,
      maxAccounts: ListBuilderScreen.maxAccounts,
    );
    setState(() {
      _lots = [for (final l in result.lots) PackedLot([...l.items])];
    });
  }

  // ------------------------------------------------------------------- saving

  Future<void> _create() async {
    if (_lots.isEmpty || _saving) return;

    final chosen = [for (final l in _lots) ...l.items.map((i) => i.account)];

    // Cheque modes: one pass over every account across ALL the lists. Account
    // numbers are unique across the proposal, so a single map keys back into
    // whichever list each row ended up on — and asking once beats pushing the
    // cheque screen six times.
    Map<String, ChequeEntry>? cheques;
    if (_isCheque) {
      final rows = [
        for (final l in _lots)
          for (final i in l.items)
            (account: i.account, installments: i.installments),
      ];
      cheques = await Navigator.of(context).push<Map<String, ChequeEntry>>(
        MaterialPageRoute(
          builder: (_) => ChequeEntryScreen(mode: widget.mode, rows: rows),
        ),
      );
      if (cheques == null || !mounted) return; // cancelled
    }

    // ASLAAS before the confirmation, for the same reason the manual builder
    // does it there: fetching pushes another screen, and doing that after
    // "Create" leaves him unsure whether the lists were made.
    final refreshed = await offerAslaasFetch(context, widget.accounts, chosen);
    if (refreshed == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Create ${_lots.length} list${_lots.length == 1 ? '' : 's'}?',
            style: AppTheme.display(17)),
        content: Text(
          '$_accountCount account${_accountCount == 1 ? '' : 's'} '
          '(${inr(_totalAmount)}, ${widget.mode}) across ${_lots.length} '
          'list${_lots.length == 1 ? '' : 's'} will be marked deposited for '
          'this cycle.',
          style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    final createdAt = DateTime.now();
    for (final packed in _lots) {
      final items = [
        for (final i in packed.items)
          LotItem(
            accountNumber: i.account.accountNumber,
            customerName: i.account.customerName,
            denomination: i.account.denominationAmount,
            installments: i.installments,
            chequeNumber: cheques?[i.account.accountNumber]?.chequeNo,
            bankAccountNumber: cheques?[i.account.accountNumber]?.bankAccount,
            // Each account's OWN ASLAAS, taken from the map `offerAslaasFetch`
            // handed back — the account objects this screen has been holding
            // since the pool was loaded may pre-date the fetch.
            aslaas: (refreshed[i.account.accountNumber] ?? i.account).aslaas,
          ),
      ];
      await widget.lots.save(Lot(
        createdAt: createdAt,
        mode: widget.mode,
        items: items,
      ));
    }

    unawaited(Analytics.track('lists_auto_created', {
      'lots': _lots.length,
      'accounts': _accountCount,
      'amount': _totalAmount,
      'mode': widget.mode,
      'removed': _removed.length,
    }));

    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Text('${_lots.length} list${_lots.length == 1 ? '' : 's'} '
          'created · $_accountCount accounts · ${inr(_totalAmount)}'),
    ));
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review lists'),
        actions: [
          TextButton(
            onPressed: _lots.isEmpty || _saving ? null : _regroup,
            child: const Text('Re-group'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 110),
        children: [
          _summary(),
          if (widget.result.unplaceable.isNotEmpty) _unplaceableCard(),
          const SizedBox(height: 4),
          for (var i = 0; i < _lots.length; i++) _lotCard(i, _lots[i]),
        ],
      ),
      floatingActionButton: _lots.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : _create,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.playlist_add_check, size: 20),
              label: Text(_saving
                  ? 'Creating…'
                  : 'Create ${_lots.length} list${_lots.length == 1 ? '' : 's'}'),
            ),
    );
  }

  Widget _summary() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.card(radius: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${_lots.length} list${_lots.length == 1 ? '' : 's'} · '
                '$_accountCount accounts · ${inr(_totalAmount)}',
                style: AppTheme.display(16, weight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                _removed.isEmpty
                    ? 'Nothing is saved yet. Check each list, then create.'
                    : '${_removed.length} removed. Re-group to close the gaps, '
                        'or create as they stand.',
                style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
          ],
        ),
      );

  /// Rows that fit on no list at all. Shown rather than dropped: an account
  /// that vanishes between the pool and the proposal is found at the counter.
  Widget _unplaceableCard() {
    final rows = widget.result.unplaceable;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.card(fill: AppTheme.amberSoft, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${rows.length} left out',
              style: AppTheme.display(15, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              'These are worth more on their own than a cash list may hold '
              '(${inr(ListBuilderScreen.lotCap)}). Put each on its own list by '
              'hand, or list fewer months.',
              style: AppTheme.body(12.5, color: AppTheme.inkMuted, height: 1.35)),
          const SizedBox(height: 8),
          for (final i in rows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  '${i.account.customerName} · #${i.account.accountNumber} · '
                  '${i.installments} × ${inr(i.account.denominationAmount)} = '
                  '${inr(i.amount)}',
                  style: AppTheme.body(12.5, weight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _lotCard(int index, PackedLot lot) {
    // How full this list is against whichever ceiling actually binds it.
    final pct = _isCheque
        ? lot.count / ListBuilderScreen.maxAccounts
        : lot.total / ListBuilderScreen.lotCap;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      decoration: AppTheme.card(radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('List ${index + 1}',
                    style: AppTheme.display(16, weight: FontWeight.w700)),
                Text(
                    '${lot.count}/${ListBuilderScreen.maxAccounts} · '
                    '${inr(lot.total)}',
                    style: AppTheme.body(13,
                        weight: FontWeight.w700, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: AppTheme.line,
                color: AppTheme.green,
              ),
            ),
          ),
          const SizedBox(height: 4),
          for (final item in lot.items) _itemRow(lot, item),
        ],
      ),
    );
  }

  Widget _itemRow(PackedLot lot, PackItem item) {
    final a = item.account;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.customerName,
                    style: AppTheme.body(14, weight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                Text(
                    '#${a.accountNumber} · ${item.installments} × '
                    '${inr(a.denominationAmount)} = ${inr(item.amount)}',
                    style: AppTheme.body(11.5, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove from this list',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18, color: AppTheme.inkFaint),
            onPressed: _saving ? null : () => _remove(lot, item),
          ),
        ],
      ),
    );
  }
}
