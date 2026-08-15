import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database.dart';
import '../services/backup_format.dart';
import '../services/backup_service.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';

/// Back up the khata, and put it back.
///
/// The whole screen is built around one fact: this file is the only copy of the
/// ledger that exists off the phone, and the man using it may not get a second
/// chance to understand it. So the passphrase is asked for twice on the way out,
/// the file is described before it is written, and a restore shows exactly what
/// it will replace before it replaces anything.
class KhataBackupScreen extends StatefulWidget {
  const KhataBackupScreen({super.key});

  @override
  State<KhataBackupScreen> createState() => _KhataBackupScreenState();
}

class _KhataBackupScreenState extends State<KhataBackupScreen> {
  final _service = BackupService(AppDatabase.instance);
  bool _busy = false;
  int _lastBackup = 0;

  @override
  void initState() {
    super.initState();
    BackupService.lastBackupMs().then((v) {
      if (mounted) setState(() => _lastBackup = v);
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  /// How stale the newest backup is, in the words he'd use.
  String get _lastLabel {
    if (_lastBackup == 0) return 'You have never backed up.';
    final days = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(_lastBackup))
        .inDays;
    if (days == 0) return 'Last backup: today.';
    if (days == 1) return 'Last backup: yesterday.';
    return 'Last backup: $days days ago.';
  }

  bool get _stale => _lastBackup == 0 ||
      DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(_lastBackup))
              .inDays >
          7;

  // --- back up ---------------------------------------------------------------

  Future<void> _backUp() async {
    final pass = await _askNewPassphrase();
    if (pass == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final bytes = await _service.export(pass);
      final file = await _service.writeToShareable(bytes);
      if (!mounted) return;
      setState(() => _busy = false);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/octet-stream')],
        subject: 'DOP Collect khata backup',
        text: 'My DOP Collect khata backup. Keep this file safe.',
      );
      await BackupService.markBackedUp();
      final now = await BackupService.lastBackupMs();
      if (mounted) setState(() => _lastBackup = now);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Could not make the backup. $e');
    }
  }

  /// Twice, because a typo here is only discovered on the day he needs the file
  /// — and by then the ledger is gone.
  Future<String?> _askNewPassphrase() async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dctx, setLocal) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Set a password', style: AppTheme.display(17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Write this down. Without it the backup cannot be opened.',
                style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: a,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              TextField(
                controller: b,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: 'Type it again'),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: AppTheme.body(12, color: AppTheme.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final p = a.text;
                if (p.length < 4) {
                  setLocal(() => error = 'Use at least 4 characters.');
                  return;
                }
                if (p != b.text) {
                  setLocal(() => error = 'The two passwords do not match.');
                  return;
                }
                Navigator.pop(dctx, p);
              },
              child: const Text('Back up'),
            ),
          ],
        ),
      ),
    );
  }

  // --- restore ---------------------------------------------------------------

  Future<void> _restore() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty || !mounted) return;

    final f = picked.files.first;
    final bytes = f.bytes ??
        (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) {
      _snack('Could not read that file.');
      return;
    }

    final pass = await _askPassphrase(f.name);
    if (pass == null || !mounted) return;

    late final BackupPayload payload;
    try {
      payload = _service.inspect(bytes, pass);
    } on BackupError catch (e) {
      _snack(e.message);
      return;
    } catch (_) {
      _snack('That file could not be read.');
      return;
    }

    if (!mounted) return;
    // Nothing has been written yet. Show him what he is about to replace and let
    // him walk away — a restore is not undoable.
    final go = await _confirmRestore(payload);
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final report = await _service.restore(payload);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Khata restored — ${report.collections} entries.');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Restore failed, your khata is unchanged. $e');
    }
  }

  Future<String?> _askPassphrase(String fileName) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Password', style: AppTheme.display(17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName,
                style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Password for this backup'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, c.text),
              child: const Text('Open')),
        ],
      ),
    );
  }

  Future<bool?> _confirmRestore(BackupPayload payload) {
    final when = payload.takenAt;
    return showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Replace your khata?', style: AppTheme.display(17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This backup holds ${payload.collections} khata entries'
              '${when != null ? ", taken on ${when.day}-${when.month}-${when.year}" : ""}.',
              style: AppTheme.body(13.5, height: 1.4),
            ),
            const SizedBox(height: 10),
            Text(
              'Anything collected after that date will be lost.',
              style: AppTheme.body(12.5, color: AppTheme.red, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Replace')),
        ],
      ),
    );
  }

  // --- ui --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Khata backup')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: AppTheme.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your khata is only on this phone',
                      style: AppTheme.display(17, weight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                    'If the phone is lost, your collections are lost with it. '
                    'A backup is the only way to get them back.',
                    style: AppTheme.body(13,
                        color: AppTheme.inkMuted, height: 1.45),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: AppTheme.panel(
                  _stale ? AppTheme.focal : AppTheme.greenSoft,
                  radius: 12),
              child: Row(
                children: [
                  Icon(_stale ? Icons.warning_amber_rounded : Icons.check_circle,
                      size: 18,
                      color: _stale ? AppTheme.amber : AppTheme.green),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_lastLabel,
                        style: AppTheme.body(13, weight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            PushButton(
              onPressed: _busy ? null : _backUp,
              color: AppTheme.black,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Back up my khata'),
            ),
            const SizedBox(height: 10),
            Text(
              'Sends one file — keep it on WhatsApp or Drive.',
              style: AppTheme.body(12, color: AppTheme.inkFaint, height: 1.4),
            ),
            const SizedBox(height: 26),
            Text('RESTORE', style: AppTheme.label(AppTheme.inkMuted)),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _busy ? null : _restore,
              child: const Text('Restore from a backup file'),
            ),
            const SizedBox(height: 10),
            Text(
              'Puts back the khata from a backup file.',
              style: AppTheme.body(12, color: AppTheme.inkFaint, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
