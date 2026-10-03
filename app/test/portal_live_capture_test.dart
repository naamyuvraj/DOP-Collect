import 'dart:io';

import 'package:dop_collect/data/portal/agent_list_parser.dart';
import 'package:dop_collect/data/portal/portal_dom.dart';
import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks the parser and the screen classifier against **real portal pages**.
///
/// The captures live in `recon/live/` and are git-ignored — they carry a real
/// Agent ID, customer names and account numbers. So this suite reads them if
/// they are on the machine and skips itself if they are not; it must never
/// assert on a value out of them, only on shape and counts.
///
/// Re-capture with `recon/live/capture.js` (desktop browser console) or the
/// `</>` button on the sync screen. Note the files are misnamed: `04_…page_1`
/// is the empty `AgentAccountHomePage` and `05_…page_2` is page 1 of the list.
void main() {
  File f(String name) => File('recon/live/$name.html');
  String? read(String name) =>
      f(name).existsSync() ? f(name).readAsStringSync() : null;

  final login = read('01_login__before_submit');
  final dashboard = read('03_dashboard__after_login');
  final accountsHome = read('04_account_list__page_1');
  final list = read('05_account_list__page_2');
  final expired = read('06_session_expired__as_seen');

  final haveAll = [login, dashboard, accountsHome, list, expired]
      .every((s) => s != null && s.trim().isNotEmpty);

  group('screen classification', () {
    test('each capture is recognised as the screen it actually is', () {
      expect(PortalDom.classify(login!), PortalScreen.login);
      expect(PortalDom.classify(dashboard!), PortalScreen.dashboard);
      // The one that used to be mistaken for a failed click. It has no table
      // and no content, but it is real progress towards the list.
      expect(PortalDom.classify(accountsHome!), PortalScreen.accountsHome);
      expect(PortalDom.classify(list!), PortalScreen.list);
      expect(PortalDom.classify(expired!), PortalScreen.sessionExpired);
    });

    test('a healthy list page is not mistaken for an expired session', () {
      // The live page says "Prevent Session Timeout" and "session will timeout
      // in", neither of which may trip the expiry markers.
      expect(list!.contains('Prevent Session Timeout'), isTrue);
      expect(PortalDom.classify(list), isNot(PortalScreen.sessionExpired));
    });

    test('the expired page offers a relaunch URL, not a retry', () {
      expect(expired!.contains(PortalDom.relaunchUrl), isTrue);
    });
  }, skip: haveAll ? false : 'recon/live/ captures not present');

  group('pagination controls', () {
    test('page number and total are read off the portal label', () {
      expect(PortalSyncEngine.currentPage(list!), 1);
      expect(PortalSyncEngine.totalPages(list), greaterThan(1));
    });

    test('the portal advertises a book size we can cross-check against', () {
      final advertised = PortalSyncEngine.advertisedTotal(list!);
      final pages = PortalSyncEngine.totalPages(list);
      expect(advertised, greaterThan(0));
      // 48 pages x 10 rows == 480. Allow the last page to be short.
      expect(advertised, lessThanOrEqualTo(pages * 10));
      expect(advertised, greaterThan((pages - 1) * 10));
    });

    test('Next is present and enabled on page 1, Previous is disabled', () {
      // These are `type="Submit"`, capital S. Asserted here because filtering
      // on [type="submit"] would silently match nothing.
      expect(list!.contains('GOTO_NEXT__'), isTrue);
      expect(RegExp(r'GOTO_PREV__[^>]*disabled').hasMatch(list), isTrue);
      expect(list.contains('type="Submit"'), isTrue);
    });
  }, skip: haveAll ? false : 'recon/live/ captures not present');

  group('account list parsing', () {
    test('reads a full page of rows off the real markup', () {
      final page = AgentListParser.parse(list!);
      expect(page.rows, 10, reason: 'the portal puts 10 rows on a page');
      expect(page.isEmpty, isFalse);
      expect(page.rejected, 0,
          reason: 'nothing on a healthy page should fail to parse');
    });

    test('accounts carry a number, a name, a denomination and a due date', () {
      final page = AgentListParser.parse(list!);
      expect(page.accounts, isNotEmpty);
      for (final a in page.accounts) {
        expect(a.accountNumber.length, greaterThanOrEqualTo(9));
        expect(a.customerName, isNotEmpty);
        expect(a.denominationAmount, greaterThan(0));
        expect(a.monthsPaid, greaterThan(0));
      }
    });

    test('a blank due date counts as matured, never as a parse failure', () {
      final page = AgentListParser.parse(list!);
      // The real capture has rows at 60 months with an empty due-date cell.
      // They used to be counted as `rejected`, which made an ordinary month of
      // maturities look like the table had gone bad.
      expect(page.matured, greaterThan(0));
      expect(page.rejected, 0);
      expect(page.accounts.length + page.matured, page.rows);
    });

    test('the empty AgentAccountHomePage yields nothing, and says so', () {
      final page = AgentListParser.parse(accountsHome!);
      expect(page.isEmpty, isTrue);
    });

    test('the structured reader and the table reader agree', () {
      // _parseByRowIds is preferred, but the column-position path is the
      // fallback for the day Finacle's ids change — they must not disagree.
      final structured = AgentListParser.parse(list!);
      final stripped = list.replaceAll('HREF_CustomAgentRDAccountFG.', 'X_');
      final table = AgentListParser.parse(stripped);
      expect(table.rows, structured.rows);
      expect(table.accounts.length, structured.accounts.length);
      expect(table.matured, structured.matured);
      expect(
        table.accounts.map((a) => a.accountNumber).toSet(),
        structured.accounts.map((a) => a.accountNumber).toSet(),
      );
    });
  }, skip: haveAll ? false : 'recon/live/ captures not present');

  group('the busy banner', () {
    test('is detected on the capture that carries it', () {
      // "You clicked on a link or a button when your previous click was still
      // being processed." It is NOT fatal — the page underneath is the right
      // one — so the engine must recognise it in order to back off instead of
      // clicking again.
      expect(PortalDom.isBusyBanner(list!), isTrue);
      expect(PortalDom.classify(list), PortalScreen.list,
          reason: 'the banner must not stop the page being read');
      expect(AgentListParser.parse(list).rows, 10);
    });
  }, skip: haveAll ? false : 'recon/live/ captures not present');

  group('keep-alive', () {
    test('the control is a form submit, so clicking it navigates', () {
      // The reason keep-alive may not fire during a walk.
      expect(
        RegExp(r'type="Submit"[^>]*PREVENT_SESSION_TIMEOUT').hasMatch(list!),
        isTrue,
      );
    });

    test('the portal allows five minutes of idle', () {
      expect(RegExp(r'name="sessionTimeout"[^>]*value="300"').hasMatch(list!),
          isTrue);
    });
  }, skip: haveAll ? false : 'recon/live/ captures not present');
}
