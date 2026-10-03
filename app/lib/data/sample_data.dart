import '../models/rd_account.dart';

/// Seed data mirroring the real portal columns so the dashboard is demoable
/// before a live Sync. Due dates span past (defaulter), current, and future
/// (advanced) months and both fortnights so every summary card shows non-zero
/// figures. Replaced entirely on first real Sync. Fixed dates for reproducible
/// builds.
final List<RdAccount> sampleAccounts = [
  // Defaulters (due date in the past)
  RdAccount(
    accountNumber: '020013913225',
    customerName: 'MADHU DEVI',
    denominationAmount: 3000,
    nextDueDate: DateTime(2026, 1, 25),
    monthsPaid: 54,
    serial: 12,
  ),
  RdAccount(
    accountNumber: '020020081166',
    customerName: 'GOPAL PURBEY',
    denominationAmount: 6000,
    nextDueDate: DateTime(2025, 12, 18),
    monthsPaid: 58,
    serial: 41,
  ),
  // First fortnight, current
  RdAccount(
    accountNumber: '020229533571',
    customerName: 'MAMTA DEVI',
    denominationAmount: 6000,
    nextDueDate: DateTime(2026, 7, 9),
    monthsPaid: 1,
    serial: 305,
    status: CollectionStatus.deposited,
  ),
  RdAccount(
    accountNumber: '020229536382',
    customerName: 'GOVIND KUMAR SAH',
    denominationAmount: 15000,
    nextDueDate: DateTime(2026, 7, 12),
    monthsPaid: 3,
    serial: 306,
  ),
  // Second fortnight, current
  RdAccount(
    accountNumber: '020002775442',
    customerName: 'SANTOSH SARRAF',
    denominationAmount: 10000,
    nextDueDate: DateTime(2026, 7, 30),
    monthsPaid: 66,
    serial: 8,
  ),
  RdAccount(
    accountNumber: '020002777833',
    customerName: 'BINOD KUMAR SARRAF',
    denominationAmount: 15000,
    nextDueDate: DateTime(2026, 7, 30),
    monthsPaid: 60,
    serial: 9,
    status: CollectionStatus.deposited,
  ),
  // Advanced paid (future month)
  RdAccount(
    accountNumber: '020229712045',
    customerName: 'RINKU KUMARI',
    denominationAmount: 5000,
    nextDueDate: DateTime(2026, 9, 12),
    monthsPaid: 8,
    serial: 402,
  ),
  // New account (few installments)
  RdAccount(
    accountNumber: '020180855143',
    customerName: 'ROHIT KUMAR',
    denominationAmount: 6000,
    nextDueDate: DateTime(2026, 7, 31),
    monthsPaid: 2,
    serial: 467,
  ),
];
