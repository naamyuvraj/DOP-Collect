import 'package:dop_collect/calc/po_calc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lump-sum schemes', () {
    test('TD compounds quarterly', () {
      // 100000 @ 7.5% for 5y, quarterly: 100000*(1+.075/4)^20 ≈ 145,000
      final r = PoCalc.compute(PoScheme.td5, amount: 100000);
      expect(r.deposited, 100000);
      expect(r.maturity, closeTo(144995, 500));
      expect(r.interest, closeTo(r.maturity - 100000, 1));
    });

    test('NSC compounds annually over 5 years', () {
      // 100000*(1.077)^5 ≈ 144,900
      final r = PoCalc.compute(PoScheme.nsc, amount: 100000);
      expect(r.maturity, closeTo(144903, 500));
    });

    test('KVP doubles the deposit', () {
      final r = PoCalc.compute(PoScheme.kvp, amount: 50000);
      expect(r.maturity, 100000);
      expect(r.interest, 50000);
      // At 7.5% doubling takes ~115 months.
      expect(r.rows.first.$2, contains('9 yr'));
    });

    test('MSSC: 2 years quarterly at 7.5%', () {
      final r = PoCalc.compute(PoScheme.mssc, amount: 200000);
      expect(r.maturity, closeTo(232044, 500));
    });
  });

  group('payout schemes return principal', () {
    test('MIS pays monthly, principal returned', () {
      // 900000 @ 7.4% -> 5550/month
      final r = PoCalc.compute(PoScheme.mis, amount: 900000);
      expect(r.maturity, 900000);
      expect(r.payout, 'Monthly income');
      expect(r.interest, closeTo(5550 * 60, 1));
    });

    test('SCSS pays quarterly', () {
      // 1000000 @ 8.2% -> 20500/quarter
      final r = PoCalc.compute(PoScheme.scss, amount: 1000000);
      expect(r.maturity, 1000000);
      expect(r.interest, closeTo(20500 * 20, 1));
    });
  });

  group('recurring deposit', () {
    test('RD matches the India Post quarterly-compounding formula', () {
      // 5000/month @ 6.7% for 5 years -> ~3.56 lakh on 3.00 lakh deposited
      final r = PoCalc.compute(PoScheme.rd, amount: 5000);
      expect(r.deposited, 300000);
      expect(r.maturity, greaterThan(350000));
      expect(r.maturity, lessThan(365000));
      expect(r.interest, r.maturity - r.deposited);
    });

    test('a longer term earns strictly more', () {
      final five = PoCalc.compute(PoScheme.rd, amount: 2000);
      final ten = PoCalc.compute(PoScheme.rd, amount: 2000, years: 10);
      expect(ten.maturity, greaterThan(five.maturity));
    });
  });

  group('yearly-deposit schemes', () {
    test('PPF 15 years of 150000 @ 7.1%', () {
      final r = PoCalc.compute(PoScheme.ppf, amount: 150000);
      expect(r.deposited, 150000 * 15);
      expect(r.maturity, greaterThan(4000000)); // ~40.6 lakh
      expect(r.maturity, lessThan(4200000));
    });

    test('SSA deposits 15y then grows to 21y', () {
      final r = PoCalc.compute(PoScheme.ssa, amount: 150000);
      expect(r.deposited, 150000 * 15); // only 15 years of deposits
      // Keeps compounding for 6 more years, so beats a plain 15-year run.
      final at15 = PoCalc.compute(PoScheme.ppf, amount: 150000, rate: 8.2);
      expect(r.maturity, greaterThan(at15.maturity));
    });
  });

  test('rate override is honoured', () {
    final a = PoCalc.compute(PoScheme.td5, amount: 100000, rate: 0);
    expect(a.maturity, closeTo(100000, 0.01));
    expect(a.interest, closeTo(0, 0.01));
  });

  group('scheme lookup', () {
    test('finds by code, name and alias', () {
      expect(PoCalc.byName('rd')?.scheme, PoScheme.rd);
      expect(PoCalc.byName('MIS')?.scheme, PoScheme.mis);
      expect(PoCalc.byName('sukanya')?.scheme, PoScheme.ssa);
      expect(PoCalc.byName('senior citizen')?.scheme, PoScheme.scss);
      expect(PoCalc.byName('kisan vikas')?.scheme, PoScheme.kvp);
      expect(PoCalc.byName('nonsense zzz'), isNull);
    });
  });

  group('historical RD rate (locked at opening)', () {
    test('picks the rate in effect on the opening date', () {
      expect(PoCalc.rdRateOn(DateTime(2018, 11, 2)), 7.3); // real account
      expect(PoCalc.rdRateOn(DateTime(2020, 6, 1)), 5.8); // covid-era low
      expect(PoCalc.rdRateOn(DateTime(2023, 8, 1)), 6.5);
      expect(PoCalc.rdRateOn(DateTime(2026, 7, 1)), 6.7); // current
    });

    test('boundary months switch exactly', () {
      expect(PoCalc.rdRateOn(DateTime(2018, 9, 30)), 6.9);
      expect(PoCalc.rdRateOn(DateTime(2018, 10, 1)), 7.3);
      expect(PoCalc.rdRateOn(DateTime(2020, 3, 31)), 7.2);
      expect(PoCalc.rdRateOn(DateTime(2020, 4, 1)), 5.8);
    });

    test('dates before the table use the earliest known rate', () {
      expect(PoCalc.rdRateOn(DateTime(2010, 1, 1)), 7.4);
    });

    test('current rate is the latest table entry', () {
      expect(PoCalc.rdCurrentRate, 6.7);
    });

    test('table is editable at runtime (add a new quarter)', () {
      try {
        PoCalc.setRdRates([
          ...PoCalc.defaultRdRateHistory,
          (202610, 7.0), // hypothetical Oct-2026 revision
        ]);
        expect(PoCalc.rdRateOn(DateTime(2026, 11, 1)), 7.0);
        expect(PoCalc.rdCurrentRate, 7.0);
        // Older dates are unaffected.
        expect(PoCalc.rdRateOn(DateTime(2018, 11, 2)), 7.3);
      } finally {
        PoCalc.resetRdRates(); // don't leak into other tests
      }
      expect(PoCalc.rdCurrentRate, 6.7);
    });

    test('invalid rows are dropped; empty falls back to built-in', () {
      PoCalc.setRdRates([(0, -1)]);
      expect(PoCalc.rdRates, PoCalc.defaultRdRateHistory);
      PoCalc.resetRdRates();
    });
  });

  test('RD advance-deposit rebate', () {
    expect(PoCalc.rdRebate(denomination: 1000, advance: 12), 100);
    expect(PoCalc.rdRebate(denomination: 1000, advance: 6), 40);
    expect(PoCalc.rdRebate(denomination: 1000, advance: 3), 0);
  });
}
