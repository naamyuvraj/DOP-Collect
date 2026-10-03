import 'package:flutter/material.dart';

import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'press.dart';

/// One account as a white floating card: avatar-style initial, name + account,
/// installment info on the left; due date and serial on the right.
class AccountRow extends StatelessWidget {
  const AccountRow({super.key, required this.account, this.onTap});
  final RdAccount account;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Colour the due date by how far behind the account is: overdue = red,
    // due this month = amber, paid ahead = green. (Was always red, which made
    // every "Deposited" list look like a wall of danger.)
    final behind = AccountFilter.monthsBehind(account, DateTime.now());
    final dueColor = behind >= 1
        ? AppTheme.red
        : behind == 0
            ? AppTheme.amber
            : AppTheme.green;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: PressFace(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: (face) => AppTheme.card(radius: 20, offset: face),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _avatar(account.customerName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(account.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.display(15.5, weight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text('#${account.accountNumber}',
                      style: AppTheme.body(13, color: AppTheme.inkFaint)),
                  const SizedBox(height: 5),
                  Text(
                    '${inr(account.denominationAmount)} · ${account.monthsPaid} paid',
                    style: AppTheme.body(13, color: AppTheme.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (account.serial > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 8),
                    child: Text('#${account.serial}',
                        style: AppTheme.body(13.5,
                            weight: FontWeight.w800, color: AppTheme.ink)),
                  ),
                const SizedBox(height: 8),
                // A closed account has reached its term: nothing is due,
                // and showing it a due date — in the same red/amber the
                // round uses — would read as a customer to go and visit.
                // It appears in the Maturity list precisely because it has
                // FINISHED, so say that instead.
                if (account.isClosed) ...[
                  Text('Status', style: AppTheme.label(AppTheme.inkFaint)),
                  const SizedBox(height: 2),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 8),
                    child: Text('Matured',
                        style: AppTheme.body(12.5,
                            weight: FontWeight.w800, color: AppTheme.green)),
                  ),
                ] else ...[
                  Text('Due', style: AppTheme.label(AppTheme.inkFaint)),
                  const SizedBox(height: 2),
                  Text(account.dueDateLabel,
                      style: AppTheme.body(13,
                          weight: FontWeight.w700, color: dueColor)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials =
        parts.isEmpty ? '?' : parts.take(2).map((w) => w[0]).join();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: AppTheme.surfaceSoft, shape: BoxShape.circle),
      child: Text(initials.toUpperCase(),
          style: AppTheme.display(14, weight: FontWeight.w800)),
    );
  }
}
