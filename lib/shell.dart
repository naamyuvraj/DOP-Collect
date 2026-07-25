import 'package:flutter/material.dart';

import 'data/account_repository.dart';
import 'data/app_settings.dart';
import 'data/lot_repository.dart';
import 'screens/account_list_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/calculator_screen.dart';
import 'screens/home_dashboard.dart';
import 'screens/lists/batch_list_screen.dart';
import 'screens/lists/saved_lists_screen.dart';
import 'screens/settings_screen.dart';
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
    (Icons.groups_rounded, 'Groups'),
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
      await runTour();
    });
  }

  /// Switch tabs then let the new page lay out before the spotlight measures.
  Future<void> _goTab(int i) async {
    if (_index != i) setState(() => _index = i);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// The guided walkthrough. Also replayable from Settings.
  Future<void> runTour() async {
    await startProductTour(context, [
      TourStep(
        key: _navKeys[0],
        circle: true,
        before: () => _goTab(0),
        title: 'Your dashboard',
        body: 'Totals at a glance — first half, second half, defaulters and '
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
        title: 'Groups — your lots',
        body: 'Create a lot by hand (₹20,000 cap), print or share it, and use '
            '"Prepare on portal" to auto-tick those accounts on the DOP site.',
      ),
      TourStep(
        key: _navKeys[3],
        circle: true,
        before: () => _goTab(3),
        title: 'Lists — built for you',
        body: 'One tap packs every account that needs collecting into ready '
            '₹20,000 lists. Remove anyone, then save them all to Groups.',
      ),
      // --- Inside Lists: these are skipped automatically if there's nothing
      // to collect (no cards on screen).
      TourStep(
        key: BatchListScreen.summaryKey,
        before: () => _goTab(3),
        title: 'Your lists at a glance',
        body: 'How many lists were built, how many accounts they cover, and '
            'the total amount you\'ll be depositing.',
      ),
      TourStep(
        key: BatchListScreen.firstCardKey,
        before: () => _goTab(3),
        title: 'One list = one deposit',
        body: 'Each list stays under the ₹20,000 cash cap — the bar shows how '
            'full it is. Tap a list to open it and remove anyone who hasn\'t '
            'paid yet.',
      ),
      TourStep(
        key: BatchListScreen.saveKey,
        before: () => _goTab(3),
        title: 'Save them to Groups',
        body: 'Happy with the lists? Save them all in one tap. From Groups you '
            'can print, share on WhatsApp, or auto-prepare them on the portal.',
      ),
      TourStep(
        key: _navKeys[4],
        circle: true,
        before: () => _goTab(4),
        title: 'Interest calculator',
        body: 'Work out maturity for any post-office scheme — RD, TD, MIS, '
            'SCSS, NSC, KVP, PPF, Sukanya and more, with the current rates '
            'built in.',
      ),
      TourStep(
        key: _navKeys[5],
        circle: true,
        before: () => _goTab(5),
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
      HomeDashboard(key: ValueKey('home-$_dataVersion'), repo: widget.repo),
      AccountListScreen(
          key: ValueKey('accounts-$_dataVersion'), repo: widget.repo),
      SavedListsScreen(
          key: ValueKey('groups-$_dataVersion'),
          accounts: widget.repo,
          lots: widget.lots),
      BatchListScreen(
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
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const AssistantScreen(),
        ),
      ),
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
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 14),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 9),
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
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < _items.length; i++)
              KeyedSubtree(key: _navKeys[i], child: _navItem(i)),
          ],
        ),
      ),
    );
  }

  Widget _navItem(int i) {
    final active = _index == i;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _index = i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? AppTheme.black : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(_items[i].$1,
            size: 23, color: active ? Colors.white : AppTheme.inkFaint),
      ),
    );
  }
}
