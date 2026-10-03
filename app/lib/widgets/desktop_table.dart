import 'package:flutter/material.dart';

import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// The account book as a table, for a screen with room for one.
///
/// WHY NOT THE CARD ROW
/// --------------------
/// [AccountRow] stacks a customer's five facts vertically because a phone is
/// 360 px wide and there is nowhere else to put them. Given a desktop that
/// stacking becomes the problem: eight customers fill the window, so comparing
/// who is furthest behind means scrolling and remembering. A table puts forty
/// on screen and lines the figures up in a column, which is the only way the
/// eye can compare them without reading each one.
///
/// Columns are flex, not fixed, so the table fills whatever width the shell
/// gives it and still holds its alignment at 900 px and at 1080.
class DesktopAccountTable extends StatelessWidget {
  const DesktopAccountTable({
    super.key,
    required this.accounts,
    required this.onOpen,
    this.padding = const EdgeInsets.fromLTRB(0, 4, 0, 40),
  });

  final List<RdAccount> accounts;
  final void Function(RdAccount) onOpen;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _HeaderRow(),
        Expanded(
          child: ListView.builder(
            padding: padding,
            itemCount: accounts.length,
            itemBuilder: (_, i) => _DataRow(
              account: accounts[i],
              now: now,
              // Zebra striping, not a divider per row. At forty rows a line
              // under each one is forty pieces of furniture competing with the
              // numbers; a barely-there tint on alternate rows does the same
              // job of keeping the eye on one customer across seven columns.
              tinted: i.isOdd,
              onTap: () => onOpen(accounts[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Column widths, in one place so the header and every row cannot drift apart.
class _Cols {
  static const double code = 64;
  static const int name = 5;
  static const int number = 4;
  static const int installment = 3;
  static const double paid = 62;
  static const int due = 3;
  static const double status = 104;
}

const _rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 11);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.body(11.5,
        weight: FontWeight.w800, color: AppTheme.inkFaint);
    return Container(
      padding: _rowPadding,
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppTheme.cardBorder, width: 1)),
      ),
      child: Row(
        children: [
          SizedBox(width: _Cols.code, child: Text('#', style: style)),
          Expanded(flex: _Cols.name, child: Text('CUSTOMER', style: style)),
          Expanded(flex: _Cols.number, child: Text('ACCOUNT NO', style: style)),
          Expanded(
            flex: _Cols.installment,
            child: Text('INSTALLMENT', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _Cols.paid,
            child: Text('PAID', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 12),
          Expanded(flex: _Cols.due, child: Text('NEXT DUE', style: style)),
          SizedBox(width: _Cols.status, child: Text('STANDING', style: style)),
        ],
      ),
    );
  }
}

class _DataRow extends StatefulWidget {
  const _DataRow({
    required this.account,
    required this.now,
    required this.tinted,
    required this.onTap,
  });

  final RdAccount account;
  final DateTime now;
  final bool tinted;
  final VoidCallback onTap;

  @override
  State<_DataRow> createState() => _DataRowState();
}

class _DataRowState extends State<_DataRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final behind = AccountFilter.monthsBehind(a, widget.now);
    final (label, color) = _standing(behind);

    return MouseRegion(
      // A desktop row has to answer the pointer before it is clicked —
      // otherwise nothing on the page looks clickable and the agent hunts for
      // a button that is not there.
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: _rowPadding,
          decoration: BoxDecoration(
            color: _hover
                ? AppTheme.surface
                : widget.tinted
                    ? AppTheme.surface.withValues(alpha: 0.45)
                    : Colors.transparent,
            border: Border(
              // The hover state is carried by a left edge as well as the fill:
              // a fill alone is a very small contrast step on this dark canvas,
              // and the edge is what actually reads.
              left: BorderSide(
                  color: _hover ? color : Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: _Cols.code,
                child: Text(a.serial > 0 ? '#${a.serial}' : '—',
                    style: AppTheme.body(12.5,
                        weight: FontWeight.w800, color: AppTheme.inkFaint)),
              ),
              Expanded(
                flex: _Cols.name,
                child: Text(a.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(13.5, weight: FontWeight.w700)),
              ),
              Expanded(
                flex: _Cols.number,
                child: Text(a.accountNumber,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
              ),
              Expanded(
                flex: _Cols.installment,
                child: Text(inr(a.denominationAmount),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(13.5, weight: FontWeight.w700)),
              ),
              SizedBox(
                width: _Cols.paid,
                child: Text('${a.monthsPaid}',
                    textAlign: TextAlign.right,
                    style: AppTheme.body(13, color: AppTheme.inkMuted)),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: _Cols.due,
                child: Text(a.dueDateLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
              ),
              SizedBox(
                width: _Cols.status,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StandingChip(label: label, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Standing in words, from the portal's own next-due date.
  ///
  /// The same thresholds as the dashboard buckets, so a row that reads
  /// "3 mo late" here is one of the customers the Defaulters tile counted.
  (String, Color) _standing(int behind) {
    if (behind >= 6) return ('$behind mo late', AppTheme.red);
    if (behind >= 1) {
      return ('$behind mo late', AppTheme.amber);
    }
    if (behind == 0) return ('Due now', AppTheme.inkMuted);
    return ('Advance', AppTheme.green);
  }
}

class _StandingChip extends StatelessWidget {
  const _StandingChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Dot plus words, never the colour alone — this has to survive a
        // printout and a reader who cannot separate the red from the amber.
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.body(12,
                  weight: FontWeight.w700, color: AppTheme.inkMuted)),
        ),
      ],
    );
  }
}
