import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../data/collection_repository.dart';
import '../models/collection.dart';
import '../models/rd_account.dart';
import '../util/format.dart';

/// Recording a collection by voice — the one thing the assistant could not do,
/// and the only thing he actually needs it for mid-round.
///
/// The design rule throughout this file is that **the assistant proposes, the
/// agent disposes**. Nothing here writes on its own: every path ends in a
/// [CollectAction] the chat renders as a card he has to tap. Three properties
/// make that safe enough to hand a language model:
///
///   1. An action can only ever name an account that already exists in his
///      book. A misheard phrase resolves to nobody and falls through to the
///      ordinary answer path instead of inventing a customer.
///   2. An ambiguous name never becomes an action — it becomes a list to pick
///      from. "Ramesh" with three Rameshes is a question, not an instruction.
///   3. Every write is one ledger row, and the outcome carries its id, so undo
///      is the same delete the swipe-left gesture performs.
enum CollectActionKind { collect, undo }

/// A proposed, not-yet-performed change to the collection ledger.
class CollectAction {
  const CollectAction({
    required this.kind,
    required this.account,
    required this.amount,
    this.installments,
    this.entryId,
  });

  final CollectActionKind kind;
  final RdAccount account;

  /// Rupees to record, or — for an undo — the rupees about to be removed.
  final int amount;

  /// Months this covers. Null means "let the sheet's own rule decide": 0 for a
  /// part-payment, 1 for a full installment.
  final int? installments;

  /// The ledger row an undo would delete.
  final int? entryId;

  bool get isUndo => kind == CollectActionKind.undo;

  /// The line on the confirm card. States the money and the person, because
  /// those are the only two things he can check at a doorstep.
  String get title => isUndo
      ? 'Undo ${inr(amount)} from ${account.customerName}?'
      : 'Record ${inr(amount)} from ${account.customerName}?';

  String get detail => '#${account.accountNumber} · '
      '${inr(account.denominationAmount)} a month';
}

/// What the parser managed to pull out of a spoken sentence, before anything
/// has been checked against the book.
class CollectRequest {
  const CollectRequest({required this.name, this.amount, this.isUndo = false});
  final String name;
  final int? amount;
  final bool isUndo;
}

/// The outcome of matching a [CollectRequest] against real accounts.
sealed class CollectResolution {
  const CollectResolution();
}

/// No account of that name — treat the sentence as an ordinary question.
class CollectNoMatch extends CollectResolution {
  const CollectNoMatch();
}

/// Several customers match. Deliberately NOT an action: picking one on his
/// behalf would put money against the wrong account, which is the single most
/// expensive mistake this feature could make.
class CollectAmbiguous extends CollectResolution {
  const CollectAmbiguous(this.matches);
  final List<RdAccount> matches;
}

class CollectReady extends CollectResolution {
  const CollectReady(this.action);
  final CollectAction action;
}

/// Turns a spoken sentence into a [CollectRequest]. Pure, offline, and free —
/// this is what makes voice collection work in a village with no signal.
class CollectPhrase {
  /// Words that mean money changed hands. Past tense on purpose: "Ramesh se
  /// paanch sau lena hai" is a plan, not a receipt, and must not record
  /// anything.
  static final _tookVerb = RegExp(
    r'(?<![a-z])(le\s?liya|liya|le\s?li|mila|mil\s?gaya|diya|de\s?diya|'
    r'diye|jama\s?kiya|collected|received|paid|gave|took)(?![a-z])',
    caseSensitive: false,
  );

  static final _undoVerb = RegExp(
    r'(?<![a-z])(undo|hata\s?do|hatao|galat|mistake|cancel|wapas|remove)(?![a-z])',
    caseSensitive: false,
  );

  /// Rupees. Bare digits only — spelled-out numbers ("paanch sau") are left to
  /// the cloud extractor rather than guessed at, because a wrong amount is
  /// worse than no amount.
  static final _amount = RegExp(r'(?:₹|rs\.?|rupees?|rupaye)?\s*(\d{2,7})');

  /// Connectors and noise to strip once the verb and amount are out, leaving
  /// the customer's name behind.
  static const _filler = [
    'se', 'ne', 'ko', 'ka', 'ki', 'ke', 'from', 'of', 'for', 'aaj', 'today',
    'abhi', 'now', 'rupaye', 'rupees', 'rupee', 'rs', 'record', 'karo', 'kar',
    'do', 'entry', 'add', 'collection', 'collect', 'please', 'ji', 'hai', 'ha',
    'haan', 'yes', 'wala', 'wale', 'sahab', 'saheb', 'the', 'a', 'an',
  ];

  /// Returns a request when the sentence reads like an instruction about money
  /// changing hands, else null. A null here is the common case — most input is
  /// still a question.
  static CollectRequest? parse(String question) {
    final q = question.toLowerCase().trim();
    if (q.isEmpty) return null;

    final undo = _undoVerb.hasMatch(q);
    final took = _tookVerb.hasMatch(q);
    if (!undo && !took) return null;

    // A question word means he is asking, not instructing. "Ramesh se kitna
    // liya" wants the ledger read back, not another entry written into it.
    //
    // The Hindi interrogatives take case endings — kis/kisne/kisko/kiska,
    // kaun/kaunsa/kaunsi — so they are matched with a trailing wildcard. A word
    // wrongly caught here only costs a proposal he could have confirmed; one
    // wrongly missed turns a question into a proposed write, which is the
    // failure worth avoiding.
    if (RegExp(r'(?<![a-z])(kitn[aei]|how much|how many|kya|what|kis[a-z]*|'
            r'kaun[a-z]*|which|kab|when|batao|dikhao|show|list)(?![a-z])')
        .hasMatch(q)) {
      return null;
    }

    final m = _amount.firstMatch(q);
    final amount = m == null ? null : int.tryParse(m.group(1)!);

    // Everything that is not the verb, the amount or filler is the name.
    var rest = q
        .replaceAll(_tookVerb, ' ')
        .replaceAll(_undoVerb, ' ')
        .replaceAll(RegExp(r'[₹0-9,.\-]'), ' ');
    final words = rest
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r'[^a-zऀ-ॿ]'), ''))
        .where((w) => w.isNotEmpty && !_filler.contains(w))
        .toList();
    final name = words.join(' ').trim();
    if (name.length < 3) return null;

    return CollectRequest(
        name: name, amount: amount == null || amount <= 0 ? null : amount,
        isUndo: undo);
  }
}

/// Resolves requests against the real book and performs the confirmed action.
///
/// Holds the repositories rather than a database handle, so every write goes
/// through exactly the same path the collect sheet uses — the ledger stays
/// append-and-delete-only, and an agent mistake undoes like a mis-swipe.
class CollectActions {
  CollectActions({required this.accounts, required this.collections});

  final AccountRepository accounts;
  final CollectionRepository collections;

  /// Match the spoken name to an account and work out what to record.
  Future<CollectResolution> resolve(CollectRequest r, DateTime now) async {
    final matches = await _search(r.name);
    if (matches.isEmpty) return const CollectNoMatch();
    if (matches.length > 1) return CollectAmbiguous(matches);

    final account = matches.first;
    final cycle = Collection.cycleOf(now);
    final history = await collections.forAccount(account.accountNumber);
    final thisCycle = history.where((c) => c.cycleYm == cycle).toList();

    if (r.isUndo) {
      if (thisCycle.isEmpty) return const CollectNoMatch();
      final last = thisCycle.first; // repository returns newest first
      return CollectReady(CollectAction(
        kind: CollectActionKind.undo,
        account: account,
        amount: last.amount,
        entryId: last.id,
      ));
    }

    final rule = await AppSettings.dailyRule();
    final progress = CollectionProgress(
      account: account,
      collected: thisCycle.fold(0, (s, c) => s + c.amount),
      installments: thisCycle.fold(0, (s, c) => s + c.installments),
      entries: thisCycle,
      dailyAmount: rule.amountFor(account),
    );

    // No amount spoken: fall back to whatever the sheet's own toggle would
    // have taken, so the voice path and the swipe path can never disagree.
    final daily = await AppSettings.collectDailyMode();
    final amount = r.amount ?? (daily ? progress.dailyNext : progress.monthlyNext);
    if (amount <= 0) return const CollectNoMatch();

    return CollectReady(CollectAction(
      kind: CollectActionKind.collect,
      account: account,
      amount: amount,
      // An explicit amount is a part-payment unless it covers a whole month.
      installments: amount >= progress.target ? 1 : 0,
    ));
  }

  /// Name matching, tightened past a bare LIKE.
  ///
  /// A substring search on 480 customers turns "Ram" into a dozen hits, so an
  /// exact full-name match wins outright when there is one — otherwise every
  /// Ram Kumar in the book would be unrecordable by voice.
  Future<List<RdAccount>> _search(String name) async {
    final all = await accounts.search(name);
    if (all.length <= 1) return all;
    final exact = all
        .where((a) => a.customerName.toLowerCase().trim() == name.trim())
        .toList();
    return exact.length == 1 ? exact : all;
  }

  /// Perform a confirmed action. Returns the sentence to show him, plus the
  /// ledger row id so the chat can offer an undo that outlives a snackbar.
  Future<CollectOutcome> perform(CollectAction a, DateTime now) async {
    if (a.isUndo) {
      final id = a.entryId;
      if (id == null) {
        return const CollectOutcome(message: 'Nothing to undo.', entryId: null);
      }
      await collections.remove(id);
      return CollectOutcome(
        message: '${inr(a.amount)} removed from ${a.account.customerName}.',
        entryId: null,
      );
    }

    final saved = await collections.add(Collection(
      accountNumber: a.account.accountNumber,
      amount: a.amount,
      installments: a.installments ?? 0,
      collectedAt: now,
      cycleYm: Collection.cycleOf(now),
    ));
    return CollectOutcome(
      message: '${inr(a.amount)} recorded for ${a.account.customerName}.',
      entryId: saved.id,
    );
  }

  /// Undo a write this conversation made.
  Future<void> undo(int entryId) => collections.remove(entryId);
}

class CollectOutcome {
  const CollectOutcome({required this.message, required this.entryId});
  final String message;

  /// The row that was written, so it can be taken back. Null when there is
  /// nothing left to undo.
  final int? entryId;
}
