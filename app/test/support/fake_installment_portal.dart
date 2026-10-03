import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// One row of the portal's selected-accounts / installment-entry screen.
class FakeRow {
  FakeRow({
    required this.account,
    required this.name,
    this.rebate = 0,
    this.defaultFee = 0,
    this.modified = false,
  });

  final String account;
  final String name;

  /// What the portal WOULD answer for this row once
  /// `Action.CALCULATE_REBATE` is clicked on it. Before that it says nothing —
  /// the grid shows 0.00 whether or not a fee is owed, which is the trap.
  final int rebate;
  final int defaultFee;

  bool modified;
}

/// A scriptable stand-in for the installment-entry screen, behind a real
/// [WebViewController], so the REAL `PortalSyncEngine.enterInstallments` runs
/// its actual control flow.
///
/// Modelled on `recon/portal_02_installment_entry.html`, and faithful about the
/// one behaviour that matters: **the fee only exists after CALCULATE_REBATE is
/// clicked on that row.** The grid arrays (`RD_DEFAUT_FEE_ARRAY[i]`) read 0.00
/// until then, exactly as the capture does, so a test cannot accidentally pass
/// by reading a figure the live portal would not have given.
class FakeInstallmentPortal {
  FakeInstallmentPortal(this.rows);

  final List<FakeRow> rows;

  /// Selected row index, set by the SELECTED_INDEX radio.
  int selected = -1;

  /// The selected row's rebate/default fields — blank until CALCULATE_REBATE.
  int? shownRebate;
  int? shownDefaultFee;

  /// Installments keyed per account, and which accounts were calculated.
  final Map<String, int> keyed = <String, int>{};
  final List<String> calculated = <String>[];

  /// Rotate the grid by one on every ADD_TO_LIST, the way Finacle re-renders
  /// after a row is added. Off by default.
  bool reorderOnAdd = false;

  void Function()? onNavigated;

  String _money(int v) => '${v ~/ 1000 > 0 ? '${v ~/ 1000},' : ''}'
      '${(v % 1000).toString().padLeft(v >= 1000 ? 3 : 1, '0')}.00';

  String respond(String js) {
    // Row count — "are we on the installment screen".
    if (js.contains('SELECTED_INDEX') && js.contains('length')) {
      return jsonEncode('${rows.length}');
    }
    // Select a row. Selecting always clears the calculated fields: they belong
    // to whichever row is selected now, not the last one.
    if (js.contains('SELECTED_INDEX')) {
      final m = RegExp(r'value="(\d+)"').firstMatch(js);
      selected = int.tryParse(m?.group(1) ?? '') ?? -1;
      shownRebate = null;
      shownDefaultFee = null;
      onNavigated?.call();
      return jsonEncode(selected >= 0 ? 'true' : 'false');
    }
    // Which row is this account on?
    if (js.contains('var want=')) {
      final want = RegExp(r'var want="(\d+)"').firstMatch(js)?.group(1);
      final i = rows.indexWhere((r) => r.account == want);
      return jsonEncode('$i');
    }
    // First target row not yet Modified=YES.
    if (js.contains('var targets=') && js.contains('MODIFIED_ARRAY')) {
      final raw = RegExp(r'var targets=(\[.*?\]);').firstMatch(js);
      final targets = raw == null
          ? const <String>[]
          : (jsonDecode(raw.group(1)!) as List).cast<String>();
      if (js.contains('var c=0')) {
        return jsonEncode('${rows.where((r) => targets.contains(r.account) && r.modified).length}');
      }
      final i = rows.indexWhere((r) => targets.contains(r.account) && !r.modified);
      return jsonEncode('$i');
    }
    // Every account on the screen.
    if (js.contains('ACCOUNT_NUMBER_ARRAY[') && js.contains('JSON.stringify')) {
      return jsonEncode(jsonEncode([for (final r in rows) r.account]));
    }
    // One row's account number.
    final rowAcct = RegExp(r'ACCOUNT_NUMBER_ARRAY\[(\d+)\]').firstMatch(js);
    if (rowAcct != null && !js.contains('JSON.stringify')) {
      final i = int.parse(rowAcct.group(1)!);
      return jsonEncode(i >= 0 && i < rows.length ? rows[i].account : '');
    }
    // The SELECTED row's fields — empty until CALCULATE_REBATE has run.
    if (js.contains('CustomAgentRDAccountFG.REBATE')) {
      return jsonEncode(shownRebate == null ? '' : _money(shownRebate!));
    }
    if (js.contains('CustomAgentRDAccountFG.DEFAULT_FEE')) {
      return jsonEncode(shownDefaultFee == null ? '' : _money(shownDefaultFee!));
    }
    // The grid arrays. 0.00 on an unkeyed row — the stale placeholder that made
    // "just read the grid" look like it worked.
    final grid =
        RegExp(r'(RD_REBATE_ARRAY|RD_DEFAUT_FEE_ARRAY)\[(\d+)\]').firstMatch(js);
    if (grid != null) {
      final i = int.parse(grid.group(2)!);
      if (i < 0 || i >= rows.length) return jsonEncode('');
      final r = rows[i];
      final v = !r.modified
          ? 0
          : grid.group(1) == 'RD_REBATE_ARRAY'
              ? r.rebate
              : r.defaultFee;
      return jsonEncode(_money(v));
    }
    if (js.contains('Action.CALCULATE_REBATE')) {
      if (selected < 0) return jsonEncode('false');
      final r = rows[selected];
      shownRebate = r.rebate;
      shownDefaultFee = r.defaultFee;
      calculated.add(r.account);
      onNavigated?.call();
      return jsonEncode('true');
    }
    if (js.contains('Action.ADD_TO_LIST')) {
      if (selected < 0) return jsonEncode('false');
      rows[selected].modified = true;
      if (reorderOnAdd) {
        final moved = rows.removeAt(0);
        rows.add(moved);
        selected = rows.indexOf(moved);
      }
      onNavigated?.call();
      return jsonEncode('true');
    }
    // Session-expired probe and anything else: a plain page with no markers.
    if (js.contains('outerHTML')) {
      return jsonEncode('<html><body>installment entry</body></html>');
    }
    return jsonEncode('false');
  }

  /// The installments typed into the selected row, captured from the fire-and-
  /// forget `runJavaScript` call.
  void note(String js) {
    final m =
        RegExp(r"RD_INSTALLMENT_NO', '(\d+)'").firstMatch(js);
    if (m != null && selected >= 0) {
      keyed[rows[selected].account] = int.parse(m.group(1)!);
    }
  }
}

class FakeInstallmentPlatform extends WebViewPlatform {
  FakeInstallmentPlatform(this.portal);
  final FakeInstallmentPortal portal;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      _Controller(params, portal);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params, this.portal) : super.implementation();
  final FakeInstallmentPortal portal;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      portal.respond(javaScript);

  @override
  Future<void> runJavaScript(String javaScript) async => portal.note(javaScript);
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {}
}
