import 'dart:async';

import 'package:flutter/material.dart';

import 'data/account_repository.dart';
import 'data/app_settings.dart';
import 'data/lot_repository.dart';
import 'screens/account_list_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/calculator_screen.dart';
import 'screens/home_dashboard.dart';
import 'screens/lists/saved_lists_screen.dart';
import 'screens/settings_screen.dart';
import 'services/analytics.dart';
import 'theme/app_theme.dart';
import 'widgets/product_tour.dart';

/// Bottom-nav container with a floating pill nav over a soft mint canvas.
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.repo, required this.lots});
  final AccountRepository repo;
  final LotRepository lots;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  int _dataVersion = 0;

  void _refreshData() => setState(() => _dataVersion++);

  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.account_balance_wallet_rounded, 'Accounts'),
    (Icons.receipt_long_rounded, 'Lists'),
    (Icons.calculate_rounded, 'Calc'),
    (Icons.settings_rounded, 'Settings'),
  ];

  // Spotlight targets for the guided tour.
  final _navKeys = List.generate(_items.length, (_) => GlobalKey());
  final _aiKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // First launch after onboarding: run the guided tour once.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await AppSettings.tourSeen()) return;
      if (!mounted) return;
      // Offer the tour — don't force a 10-step walkthrough on him the instant
      // onboarding finishes. Either choice marks it seen so it won't nag again.
      final wants = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Take a quick tour?', style: AppTheme.display(18)),
          content: Text(
            'A short walkthrough of the app — about 10 steps. You can skip it '
            'and start straight away.',
            style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.4),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Skip')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Show me')),
          ],
        ),
      );
      if (wants == true && mounted) {
        await runTour();
      } else {
        await AppSettings.setTourSeen(true);
      }
    });
  }

  /// Switch tabs then let the new page lay out before the spotlight measures.
  Future<void> _goTab(int i) async {
    if (_index != i) setState(() => _index = i);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// The guided walkthrough. Also replayable from Settings.
  Future<void> runTour() async {
    unawaited(Analytics.track('tour'));
    await startProductTour(context, [
      TourStep(
        key: _navKeys[0],
        circle: true,
        before: () => _goTab(0),
        title: 'Your dashboard',
        body: 'Your monthly book sits up top — tap the eye to show or hide the '
            'amount. Below it: this-fortnight collection, defaulters and your '
            'portfolio. Tap any "View" to open that list.',
      ),
      TourStep(
        key: _navKeys[1],
        circle: true,
        before: () => _goTab(1),
        title: 'All accounts',
        body: 'Every RD account. Search by name or number, and tap one to see '
            'its full details, maturity and deposits.',
      ),
      TourStep(
        key: _navKeys[2],
        circle: true,
        before: () => _goTab(2),
        title: 'Lists — build them',
        body: 'At month-end, auto-build your ₹20,000 lists (most valuable '
            'customers first) or make one by hand. The "New" button is bottom-'
            'left.',
      ),
      TourStep(
        key: _navKeys[2],
        circle: true,
        before: () => _goTab(2),
        title: 'Lists — make them on the portal',
        body: '"Make all on portal" logs in once and creates every list in one '
            'go — it ticks the accounts and pays each as one installment, then '
            'saves the official reference number back onto the list. Advance '
            'deposits (an account added twice) are keyed for the rebate.',
      ),
      TourStep(
        key: _navKeys[2],
        circle: true,
        before: () => _goTab(2),
        title: 'Lists — Downloads tab',
        body: 'Once a list is made on the portal it moves to Downloads. Tap '
            'Preview to see the PDF, pinch to zoom, then Download to save it or '
            'Share it on WhatsApp — the real receipt for the post office.',
      ),
      TourStep(
        key: _navKeys[3],
        circle: true,
        before: () => _goTab(3),
        title: 'Interest calculator',
        body: 'Work out maturity for any post-office scheme — RD, TD, MIS, '
            'SCSS, NSC, KVP, PPF, Sukanya and more, with the current rates '
            'built in.',
      ),
      TourStep(
        key: _navKeys[4],
        circle: true,
        before: () => _goTab(4),
        title: 'Sync & settings',
        body: 'Sync Collection pulls all your accounts from the portal in '
            'about a minute. Your profile and ASLAAS number live here too.',
      ),
      TourStep(
        key: _aiKey,
        circle: true,
        before: () => _goTab(0),
        title: 'Ask the assistant',
        body: 'Ask anything — "aaj ke defaulters", a customer\'s account, or '
            'post-office rules and interest. You can talk to it in Hindi too.',
      ),
    ]);
    await AppSettings.setTourSeen(true);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeDashboard(
          key: ValueKey('home-$_dataVersion'),
          repo: widget.repo,
          onOpenLists: () => setState(() => _index = 2)),
      AccountListScreen(
          key: ValueKey('accounts-$_dataVersion'), repo: widget.repo),
      // One "Lists" tab: saved lists + an Auto-build entry (which pushes the
      // batch builder). Groups and Lists used to be two tabs for one concept.
      SavedListsScreen(
          key: ValueKey('lists-$_dataVersion'),
          accounts: widget.repo,
          lots: widget.lots),
      const CalculatorScreen(),
      SettingsScreen(
          repo: widget.repo, onSynced: _refreshData, onTour: runTour),
    ];

    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: AppTheme.canvas,
        child: Stack(
          children: [
            IndexedStack(index: _index, children: pages),
            // Floating AI Agent button — highest layer, sitting clear above the
            // nav on the right (screen FABs are moved left to avoid collision).
            Positioned(
              right: 18,
              bottom: MediaQuery.of(context).padding.bottom + 96,
              child: KeyedSubtree(key: _aiKey, child: _aiAgentButton()),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _floatingNav(),
    );
  }

  Widget _aiAgentButton() {
    return GestureDetector(
      onTap: () {
        unawaited(Analytics.track('screen_view', {'tab': 'assistant'}));
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => AssistantScreen(repo: widget.repo),
          ),
        );
      },
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2E3A8C), Color(0xFF6D3BD6)],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            const BoxShadow(
                color: Color(0x552E2A8C), blurRadius: 20, offset: Offset(0, 10)),
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 4,
                offset: const Offset(0, 2)),
          ],
        ),
        child: const Icon(Icons.auto_awesome_rounded,
            color: Colors.white, size: 26),
      ),
    );
  }

  Widget _floatingNav() {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          // Subtle top-highlight gradient for a glossy, glowing bar.
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFFFFF), Color(0xFFF3F7F2)],
          ),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: const Color(0xCCFFFFFF), width: 1.2),
          boxShadow: const [
            // Soft green glow so the bar reads as floating + luminous.
            BoxShadow(
                color: Color(0x3321A06A),
                blurRadius: 34,
                offset: Offset(0, 16)),
            BoxShadow(
                color: Color(0x22101B12),
                blurRadius: 12,
                offset: Offset(0, 6)),
            BoxShadow(
                color: Color(0x0FFFFFFF),
                blurRadius: 0,
                offset: Offset(0, -1)),
          ],
        ),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                  child: KeyedSubtree(key: _navKeys[i], child: _navItem(i))),
          ],
        ),
      ),
    );
  }

  static const _tabNames = ['home', 'accounts', 'lists', 'calculator', 'settings'];

  void _navTo(int i) {
    if (_index == i) return;
    setState(() => _index = i);
    unawaited(Analytics.track('screen_view', {'tab': _tabNames[i]}));
  }

  Widget _navItem(int i) {
    final active = _index == i;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _navTo(i),
      child: SizedBox(
        // Full-height 48dp+ tap target; the visible pill sits inside it.
        height: 52,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: 40,
              height: 32,
              decoration: BoxDecoration(
                color: active ? AppTheme.black : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(_items[i].$1,
                  size: 21, color: active ? Colors.white : AppTheme.inkFaint),
            ),
            const SizedBox(height: 3),
            Text(_items[i].$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(11,
                    weight: active ? FontWeight.w800 : FontWeight.w600,
                    color: active ? AppTheme.black : AppTheme.inkFaint)),
          ],
        ),
      ),
    );
  }
}
