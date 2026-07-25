import 'package:flutter/material.dart';

import '../models/rd_account.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// One account as a white floating card: avatar-style initial, name + account,
/// installment info on the left; due date and serial on the right.
class AccountRow extends StatelessWidget {
  const AccountRow({super.key, required this.account, this.onTap});
  final RdAccount account;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            decoration: AppTheme.card(radius: 20),
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
                          style: AppTheme.body(12, color: AppTheme.inkFaint)),
                      const SizedBox(height: 5),
                      Text(
                        '${inr(account.denominationAmount)} · ${account.monthsPaid} paid',
                        style: AppTheme.body(12.5, color: AppTheme.inkMuted),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 8),
                        child: Text('#${account.serial}',
                            style: AppTheme.body(11.5,
                                weight: FontWeight.w700, color: AppTheme.ink)),
                      ),
                    const SizedBox(height: 8),
                    Text('Due',
                        style: AppTheme.label(AppTheme.inkFaint)),
                    const SizedBox(height: 2),
                    Text(account.dueDateIso,
                        style: AppTheme.body(13,
                            weight: FontWeight.w700, color: AppTheme.red)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatar(String name) {
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
          color: AppTheme.surfaceSoft, shape: BoxShape.circle),
      child: Text(initials.toUpperCase(),
          style: AppTheme.display(14, weight: FontWeight.w800)),
    );
  }
}
