import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../calc/po_calc.dart';
import '../data/rd_rates_store.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';

/// Editable India Post RD rate history. RD locks its rate at opening, so this
/// table drives every account's maturity. The agent can add the new quarter's
/// rate here when India Post announces it — no app update needed.
class RdRatesScreen extends StatefulWidget {
  const RdRatesScreen({super.key});

  @override
  State<RdRatesScreen> createState() => _RdRatesScreenState();
}

class _RdRatesScreenState extends State<RdRatesScreen> {
  late List<(int, double)> _rows;
  bool _dirty = false;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _rows = List.of(PoCalc.rdRates);
  }

  String _label(int yyyymm) {
    final y = yyyymm ~/ 100;
    final m = (yyyymm % 100).clamp(1, 12);
    return '${_months[m - 1]} $y';
  }

  Future<void> _save() async {
    await RdRatesStore.save(_rows);
    if (!mounted) return;
    setState(() {
      _rows = List.of(PoCalc.rdRates);
      _dirty = false;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('RD rates saved')));
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Restore built-in rates?', style: AppTheme.display(17)),
        content: Text(
          'This discards every rate you added or edited and restores the '
          'built-in table. It changes the maturity shown for accounts.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await RdRatesStore.reset();
    if (!mounted) return;
    setState(() {
      _rows = List.of(PoCalc.rdRates);
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restored the built-in rates')));
  }

  void _editRate(int index) {
    final ctrl =
        TextEditingController(text: PoCalc.rdRates.isEmpty ? '' : '${_rows[index].$2}');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Rate from ${_label(_rows[index].$1)}',
            style: AppTheme.display(17)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: const InputDecoration(suffixText: '%'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim());
              if (v == null || v < 1 || v > 15) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Enter a rate between 1% and 15%.')));
                return;
              }
              setState(() {
                _rows[index] = (_rows[index].$1, v);
                _dirty = true;
              });
              Navigator.pop(context);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Delete this rate?', style: AppTheme.display(17)),
        content: Text(
          'Removing the ${_label(_rows[index].$1)} rate changes the maturity '
          'shown for every account opened from then on.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _rows.removeAt(index);
        _dirty = true;
      });
    }
  }

  Future<void> _addRow() async {
    final now = DateTime.now();
    var year = now.year;
    var month = ((now.month - 1) ~/ 3) * 3 + 1; // current quarter start
    final rateCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (_, setLocal) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Add a rate', style: AppTheme.display(17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Effective from the start of:',
                  style: AppTheme.body(12, color: AppTheme.inkMuted)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<int>(
                      value: month,
                      isExpanded: true,
                      items: [
                        for (var m = 1; m <= 12; m++)
                          DropdownMenuItem(value: m, child: Text(_months[m - 1])),
                      ],
                      onChanged: (v) => setLocal(() => month = v ?? month),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<int>(
                      value: year,
                      isExpanded: true,
                      items: [
                        for (var y = 2010; y <= 2030; y++)
                          DropdownMenuItem(value: y, child: Text('$y')),
                      ],
                      onChanged: (v) => setLocal(() => year = v ?? year),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: rateCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                ],
                decoration: const InputDecoration(labelText: 'Rate', suffixText: '%'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(rateCtrl.text.trim());
                if (v == null || v < 1 || v > 15) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Enter a rate between 1% and 15%.')));
                  return;
                }
                final key = year * 100 + month;
                setState(() {
                  _rows.removeWhere((r) => r.$1 == key);
                  _rows.add((key, v));
                  _rows.sort((a, b) => a.$1.compareTo(b.$1));
                  _dirty = true;
                });
                Navigator.pop(context);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmExit() async {
    if (!_dirty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Discard changes?', style: AppTheme.display(17)),
        content: Text('You edited the rates but haven\'t saved. Leave anyway?',
            style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('RD Interest Rates'),
        actions: [
          TextButton(
              onPressed: _reset,
              child: Text('Reset',
                  style: AppTheme.body(13, color: AppTheme.inkMuted))),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            color: AppTheme.blueSoft,
            child: Text(
              'RD locks its rate at opening, so this table sets each account\'s '
              'maturity. When India Post announces a new quarter\'s rate, add it '
              'here — accounts opened from that month use it automatically.',
              style: AppTheme.body(12, color: AppTheme.ink, height: 1.4),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 100),
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = _rows[_rows.length - 1 - i]; // newest first
                final idx = _rows.length - 1 - i;
                final isCurrent = idx == _rows.length - 1;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: AppTheme.card(),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Text('From ${_label(r.$1)}',
                                style: AppTheme.body(14, weight: FontWeight.w600)),
                            if (isCurrent) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration:
                                    AppTheme.panel(AppTheme.greenSoft, radius: 6),
                                child: Text('current',
                                    style: AppTheme.body(10,
                                        weight: FontWeight.w700,
                                        color: AppTheme.green)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _editRate(idx),
                        child: Text('${r.$2}%',
                            style: AppTheme.display(16,
                                weight: FontWeight.w800, color: AppTheme.accent)),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove_circle_outline,
                            color: AppTheme.red, size: 20),
                        onPressed: _rows.length > 1 ? () => _delete(idx) : null,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: _dirty ? 76 : 0),
        child: FloatingActionButton.extended(
          onPressed: _addRow,
          icon: const Icon(Icons.add),
          label: const Text('Add rate'),
        ),
      ),
      bottomNavigationBar: _dirty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PushButton(
                  color: AppTheme.black,
                  onPressed: _save,
                  child: const Text('Save rates'),
                ),
              ),
            )
          : null,
      ),
    );
  }
}
