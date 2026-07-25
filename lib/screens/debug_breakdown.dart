import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';

/// Temporary diagnostics: shows the real distribution of the synced accounts so
/// the dashboard bucket rules can be matched to the core app exactly. Removed
/// once the rules are locked.
class DebugBreakdown extends StatelessWidget {
  const DebugBreakdown({super.key, required this.repo});
  final AccountRepository repo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data breakdown (debug)')),
      body: FutureBuilder<List<RdAccount>>(
        future: repo.all(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final now = DateTime.now();
          final a = snap.data!;

          // months behind, split by fortnight
          final firstBehind = <int, int>{};
          final secondBehind = <int, int>{};
          for (final x in a) {
            final b = AccountFilter.monthsBehind(x, now);
            final m = x.fortnight == Fortnight.first ? firstBehind : secondBehind;
            m[b] = (m[b] ?? 0) + 1;
          }

          // months paid buckets (4/5/6 split out to pin "New Accounts")
          final paid = <String, int>{
            '<=1': 0, '2': 0, '3': 0, '4': 0, '5': 0, '6': 0, '7-57': 0,
            '58': 0, '59': 0, '60': 0, '61': 0, '62': 0, '63': 0,
            '64': 0, '65+': 0,
          };
          for (final x in a) {
            final p = x.monthsPaid;
            if (p <= 1) {
              paid['<=1'] = paid['<=1']! + 1;
            } else if (p <= 6) {
              paid['$p'] = paid['$p']! + 1;
            } else if (p <= 57) {
              paid['7-57'] = paid['7-57']! + 1;
            } else if (p >= 65) {
              paid['65+'] = paid['65+']! + 1;
            } else {
              paid['$p'] = (paid['$p'] ?? 0) + 1;
            }
          }

          // Second-half due-DAY histogram, split by behind (to find the
          // Pending/Deposited cutoff the core app uses vs today's day).
          final shBehindMinus1Day = <int, int>{};
          final shBehind0Day = <int, int>{};
          for (final x in a) {
            if (x.fortnight != Fortnight.second) continue;
            final b = AccountFilter.monthsBehind(x, now);
            final d = x.nextDueDate.day;
            if (b == -1) shBehindMinus1Day[d] = (shBehindMinus1Day[d] ?? 0) + 1;
            if (b == 0) shBehind0Day[d] = (shBehind0Day[d] ?? 0) + 1;
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _line('today', now.toIso8601String().substring(0, 10)),
              _line('total accounts', '${a.length}'),
              const Divider(),
              _h('FIRST HALF · months behind (0=this month, -1=next, +1=overdue)'),
              ..._behindLines(firstBehind),
              const Divider(),
              _h('SECOND HALF · months behind'),
              ..._behindLines(secondBehind),
              const Divider(),
              _h('MONTHS PAID buckets'),
              ...paid.entries
                  .where((e) => e.value > 0)
                  .map((e) => _line(e.key, '${e.value}')),
              const Divider(),
              _h('SECOND HALF · behind -1 · by due day (today day=${now.day})'),
              ..._dayLines(shBehindMinus1Day, now.day),
              const Divider(),
              _h('SECOND HALF · behind 0 · by due day'),
              ..._dayLines(shBehind0Day, now.day),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _behindLines(Map<int, int> m) {
    final keys = m.keys.toList()..sort();
    return keys.map((k) => _line('behind $k', '${m[k]}')).toList();
  }

  /// Due-day counts with a running cumulative, so the Pending/Deposited cutoff
  /// reads off directly. "day D: n (cum C)".
  List<Widget> _dayLines(Map<int, int> m, int todayDay) {
    final keys = m.keys.toList()..sort();
    var cum = 0;
    return keys.map((k) {
      cum += m[k]!;
      final marker = k == todayDay ? '  <= today' : '';
      return _line('day $k', '${m[k]}  (cum $cum)$marker');
    }).toList();
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Text(t, style: AppTheme.label(AppTheme.accent)),
      );

  Widget _line(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: AppTheme.body(13, color: AppTheme.inkMuted)),
            Text(v, style: AppTheme.body(14, weight: FontWeight.w700)),
          ],
        ),
      );
}
