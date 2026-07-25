import 'dart:convert';

import 'package:intl/intl.dart';

/// One account line in a saved collection list (lot): what installment count
/// was collected and the resulting amount.
class LotItem {
  final String accountNumber;
  final String customerName;
  final int denomination;
  final int installments;

  const LotItem({
    required this.accountNumber,
    required this.customerName,
    required this.denomination,
    required this.installments,
  });

  int get amount => denomination * installments;

  Map<String, Object?> toJson() => {
        'a': accountNumber,
        'n': customerName,
        'd': denomination,
        'i': installments,
      };

  factory LotItem.fromJson(Map<String, Object?> j) => LotItem(
        accountNumber: j['a'] as String,
        customerName: j['n'] as String,
        denomination: (j['d'] as num).toInt(),
        installments: (j['i'] as num).toInt(),
      );
}

/// A saved collection list to key into / submit at the post office.
class Lot {
  final int? id;
  final DateTime createdAt;
  final String mode; // 'Cash' for now
  final List<LotItem> items;

  const Lot({
    this.id,
    required this.createdAt,
    required this.mode,
    required this.items,
  });

  int get count => items.length;
  int get totalAmount => items.fold(0, (s, i) => s + i.amount);
  int get totalInstallments => items.fold(0, (s, i) => s + i.installments);

  Lot copyWith({List<LotItem>? items}) => Lot(
        id: id,
        createdAt: createdAt,
        mode: mode,
        items: items ?? this.items,
      );

  String get dateLabel => DateFormat('dd-MMM-yyyy · hh:mm a').format(createdAt);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'created_at': createdAt.toIso8601String(),
        'mode': mode,
        'items_json': jsonEncode(items.map((e) => e.toJson()).toList()),
      };

  factory Lot.fromMap(Map<String, Object?> m) => Lot(
        id: (m['id'] as num?)?.toInt(),
        createdAt: DateTime.parse(m['created_at'] as String),
        mode: m['mode'] as String,
        items: (jsonDecode(m['items_json'] as String) as List)
            .map((e) => LotItem.fromJson(e as Map<String, Object?>))
            .toList(),
      );
}
