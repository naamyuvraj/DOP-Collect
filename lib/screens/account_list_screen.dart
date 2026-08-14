import 'dart:async';

import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../data/collection_repository.dart';
import '../models/account_sort.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../widgets/account_row.dart';
import '../widgets/account_sort_bar.dart';
import 'portfolio_screen.dart';

/// Accounts list. With [filter] null it is the "All Accounts" tab (search +
/// Reset); with a [filter] it is a titled bucket list opened from a dashboard
/// "View" (e.g. Defaulters).
class AccountListScreen extends StatefulWidget {
  const AccountListScreen(
      {super.key,
      required this.repo,
      this.collections,
      this.filter,
      this.revision = 0});
  final AccountRepository repo;

  /// Ledger for each account's Khata tab.
  final CollectionRepository? collections;
  final AccountFilter? filter;

  /// Bumped by the shell whenever the data may have changed (a Sync, or simply
  /// re-entering the tab). As a tab this screen lives in an IndexedStack and is
  /// built once, so without this it would keep showing the very first query —
  /// a Sync run from Home left it stuck on "No accounts yet".
  final int revision;

  @override
  State<AccountListScreen> createState() => _AccountListScreenState();
}

class _AccountListScreenState extends State<AccountListScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Future<List<RdAccount>>? _future;
  Timer? _debounce;

  /// null = natural (repo) order; else amount/due sort.
  AccountSort? _sort;

  bool get _isTab => widget.filter == null;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant AccountListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) setState(_reload);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _future = _query.isEmpty ? widget.repo.all() : widget.repo.search(_query);
  }

  /// Debounce the SQLite search so it doesn't fire on every keystroke on a
  /// 500-row DB (the field stuttered on a budget phone).
  void _onSearchChanged(String v) {
    setState(() {}); // reflect the clear (✕) button instantly
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _query = v.trim();
        _reload();
      });
    });
  }

  List<RdAccount> _apply(List<RdAccount> all) {
    final filtered =
        widget.filter == null ? all : widget.filter!.filter(all, DateTime.now());
    if (_sort == null) return filtered;
    return [...filtered]..sort(_sort!.comparator);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.filter?.title ?? 'All Accounts')),
      body: Column(
        children: [
          if (_isTab) _searchRow(),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: AccountSortBar(
              value: _sort,
              smartLabel: 'Default',
              onChanged: (v) => setState(() => _sort = v),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<RdAccount>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = _apply(snap.data!);
                if (list.isEmpty) {
                  final msg = _query.isNotEmpty
                      ? 'No account matches "$_query".'
                      : _isTab
                          ? 'No accounts yet — Sync from the dashboard.'
                          : 'Nothing in this list right now.';
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(msg,
                          textAlign: TextAlign.center,
                          style: AppTheme.body(14, color: AppTheme.inkMuted)),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 120),
                  itemCount: list.length,
                  itemBuilder: (_, i) => AccountRow(
                    account: list[i],
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PortfolioScreen(
                          repo: widget.repo,
                          accountNumber: list[i].accountNumber,
                          collections: widget.collections,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: AppTheme.card(radius: 12),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, size: 20, color: AppTheme.inkFaint),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                style: AppTheme.body(15),
                cursorColor: AppTheme.accent,
                decoration: InputDecoration(
                  hintText: 'Search name or account number',
                  hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            if (_searchCtrl.text.isNotEmpty)
              GestureDetector(
                onTap: () => setState(() {
                  _searchCtrl.clear();
                  _query = '';
                  _reload();
                }),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close_rounded,
                      size: 20, color: AppTheme.inkMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
