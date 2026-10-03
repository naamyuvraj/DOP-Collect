import 'dart:convert';

import 'package:intl/intl.dart';

/// One account line in a saved collection list (lot): what installment count
/// was collected and the resulting amount.
class LotItem {
  final String accountNumber;
  final String customerName;
  final int denomination;
  final int installments;

  // Cheque modes (DOP / Non-DOP) only: the portal needs the cheque number and
  // the bank account number printed on the cheque. Null for cash.
  final String? chequeNumber;
  final String? bankAccountNumber;

  /// This account's OWN ASLAAS number, snapshotted when the list was created.
  /// One number per account — never the agency-wide value it used to be.
  final String? aslaas;

  /// Rebate and default fee, in paise-free rupees, exactly as the PORTAL
  /// computed them when the list was submitted.
  ///
  /// These are not ours to calculate. The portal works them out from the
  /// account's own history when "Get Rebate and Default" runs, and the printed
  /// report has to agree with the receipt the post office holds. The app read
  /// them during submission and then discarded them, so every report printed
  /// 0.00 in both columns — for an advance payer that understated what he was
  /// owed, and for a defaulter it hid the fee he had paid.
  ///
  /// Null means "never submitted, so the portal has not said" — printed blank.
  /// Zero is a real answer and prints as 0.00.
  final int? rebate;
  final int? defaultFee;

  const LotItem({
    required this.accountNumber,
    required this.customerName,
    required this.denomination,
    required this.installments,
    this.chequeNumber,
    this.bankAccountNumber,
    this.aslaas,
    this.rebate,
    this.defaultFee,
  });

  int get amount => denomination * installments;

  /// What the agent actually hands over for this account.
  ///
  /// Rebate is a DISCOUNT for paying ahead and comes off; default fee is a
  /// SURCHARGE for paying late and goes on. Getting the sign wrong would make a
  /// defaulter's list read low, which is the one direction that loses money at
  /// the counter.
  ///
  /// Falls back to the gross deposit until the portal has answered, so an
  /// unsubmitted list still totals to something real.
  int get netAmount => amount - (rebate ?? 0) + (defaultFee ?? 0);

  LotItem copyWith({
    int? installments,
    String? chequeNumber,
    String? bankAccountNumber,
    String? aslaas,
    int? rebate,
    int? defaultFee,
  }) =>
      LotItem(
        accountNumber: accountNumber,
        customerName: customerName,
        denomination: denomination,
        installments: installments ?? this.installments,
        chequeNumber: chequeNumber ?? this.chequeNumber,
        bankAccountNumber: bankAccountNumber ?? this.bankAccountNumber,
        aslaas: aslaas ?? this.aslaas,
        rebate: rebate ?? this.rebate,
        defaultFee: defaultFee ?? this.defaultFee,
      );

  Map<String, Object?> toJson() => {
        'a': accountNumber,
        'n': customerName,
        'd': denomination,
        'i': installments,
        // Only written when set, so existing cash items keep their compact shape.
        if (chequeNumber != null) 'cn': chequeNumber,
        if (bankAccountNumber != null) 'ba': bankAccountNumber,
        if (aslaas != null) 'as': aslaas,
        // Only written once the portal has said, so a list prepared but never
        // submitted stays byte-identical to what older builds wrote.
        if (rebate != null) 'rb': rebate,
        if (defaultFee != null) 'df': defaultFee,
      };

  factory LotItem.fromJson(Map<String, Object?> j) => LotItem(
        accountNumber: j['a'] as String,
        customerName: j['n'] as String,
        denomination: (j['d'] as num).toInt(),
        installments: (j['i'] as num).toInt(),
        chequeNumber: j['cn'] as String?,
        bankAccountNumber: j['ba'] as String?,
        aslaas: j['as'] as String?,
        rebate: (j['rb'] as num?)?.toInt(),
        defaultFee: (j['df'] as num?)?.toInt(),
      );
}

/// A saved collection list to key into / submit at the post office.
class Lot {
  final int? id;
  final DateTime createdAt;
  final String mode; // 'Cash' | 'DOP Cheque' | 'Non DOP Cheque'
  final List<LotItem> items;

  // Set once the list has actually been submitted on the DOP portal: the real
  // reference (C…/DC…/NDC…) and when. Null until then — the printed `L…` id is
  // only a local handle.
  final String? referenceNumber;
  final DateTime? submittedAt;

  const Lot({
    this.id,
    required this.createdAt,
    required this.mode,
    required this.items,
    this.referenceNumber,
    this.submittedAt,
  });

  int get count => items.length;
  int get totalAmount => items.fold(0, (s, i) => s + i.amount);

  /// Portal-computed totals across the list. Null contributes nothing, so a
  /// half-submitted list totals only what the portal actually answered for.
  int get totalRebate => items.fold(0, (s, i) => s + (i.rebate ?? 0));
  int get totalDefaultFee => items.fold(0, (s, i) => s + (i.defaultFee ?? 0));

  /// True once the portal has returned figures for at least one line — the
  /// report uses this to decide between printing real numbers and printing
  /// blanks, rather than printing a confident 0.00 it cannot stand behind.
  /// Total actually payable: deposits, less rebates, plus default fees. This is
  /// the figure that has to match the cash he hands across the counter.
  int get totalNetAmount => items.fold(0, (s, i) => s + i.netAmount);

  bool get hasPortalFigures =>
      items.any((i) => i.rebate != null || i.defaultFee != null);
  int get totalInstallments => items.fold(0, (s, i) => s + i.installments);

  /// True once a real portal reference has been captured for this list.
  bool get isSubmitted => referenceNumber != null;

  Lot copyWith({
    int? id,
    List<LotItem>? items,
    String? referenceNumber,
    DateTime? submittedAt,
  }) =>
      Lot(
        id: id ?? this.id,
        createdAt: createdAt,
        mode: mode,
        items: items ?? this.items,
        referenceNumber: referenceNumber ?? this.referenceNumber,
        submittedAt: submittedAt ?? this.submittedAt,
      );

  String get dateLabel => DateFormat('dd-MMM-yyyy · hh:mm a').format(createdAt);

  /// The date this list should be FILED under.
  ///
  /// Submission time when it has one, creation time otherwise. The Downloads tab
  /// used to group on `createdAt`, so a list built on Thursday and submitted
  /// today filed itself under Thursday and read as old — the agent was being
  /// shown the wrong event. What he is looking for is what he submitted, because
  /// that is when the reference was minted and when he walks to the counter.
  DateTime get filedAt => submittedAt ?? createdAt;

  /// Day key for grouping — [filedAt], not creation.
  String get filedDayLabel => DateFormat('dd-MMM-yyyy').format(filedAt);

  /// Clock time, so two batches submitted on the SAME day separate visually
  /// instead of merging into one undifferentiated block.
  String get filedTimeLabel => DateFormat('hh:mm a').format(filedAt);

  /// "Today" / "Yesterday" / the date. A bare `14-Aug-2026` beside
  /// `16-Aug-2026` does not read as old-versus-new at a glance, which is most of
  /// why the tab was hard to scan.
  static String relativeDay(DateTime d, DateTime now) {
    final day = DateTime(d.year, d.month, d.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat('dd-MMM-yyyy').format(d);
  }

  /// Lists grouped by the day they were filed, NEWEST DAY FIRST, and newest
  /// first within each day.
  ///
  /// Both orderings used to be incidental: the repository returns
  /// `created_at DESC`, so day groups appeared in whatever order their first lot
  /// happened to arrive and a day's lots were ordered by creation rather than
  /// submission. Today's batch could sit below last week's.
  static List<({String day, List<Lot> lots})> groupByDay(List<Lot> lots) {
    final groups = <String, List<Lot>>{};
    for (final l in lots) {
      (groups[l.filedDayLabel] ??= []).add(l);
    }
    final out = groups.entries
        .map((e) => (
              day: e.key,
              lots: [...e.value]..sort((a, b) => b.filedAt.compareTo(a.filedAt)),
            ))
        .toList();
    out.sort((a, b) => b.lots.first.filedAt.compareTo(a.lots.first.filedAt));
    return out;
  }

  /// Day only — used to group lists into batches (all lists made the same day).
  String get dayLabel => DateFormat('dd-MMM-yyyy').format(createdAt);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'created_at': createdAt.toIso8601String(),
        'mode': mode,
        'items_json': jsonEncode(items.map((e) => e.toJson()).toList()),
        'reference_number': referenceNumber,
        'submitted_at': submittedAt?.toIso8601String(),
        // Denormalised so `v_lots` can report size and value in plain SQL. The
        // items live in a JSON blob, and relying on SQLite's JSON1 extension
        // being compiled into every SQLCipher build is not a bet worth taking
        // for a view the assistant depends on.
        'item_count': count,
        'total_amount': totalAmount,
      };

  factory Lot.fromMap(Map<String, Object?> m) => Lot(
        id: (m['id'] as num?)?.toInt(),
        createdAt: DateTime.parse(m['created_at'] as String),
        mode: m['mode'] as String,
        items: (jsonDecode(m['items_json'] as String) as List)
            .map((e) => LotItem.fromJson(e as Map<String, Object?>))
            .toList(),
        referenceNumber: m['reference_number'] as String?,
        submittedAt: m['submitted_at'] == null
            ? null
            : DateTime.tryParse(m['submitted_at'] as String),
      );
}
