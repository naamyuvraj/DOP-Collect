import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'data/account_repository.dart';
import 'data/app_settings.dart';
import 'data/collection_repository.dart';
import 'data/lot_repository.dart';
import 'screens/account_list_screen.dart';
import 'screens/collect/collect_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/home_dashboard.dart';
import 'screens/lists/saved_lists_screen.dart';
import 'screens/profile_view.dart';
import 'screens/settings_screen.dart';
import 'services/analytics.dart';
import 'services/cloud_sync.dart';
import 'theme/app_theme.dart';
import 'widgets/press.dart';
import 'widgets/product_tour.dart';

/// Width of the permanent navigation rail.
const double kDesktopRailWidth = 208;

/// The widest the content column is ever drawn. See [_MainShellState].
const double kDesktopContentWidth = 1080;

/// Bottom-nav container with a floating pill nav over a soft mint canvas.
class MainShell extends StatefulWidget {
  const MainShell(
      {super.key,
      required this.repo,
      required this.lots,
      required this.collections});
  final AccountRepository repo;
  final LotRepository lots;
  final CollectionRepository collections;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  int _dataVersion = 0;

  // The agent's own name and photo. On a handset these live in the Home
  // header, because a phone has no chrome to put them in. A desktop does — the
  // rail is on screen on every tab, so the account belongs there and Home gets
  // its full width back for the figures.
  String _agentName = '';
  Uint8List? _agentPhoto;
  StreamSubscription<SyncReport>? _syncSub;

  void _loadProfile() {
    AppSettings.agentName().then((v) {
      if (mounted) setState(() => _agentName = v);
    });
    AppSettings.profilePhoto().then((v) {
      if (!mounted) return;
      setState(() => _agentPhoto = v.isEmpty ? null : base64Decode(v));
    });
  }

  Future<void> _openProfile() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ProfileView()));
    // Either could have been edited on that screen.
    _loadProfile();
  }

  /// Two letters for the avatar when there is no photo.
  String _initials() {
    final parts = _agentName
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'A';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  /// Re-query trigger for the Collect tab. It is kept alive by the IndexedStack
  /// below, so it only re-reads the DB when this changes — on a Sync, and on
  /// every entry into the tab (a Sync can be started from Home, a list or an
  /// account detail page, none of which go through [_refreshData]).
  int _accountsRevision = 0;

  void _refreshData() => setState(() {
        _dataVersion++;
        _accountsRevision++;
      });

  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.account_balance_wallet_rounded, 'Accounts'),
    (Icons.checklist_rounded, 'Collect'),
    (Icons.receipt_long_rounded, 'Lists'),
    (Icons.settings_rounded, 'Settings'),
  ];

  // Spotlight targets for the guided tour.
  final _navKeys = List.generate(_items.length, (_) => GlobalKey());
  final _aiKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
    CloudSync.startAutoSync();
    _syncSub = CloudSync.syncStream.listen((report) {
      if (report.changedAnything && mounted) {
        _refreshData();
      }
    });
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncSub?.cancel();
    CloudSync.stopAutoSync();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      CloudSync.triggerAutoSync();
    }
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
        title: 'Collect from your round',
        // The tour is the only place the gesture is ever explained, so it has
        // to name the one this device actually has.
        body: MediaQuery.of(context).size.width >= kDesktopBreakpoint
            ? 'Your round for this month. Tick a customer off the moment they '
                'pay you — the toggle at the top decides whether that takes '
                'their daily amount or the full month. Tick again to undo, or '
                'click the row to type any other amount. The yellow card keeps '
                'a running total of the cash in your bag.'
            : 'Your round for this month. Swipe a customer to the right the '
                'moment they pay you — the toggle at the top decides whether '
                'that takes their daily amount or the full month. Swipe left '
                'to undo, or tap the row to type any other amount. The yellow '
                'card keeps a running total of the cash in your bag.',
      ),
      TourStep(
        key: _navKeys[3],
        circle: true,
        before: () => _goTab(3),
        title: 'Lists — build them',
        body: 'At month-end, build each ₹20,000 list by hand — tap "New" '
            'bottom-left, then pick the customers whose cash you are actually '
            'carrying and set how many months each one is paying.',
      ),
      TourStep(
        key: _navKeys[3],
        circle: true,
        before: () => _goTab(3),
        title: 'Lists — make them on the portal',
        body: '"Make all on portal" logs in once and creates every list in one '
            'go — it ticks the accounts, asks the portal for each one\'s rebate '
            'and default fee, pays each as one installment, then saves the '
            'official reference number back onto the list.',
      ),
      TourStep(
        key: _navKeys[3],
        circle: true,
        before: () => _goTab(3),
        title: 'Lists — Downloads tab',
        body: 'Once a list is made on the portal it moves to Downloads. Tap '
            'Preview to see the PDF, pinch to zoom, then Download to save it or '
            'Share it on WhatsApp — the real receipt for the post office.',
      ),
      TourStep(
        key: _navKeys[4],
        circle: true,
        before: () => _goTab(4),
        title: 'Sync & settings',
        body: 'Sync Collection pulls all your accounts from the portal in '
            'about a minute. Your profile, your daily-collection amount and '
            'the interest calculator live here too.',
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
          onSynced: _refreshData,
          onOpenLists: () => setState(() => _index = 3)),
      // The account book: every RD account, searchable and sortable. Distinct
      // from Collect — this is for looking someone up, that is for the round.
      AccountListScreen(
          key: ValueKey('accounts-$_dataVersion'),
          repo: widget.repo,
          collections: widget.collections,
          revision: _accountsRevision),
      CollectScreen(
          key: ValueKey('collect-$_dataVersion'),
          accounts: widget.repo,
          collections: widget.collections,
          lots: widget.lots,
          revision: _accountsRevision),
      // One "Lists" tab: saved lists plus the manual builder. Groups and Lists
      // used to be two tabs for one concept.
      SavedListsScreen(
          key: ValueKey('lists-$_dataVersion'),
          accounts: widget.repo,
          lots: widget.lots,
          collections: widget.collections),
      // Calculator moved into Settings rather than taking a sixth tab — it's a
      // reference tool used occasionally, not a daily surface like Collect.
      SettingsScreen(
          repo: widget.repo,
          collections: widget.collections,
          onSynced: _refreshData,
          onTour: runTour),
    ];

    // One shell, two sets of chrome. The pages themselves are built once above
    // and handed to whichever scaffold is appropriate — a second shell widget
    // would mean two places to add a tab to, and they would drift.
    final wide = MediaQuery.of(context).size.width >= kDesktopBreakpoint;
    // Set here, in the shell's own build, because the shell always builds
    // before its children — so by the time any card computes a decoration the
    // flag is already right, including on the very first frame and on the
    // frame after a window resize.
    AppTheme.pointerDevice = wide;
    return wide ? _desktopScaffold(pages) : _phoneScaffold(pages);
  }

  /// The handset: content edge to edge under a floating bottom bar.
  Widget _phoneScaffold(List<Widget> pages) {
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

  /// The desktop: a permanent rail on the left, content in a readable column.
  ///
  /// The content is CAPPED, not stretched. Every screen in this app is a
  /// vertical list of rows, and a row that runs the full 1,440 px of a laptop
  /// puts the customer's name at the far left and his due date at the far
  /// right with a hand's width of nothing between them — the eye has to
  /// traverse the whole screen to read one customer. Capping the column is
  /// what makes it a desktop app rather than a phone app that was resized.
  Widget _desktopScaffold(List<Widget> pages) {
    return Scaffold(
      body: Container(
        decoration: AppTheme.canvas,
        child: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sideRail(),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: kDesktopContentWidth),
                    child: IndexedStack(index: _index, children: pages),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sideRail() {
    return Container(
      width: kDesktopRailWidth,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
            right: BorderSide(color: AppTheme.cardBorder, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: AppTheme.card(
                      fill: AppTheme.black,
                      radius: 10,
                      offset: AppTheme.faceOffsetPressed),
                  child: Text('D',
                      style: AppTheme.display(15, color: AppTheme.onAccent)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('DOP Collect',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.display(15)),
                ),
              ],
            ),
          ),
          for (var i = 0; i < _items.length; i++)
            KeyedSubtree(key: _navKeys[i], child: _railItem(i)),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            // On a handset this floats over the content because there is
            // nowhere else for it. Here there is — it belongs in the rail with
            // the other destinations, not hovering over the agent's table.
            child: KeyedSubtree(key: _aiKey, child: _railAssistant()),
          ),
          Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
          _railProfile(),
        ],
      ),
    );
  }

  /// The account, parked at the foot of the rail.
  ///
  /// Bottom-left is where every desktop tool of this shape keeps it, and the
  /// reason is structural rather than fashion: the rail is the only chrome
  /// present on all five tabs, so it is the only place "who am I signed in as"
  /// can live without being duplicated onto every screen.
  Widget _railProfile() {
    return _HoverFill(
      onTap: _openProfile,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              clipBehavior: Clip.antiAlias,
              decoration:
                  BoxDecoration(color: AppTheme.black, shape: BoxShape.circle),
              child: _agentPhoto == null
                  ? Center(
                      child: Text(_initials(),
                          style: AppTheme.display(12.5,
                              weight: FontWeight.w800,
                              color: AppTheme.onAccent)))
                  : Image.memory(_agentPhoto!,
                      fit: BoxFit.cover, gaplessPlayback: true),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_agentName.isEmpty ? 'Your profile' : _agentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(13, weight: FontWeight.w700)),
                  Text('View profile',
                      maxLines: 1,
                      style:
                          AppTheme.body(11, color: AppTheme.inkFaint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: AppTheme.inkFaint),
          ],
        ),
      ),
    );
  }

  Widget _railItem(int i) {
    final active = _index == i;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: _HoverFill(
        onTap: () => _navTo(i),
        radius: 9,
        // The active tab is a flat filled block, not an extruded one. On a
        // phone every control is raised because a thumb needs to see what it
        // can push; a pointer does not, and a rail full of raised blocks is
        // the single loudest "this is a mobile app" signal on the screen.
        fill: active ? AppTheme.black : null,
        child: SizedBox(
          height: 38,
          child: Row(
            children: [
              const SizedBox(width: 11),
              Icon(_items[i].$1,
                  size: 18,
                  color: active ? AppTheme.onAccent : AppTheme.inkFaint),
              const SizedBox(width: 11),
              Expanded(
                child: Text(_items[i].$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(13,
                        weight: active ? FontWeight.w700 : FontWeight.w600,
                        color:
                            active ? AppTheme.onAccent : AppTheme.inkMuted)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _railAssistant() {
    return _HoverFill(
      onTap: _openAssistant,
      radius: 9,
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2E3A8C), Color(0xFF6D3BD6)],
      ),
      child: SizedBox(
        height: 38,
        child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text('Ask assistant',
              style: AppTheme.body(12.5,
                  weight: FontWeight.w700, color: Colors.white)),
        ],
        ),
      ),
    );
  }

  void _openAssistant() {
    unawaited(Analytics.track('screen_view', {'tab': 'assistant'}));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            AssistantScreen(repo: widget.repo, collections: widget.collections),
      ),
    );
  }

  Widget _aiAgentButton() {
    return PressFace(
      onTap: _openAssistant,
      width: 58,
      height: 58,
      // Straight down, not down-right: this face is cast on one axis, so the
      // sink has to be on the same one.
      travelDirection: const Offset(0, 1),
      decoration: (face) => BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E3A8C), Color(0xFF6D3BD6)],
        ),
        shape: BoxShape.circle,
        // Hard face, like every other pressable — the blurred halo it had
        // was the last of the glass language on this screen.
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF241E63),
              blurRadius: 0,
              offset: Offset(0, face)),
        ],
      ),
      child:
          const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 26),
    );
  }

  Widget _floatingNav() {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        // The bar itself is furniture, not a control, so it takes no face —
        // only the items inside it do. It gets the edge and the surface and
        // nothing that suggests it can be pushed.
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.cardBorder, width: 1),
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

  static const _tabNames = ['home', 'accounts', 'collect', 'lists', 'settings'];

  void _navTo(int i) {
    if (_index == i) return;
    setState(() {
      _index = i;
      // Entering Accounts or Collect always re-reads the store, so neither can
      // show a stale (or empty) list after a Sync — or a collection recorded
      // elsewhere — happened somewhere else.
      if (i == 1 || i == 2) _accountsRevision++;
    });
    unawaited(Analytics.track('screen_view', {'tab': _tabNames[i]}));
  }

  Widget _navItem(int i) {
    final active = _index == i;
    return PressFace(
      onTap: () => _navTo(i),
      // Full-height 48dp+ tap target; the visible pill sits inside it. The
      // item carries no face of its own — the pill is the only lit surface —
      // so it answers the thumb by recoiling.
      height: 52,
      rest: 0,
      pressedFace: 0,
      decoration: (_) => const BoxDecoration(),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            width: 40,
            height: 32,
            decoration: active
                ? AppTheme.card(
                    fill: AppTheme.black,
                    radius: 9,
                    offset: AppTheme.faceOffsetPressed)
                : const BoxDecoration(),
            child: Icon(_items[i].$1,
                size: 21,
                color: active ? AppTheme.onAccent : AppTheme.inkFaint),
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
    );
  }
}

/// A tappable region that answers the POINTER, not the thumb.
///
/// The app's own [PressFace] is built for a handset: every control sits on an
/// extruded face and sinks when pressed, because a thumb covers the thing it is
/// touching and needs the movement to confirm the hit. A pointer never covers
/// anything and arrives *before* the click, so on a desktop the same treatment
/// reads as a toy — it is the loudest "this is a phone app" tell in the UI.
///
/// This is the desktop counterpart: no extrusion, no bounce, a cursor change
/// and a quiet fill on hover.
class _HoverFill extends StatefulWidget {
  const _HoverFill({
    required this.child,
    required this.onTap,
    this.radius = 10,
    this.fill,
    this.gradient,
  });

  final Widget child;
  final VoidCallback onTap;
  final double radius;

  /// Painted when set, regardless of hover — the selected state.
  final Color? fill;
  final Gradient? gradient;

  @override
  State<_HoverFill> createState() => _HoverFillState();
}

class _HoverFillState extends State<_HoverFill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.fill != null || widget.gradient != null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: widget.gradient,
            color: widget.gradient != null
                ? null
                : widget.fill ??
                    (_hover
                        ? AppTheme.surfaceSoft
                        : Colors.transparent),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          // A selected item is already the loudest thing in the rail; dimming it
          // slightly on hover is the only honest way to acknowledge the pointer
          // without inventing a third state.
          foregroundDecoration: selected && _hover
              ? BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(widget.radius),
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
