import 'package:intl/intl.dart';

import '../models/collection.dart';
import 'format.dart';

/// Plain-text messages the agent sends out of the app — a receipt to a
/// customer, and a summary of the day's takings for his own record.
///
/// Kept as pure functions with no widgets and no plugins so the wording can be
/// unit-tested. These go to real customers, so the numbers in them have to be
/// exactly the numbers in the ledger.
class Receipt {
  Receipt._();

  static final _date = DateFormat('dd-MMM-yyyy');
  static final _time = DateFormat('h:mm a');

  /// Confirmation that money changed hands, for the customer.
  ///
  /// Deliberately states what is and isn't true yet: cash received by the
  /// agent is not the same as a deposit recorded at the post office, and a
  /// receipt that blurs the two is how disputes start. When the month is fully
  /// paid it says so; when it isn't, it names the balance.
  static String collection({
    required String customerName,
    required String accountNumber,
    required int amount,
    required DateTime at,
    required int collectedThisCycle,
    required int monthlyAmount,
    String? agentName,
  }) {
    final b = StringBuffer()
      ..writeln('*Received ${inr(amount)}*')
      ..writeln()
      ..writeln(customerName)
      ..writeln('RD A/c: $accountNumber')
      ..writeln('Date: ${_date.format(at)}, ${_time.format(at)}');

    if (monthlyAmount > 0) {
      final remaining = monthlyAmount - collectedThisCycle;
      b.writeln();
      b.writeln('This month: ${inr(collectedThisCycle)} of '
          '${inr(monthlyAmount)}');
      if (remaining > 0) {
        b.writeln('Still to pay: ${inr(remaining)}');
      } else {
        b.writeln('Fully paid for this month ✓');
      }
    }

    b
      ..writeln()
      ..writeln('Received by your agent. The deposit is made at the post '
          'office at month end.');
    if (agentName != null && agentName.trim().isNotEmpty) {
      b.writeln('— ${agentName.trim()}');
    }
    return b.toString().trimRight();
  }

  /// The day's takings, for his own record — what he sends himself or keeps in
  /// the chat as proof of the round.
  static String daySummary({
    required DateTime day,
    required List<Collection> entries,
    required Map<String, String> namesByAccount,
    int? counted,
  }) {
    final total = entries.fold(0, (s, c) => s + c.amount);
    final b = StringBuffer()
      ..writeln('*Collection — ${_date.format(day)}*')
      ..writeln()
      ..writeln('${entries.length} collections · ${inr(total)}');

    if (counted != null) {
      final diff = counted - total;
      b.writeln('Cash counted: ${inr(counted)}');
      if (diff == 0) {
        b.writeln('Tallies ✓');
      } else if (diff < 0) {
        b.writeln('Short by ${inr(-diff)}');
      } else {
        b.writeln('Extra ${inr(diff)}');
      }
    }

    b.writeln();
    // Oldest first here — it reads as the order he walked the round.
    final ordered = [...entries]
      ..sort((a, c) => a.collectedAt.compareTo(c.collectedAt));
    for (final c in ordered) {
      final name = namesByAccount[c.accountNumber] ?? c.accountNumber;
      b.writeln('${_time.format(c.collectedAt)}  $name  ${inr(c.amount)}');
    }
    return b.toString().trimRight();
  }
}
