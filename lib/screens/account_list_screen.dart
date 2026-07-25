import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../widgets/account_row.dart';
import 'portfolio_screen.dart';

/// Accounts list. With [filter] null it is the "All Accounts" tab (search +
/// Reset); with a [filter] it is a titled bucket list opened from a dashboard
/// "View" (e.g. Defaulters).
class AccountListScreen extends StatefulWidget {
  const AccountListScreen({super.key, required this.repo, this.filter});
  final AccountRepository repo;
  final AccountFilter? filter;

  @override
  State<AccountListScreen> createState() => _AccountListScreenState();
}

class _AccountListScreenState extends State<AccountListScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Future<List<RdAccount>>? _future;

  bool get _isTab => widget.filter == null;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _future = _query.isEmpty ? widget.repo.all() : widget.repo.search(_query);
  }

  List<RdAccount> _apply(List<RdAccount> all) {
    if (widget.filter == null) return all;
    return widget.filter!.filter(all, DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.filter?.title ?? 'All Accounts')),
      body: Column(
        children: [
          if (_isTab) _searchRow(),
          Expanded(
            child: FutureBuilder<List<RdAccount>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = _apply(snap.data!);
                if (list.isEmpty) {
                  return Center(
                    child: Text('No accounts',
                        style: AppTheme.body(14, color: AppTheme.inkMuted)),
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
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: AppTheme.card(radius: 10),
              alignment: Alignment.center,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() {
                  _query = v;
                  _reload();
                }),
                style: AppTheme.body(15),
                cursorColor: AppTheme.accent,
                decoration: InputDecoration(
                  hintText: 'Type Here…',
                  hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => setState(() {
              _searchCtrl.clear();
              _query = '';
              _reload();
            }),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.inkMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('Reset',
                  style: AppTheme.body(14,
                      weight: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
