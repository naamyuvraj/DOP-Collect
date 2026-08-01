import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../calc/po_calc.dart';
import '../services/analytics.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// Post Office interest calculator. Pick a scheme, type the amount, and the
/// maturity updates live — the maths lives in [PoCalc] so the screen and the
/// AI assistant always agree.
class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  SchemeSpec _spec = PoCalc.schemes.first;
  final _amount = TextEditingController();
  final _years = TextEditingController();
  final _rate = TextEditingController();

  @override
  void initState() {
    super.initState();
    _applyDefaults();
  }

  @override
  void dispose() {
    for (final c in [_amount, _years, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? _openedOn; // RD only: sets the historical (locked) rate

  void _applyDefaults() {
    _openedOn = null;
    _rate.text = _spec.rate.toString();
    _years.text = _spec.years > 0 ? _trim(_spec.years) : '';
  }

  Future<void> _pickOpenedOn() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _openedOn ?? DateTime(now.year - 2, now.month),
      firstDate: DateTime(2010),
      lastDate: now,
      helpText: 'Account opened on',
    );
    if (picked == null) return;
    setState(() {
      _openedOn = picked;
      // RD locks the rate at opening — fill it from the history table.
      _rate.text = _trim(PoCalc.rdRateOn(picked));
    });
  }

  String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  double get _amountVal => double.tryParse(_amount.text.trim()) ?? 0;
  double? get _yearsVal => double.tryParse(_years.text.trim());
  double? get _rateVal => double.tryParse(_rate.text.trim());

  CalcResult? get _result {
    if (_amountVal <= 0) return null;
    try {
      return PoCalc.compute(
        _spec.scheme,
        amount: _amountVal,
        years: _yearsVal,
        rate: _rateVal,
      );
    } catch (_) {
      return null;
    }
  }

  void _pick(SchemeSpec s) {
    setState(() {
      _spec = s;
      _applyDefaults();
    });
    unawaited(Analytics.track('calc_used', {'scheme': s.code}));
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Calculator')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 130),
        children: [
          _schemeCard(),
          const SizedBox(height: 14),
          _inputsCard(),
          const SizedBox(height: 16),
          if (res != null) _resultCard(res),
          if (res == null)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: AppTheme.card(),
              child: Text(
                'Enter the ${_spec.amountLabel.toLowerCase()} to see the '
                'maturity value.',
                style: AppTheme.body(13, color: AppTheme.inkMuted),
              ),
            ),
          const SizedBox(height: 20),
          _ratesCard(),
        ],
      ),
    );
  }

  // --- Scheme picker -------------------------------------------------------

  Widget _schemeCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SCHEME', style: AppTheme.label(AppTheme.inkMuted)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<PoScheme>(
                value: _spec.scheme,
                isExpanded: true,
                borderRadius: BorderRadius.circular(16),
                style: AppTheme.body(15, weight: FontWeight.w600),
                items: [
                  for (final s in PoCalc.schemes)
                    DropdownMenuItem(
                      value: s.scheme,
                      child: Text('${s.code} · ${s.name}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) _pick(PoCalc.spec(v));
                },
              ),
            ),
          ),
          if (_spec.note != null) ...[
            const SizedBox(height: 10),
            Text(_spec.note!,
                style: AppTheme.body(12, color: AppTheme.inkMuted, height: 1.35)),
          ],
        ],
      ),
    );
  }

  // --- Inputs --------------------------------------------------------------

  Widget _inputsCard() {
    final fixedTerm = !_spec.tenureEditable && _spec.years > 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(),
      child: Column(
        children: [
          _field(_amount, _spec.amountLabel, prefix: '₹'),
          if (_spec.scheme == PoScheme.rd) ...[
            const SizedBox(height: 12),
            _openedOnField(),
          ],
          const SizedBox(height: 14),
          if (_spec.scheme == PoScheme.kvp)
            Row(children: [
              Expanded(child: _readOnly('Term', 'till doubled')),
              const SizedBox(width: 12),
              Expanded(child: _field(_rate, 'Rate %')),
            ])
          else if (fixedTerm)
            Row(children: [
              Expanded(child: _readOnly('Term', '${_trim(_spec.years)} years')),
              const SizedBox(width: 12),
              Expanded(child: _field(_rate, 'Rate %')),
            ])
          else ...[
            // Editable term with a live ± stepper — maturity recalculates as
            // you tap, like the reference detail screen.
            _termStepper(),
            const SizedBox(height: 12),
            _field(_rate, 'Rate %'),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bolt_rounded,
                  size: 16, color: AppTheme.green),
              const SizedBox(width: 4),
              Text('Maturity updates automatically as you type',
                  style: AppTheme.body(12, color: AppTheme.inkMuted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {String? prefix}) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: (_) => setState(() {}),
      style: AppTheme.body(16, weight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTheme.body(13, color: AppTheme.inkMuted),
        prefixText: prefix,
        isDense: true,
        filled: true,
        fillColor: AppTheme.surfaceSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
    );
  }

  void _setYears(double v) {
    final clamped = v.clamp(1, 40).toDouble();
    setState(() => _years.text = _trim(clamped));
  }

  /// "Maturity Time" with a live ± stepper — every tap recalculates maturity.
  Widget _termStepper() {
    final y = _yearsVal ?? _spec.years;
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('MATURITY TIME', style: AppTheme.label(AppTheme.inkMuted)),
                const SizedBox(height: 2),
                Text('${_trim(y)} ${y == 1 ? "Year" : "Years"}',
                    style: AppTheme.body(16, weight: FontWeight.w800)),
              ],
            ),
          ),
          _stepBtn(Icons.remove, AppTheme.red, () => _setYears(y - 1)),
          const SizedBox(width: 10),
          _stepBtn(Icons.add, AppTheme.green, () => _setYears(y + 1)),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  /// RD-only: tap to set the opening date, which fills the locked historical
  /// rate. Optional — for a brand-new RD the current rate is already filled.
  Widget _openedOnField() {
    return InkWell(
      onTap: _pickOpenedOn,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
        child: Row(
          children: [
            const Icon(Icons.event_outlined,
                size: 18, color: AppTheme.inkFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      _openedOn == null
                          ? 'Date'
                          : 'Opened ${_trim(_openedOn!.day.toDouble())}-'
                              '${_openedOn!.month}-${_openedOn!.year}',
                      style: AppTheme.body(13.5, weight: FontWeight.w600)),
                  if (_openedOn != null)
                    Text('Rate locked at ${_rate.text}%',
                        style:
                            AppTheme.body(11, color: AppTheme.inkMuted)),
                ],
              ),
            ),
            if (_openedOn != null)
              GestureDetector(
                onTap: () => setState(() {
                  _openedOn = null;
                  _rate.text = _spec.rate.toString();
                }),
                child: const Icon(Icons.close, size: 18, color: AppTheme.inkFaint),
              )
            else
              Text('New RD',
                  style: AppTheme.body(11.5, color: AppTheme.inkFaint)),
          ],
        ),
      ),
    );
  }

  Widget _readOnly(String label, String value) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.body(11, color: AppTheme.inkMuted)),
          Text(value, style: AppTheme.body(14, weight: FontWeight.w700)),
        ],
      ),
    );
  }

  // --- Result --------------------------------------------------------------

  Widget _resultCard(CalcResult r) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: AppTheme.focal,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.payout == null ? 'MATURITY VALUE' : 'YOU GET BACK',
              style: AppTheme.label(AppTheme.black)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(inr(r.maturity.round()),
                style: AppTheme.display(34, weight: FontWeight.w800)),
          ),
          const Divider(height: 26, color: Color(0x33000000)),
          _row('Total deposited', inr(r.deposited.round())),
          _row('Interest earned', inr(r.interest.round())),
          for (final extra in r.rows) _row(extra.$1, extra.$2),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppTheme.body(13, color: AppTheme.black)),
            Text(value,
                style: AppTheme.body(14.5, weight: FontWeight.w800)),
          ],
        ),
      );

  // --- All rates -----------------------------------------------------------

  Widget _ratesCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('INTEREST RATES', style: AppTheme.label(AppTheme.inkMuted)),
          const SizedBox(height: 2),
          Text('w.e.f ${PoCalc.ratesEffective}',
              style: AppTheme.body(11, color: AppTheme.inkFaint)),
          const SizedBox(height: 10),
          for (final s in PoCalc.schemes)
            if (s.scheme != PoScheme.custom)
              InkWell(
                onTap: () => _pick(s),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(s.code,
                            style: AppTheme.body(13, weight: FontWeight.w800)),
                      ),
                      Expanded(
                        child: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                AppTheme.body(13, color: AppTheme.inkMuted)),
                      ),
                      Text('${s.rate}%',
                          style: AppTheme.body(13.5,
                              weight: FontWeight.w800, color: AppTheme.green)),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
