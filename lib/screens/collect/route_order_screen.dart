import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../models/rd_account.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';

/// Arrange the round into the order he actually walks it.
///
/// The portal hands accounts back in its own order, which has nothing to do
/// with the lanes of a village. Dragging them once into walking order turns the
/// collect sheet into a checklist he can go straight down, house after house,
/// without hunting for the next name.
class RouteOrderScreen extends StatefulWidget {
  const RouteOrderScreen(
      {super.key, required this.repo, required this.accounts});

  final AccountRepository repo;
  final List<RdAccount> accounts;

  @override
  State<RouteOrderScreen> createState() => _RouteOrderScreenState();
}

class _RouteOrderScreenState extends State<RouteOrderScreen> {
  late List<RdAccount> _order;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Start from the round as it stands: anyone already placed keeps their
    // position, the rest follow in due-date order.
    _order = [...widget.accounts]..sort((a, b) {
        final ra = a.routeOrder, rb = b.routeOrder;
        if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
        if (ra != null && rb == null) return -1;
        if (ra == null && rb != null) return 1;
        return a.nextDueDate.compareTo(b.nextDueDate);
      });
  }

  /// `onReorderItem` hands back an index already adjusted for the removed row,
  /// so it is used directly — no off-by-one correction.
  void _move(int from, int to) {
    setState(() {
      _order.insert(to, _order.removeAt(from));
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.repo.setRouteOrder({
      for (var i = 0; i < _order.length; i++) _order[i].accountNumber: i,
    });
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Leave without saving?', style: AppTheme.display(17)),
        content: Text('Your new order will be lost.',
            style: AppTheme.body(13.5, color: AppTheme.inkMuted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context); // captured before the await
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Arrange my route')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Drag each customer into the order you visit them. The collect '
                'sheet then follows your round, house by house.',
                style:
                    AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                itemCount: _order.length,
                onReorderItem: _move,
                itemBuilder: (context, i) {
                  final a = _order[i];
                  return Container(
                    key: ValueKey('route-${a.accountNumber}'),
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    decoration: AppTheme.card(radius: 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 30,
                          child: Text('${i + 1}',
                              style: AppTheme.body(13,
                                  weight: FontWeight.w800,
                                  color: AppTheme.inkFaint)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.customerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.body(14.5,
                                      weight: FontWeight.w700)),
                              Text(
                                  '${inr(a.denominationAmount)} · due '
                                  '${a.dueDateLabel}',
                                  style: AppTheme.body(11.5,
                                      color: AppTheme.inkFaint)),
                            ],
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.drag_handle_rounded,
                                color: AppTheme.inkFaint),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.black,
                minimumSize: const Size.fromHeight(52),
              ),
              child: Text(_saving ? 'Saving…' : 'Save route',
                  style: AppTheme.body(15,
                      weight: FontWeight.w800, color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}
