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

  const LotItem({
    required this.accountNumber,
    required this.customerName,
    required this.denomination,
    required this.installments,
    this.chequeNumber,
    this.bankAccountNumber,
  });

  int get amount => denomination * installments;

  LotItem copyWith({
    int? installments,
    String? chequeNumber,
    String? bankAccountNumber,
  }) =>
      LotItem(
        accountNumber: accountNumber,
        customerName: customerName,
        denomination: denomination,
        installments: installments ?? this.installments,
        chequeNumber: chequeNumber ?? this.chequeNumber,
        bankAccountNumber: bankAccountNumber ?? this.bankAccountNumber,
      );

  Map<String, Object?> toJson() => {
        'a': accountNumber,
        'n': customerName,
        'd': denomination,
        'i': installments,
        // Only written when set, so existing cash items keep their compact shape.
        if (chequeNumber != null) 'cn': chequeNumber,
        if (bankAccountNumber != null) 'ba': bankAccountNumber,
      };

  factory LotItem.fromJson(Map<String, Object?> j) => LotItem(
        accountNumber: j['a'] as String,
        customerName: j['n'] as String,
        denomination: (j['d'] as num).toInt(),
        installments: (j['i'] as num).toInt(),
        chequeNumber: j['cn'] as String?,
        bankAccountNumber: j['ba'] as String?,
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

  /// Day only — used to group lists into batches (all lists made the same day).
  String get dayLabel => DateFormat('dd-MMM-yyyy').format(createdAt);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'created_at': createdAt.toIso8601String(),
        'mode': mode,
        'items_json': jsonEncode(items.map((e) => e.toJson()).toList()),
        'reference_number': referenceNumber,
        'submitted_at': submittedAt?.toIso8601String(),
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
