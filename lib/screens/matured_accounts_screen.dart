import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/account_repository.dart';
import '../data/collection_repository.dart';
import '../models/rd_account.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'portfolio_screen.dart';

/// Settings → Matured Accounts: the accounts that have left the agent's book.
///
/// An RD account that matures and closes simply stops appearing in the portal's
/// "Agent Inquire and Update" listing — there is no status column and no
/// closure event to read. So a sync that read EVERY page marks the accounts it
/// no longer saw as closed ([AccountRepository.replaceAll] with
/// `complete: true`), and this is where they surface.
///
/// They are shown for one month and then drop out of the list (see
/// [maturedFrom]). The row itself is never deleted — `collections` holds real
/// money the agent took at that door, and a payment with no name against it is
/// worse than a closed account he can no longer see. So this screen is a window
/// onto recent closures, not an archive: long enough to hand over the passbook
/// and check what the customer paid in, short enough that it never becomes a
/// second, stale book.
class MaturedAccountsScreen extends StatefulWidget {
  const MaturedAccountsScreen({super.key, required this.repo, this.collections});

  final AccountRepository repo;

  /// Ledger for the account's Khata tab — the reason these rows are kept at
  /// all. Null just hides that tab.
  final CollectionRepository? collections;

  @override
  State<MaturedAccountsScreen> createState() => _MaturedAccountsScreenState();
}

class _MaturedAccountsScreenState extends State<MaturedAccountsScreen> {
  Future<List<RdAccount>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() =>
      _future = widget.repo.maturedSince(maturedFrom(DateTime.now()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Matured Accounts')),
      body: FutureBuilder<List<RdAccount>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return _empty();
          return ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 120),
            children: [
              _note(),
              for (final a in list) _row(a),
            ],
          );
        },
      ),
    );
  }

  /// Says what the list is and why it is short, so an agent who closed six
  /// accounts and sees two isn't left wondering where the others went.
  Widget _note() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 14),
          child: Text(
            'Accounts that left your book in the last month — matured and '
            'closed, or transferred. Tap one to see what the customer paid in. '
            'They drop off this list a month after closing.',
            style: AppTheme.body(13, color: AppTheme.inkMuted),
          ),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No accounts have closed in the last month.\n\n'
            'An account appears here after a Sync that finishes — that is when '
            'the app can tell a closed account from a page it never reached.',
            textAlign: TextAlign.center,
            style: AppTheme.body(14, color: AppTheme.inkMuted),
          ),
        ),
      );

  Widget _row(RdAccount a) {
    final closedOn = DateFormat('dd-MMM-yyyy').format(a.closedAt!);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PortfolioScreen(
                repo: widget.repo,
                accountNumber: a.accountNumber,
                collections: widget.collections,
              ),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            decoration: AppTheme.card(radius: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.customerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.display(15.5,
                                  weight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text('#${a.accountNumber}',
                              style:
                                  AppTheme.body(13, color: AppTheme.inkFaint)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration:
                          AppTheme.panel(AppTheme.greenSoft, radius: 8),
                      child: Text('Closed',
                          style: AppTheme.body(12,
                              weight: FontWeight.w800,
                              color: AppTheme.green)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Deliberately NOT the due date. This account has no next due
                // date any more; showing one (in red, aging by a month every
                // month) is exactly the bug this screen exists to end.
                Row(
                  children: [
                    _fact('Closed on', closedOn),
                    _fact('Paid in', inr(a.depositedAmount)),
                    _fact('Installments', '${a.monthsPaid}'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fact(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTheme.label(AppTheme.inkFaint)),
            const SizedBox(height: 3),
            Text(value,
                style: AppTheme.body(13.5, weight: FontWeight.w700)),
          ],
        ),
      );
}
