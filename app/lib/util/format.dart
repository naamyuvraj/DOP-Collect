import 'package:intl/intl.dart';

/// Indian-grouping currency (₹3,010,400 style used in the app screens).
final _inr = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 0,
);

String inr(num value) => _inr.format(value);

/// Plain grouped number without the symbol (e.g. for "465" counts is trivial,
/// but "3,010,400" totals use this when no ₹ is wanted).
final _grouped = NumberFormat.decimalPattern('en_IN');
String grouped(num value) => _grouped.format(value);
