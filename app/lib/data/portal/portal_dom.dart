/// The DOP agent portal's DOM, pinned to real captures.
///
/// Every selector here was read off a live page in `recon/live/` on
/// 20 Aug 2026 (Finacle, `dopagent.indiapost.gov.in`). Before this file the
/// engine guessed with substring selectors like `input[name*="GOTO_PAGE" i]`,
/// which mostly worked and failed in ways nobody could reproduce. The rule now
/// is: **exact first, substring as the fallback** — so when the portal is
/// rebuilt we get a clean miss on the exact selector and still limp along on
/// the loose one, instead of silently clicking the wrong thing.
///
/// The captures are git-ignored (they carry a real Agent ID and customer
/// names). Only selectors live here, never values — the `recon/NOTES.txt`
/// convention.
///
/// ## The screen graph
///
/// Login lands on the Dashboard, and the account list is **two** clicks away,
/// not one. The middle screen is easy to miss because it looks like a dead end:
/// it has no table and no content at all.
///
/// ```
///   AuthenticationFG            login          → 01_login__before_submit
///        │  Log in
///        ▼
///   RMDashboard                 dashboard      → 03_dashboard__after_login
///        │  #Accounts                 (submenu is NOT in the DOM yet)
///        ▼
///   AgentAccountHomePage        accountsHome   → 04_account_list__page_1
///        │  #"Agent Enquire & Update Screen"   (empty page — 0 tables)
///        ▼
///   AgentRDAccountSummaryAll    list           → 05_account_list__page_2
///           table#SummaryList, "Page 1 of 48"
/// ```
///
/// The capture filenames are wrong about this: `04_account_list__page_1` is
/// actually the empty `AgentAccountHomePage`, and `05_account_list__page_2` is
/// page **1** of the real list. Trust the `REPORTTITLE` in each file, not the
/// name it was saved under.
library;

/// Which portal screen a page of HTML is.
enum PortalScreen {
  /// The credentials + captcha page.
  login,

  /// Post-login landing (`RMDashboard`). Has `#Accounts`, no submenu.
  dashboard,

  /// `AgentAccountHomePage` — the empty screen between Accounts and the list.
  /// Reaching it means the first click landed; it is progress, not a failure.
  accountsHome,

  /// `AgentRDAccountSummaryAll` — the account table with "Page X of N".
  list,

  /// The **whole book on one page** — the portal's own print-preview of the
  /// listing, every account and every column, with no pagination at all.
  ///
  /// This is the same data the 48-page walk assembles, in a single request.
  /// Verified against a live capture: 479 of each field array, matching the
  /// walk's 476 accounts + 3 matured exactly.
  fullList,

  /// Finacle's "Your Session is Expired" interstitial.
  sessionExpired,

  /// Finacle's stale-transaction-token guard ("close this window…").
  blocked,

  /// Anything else — an error page, a detail screen, a half-painted DOM.
  unknown,
}

/// Selectors and page-text markers, all confirmed against `recon/live/`.
class PortalDom {
  PortalDom._();

  // --- Login (01_login__before_submit) ------------------------------------

  static const loginForm = 'AuthenticationFG';
  static const agentIdField = r'input[name="AuthenticationFG.USER_PRINCIPAL"]';
  static const passwordField = r'input[name="AuthenticationFG.ACCESS_CODE"]';

  /// The captcha answer box. The old code wrote to `[id*="captcha" i]`, which
  /// matches nothing on this page — the field is called VERIFICATION_CODE — and
  /// on other pages could match something unrelated.
  static const captchaField =
      r'input[name="AuthenticationFG.VERIFICATION_CODE"]';

  /// The captcha image itself. Served from `AuthenticationController`, so it
  /// has no `captcha` in its src — only this id identifies it.
  static const captchaImage = '#IMAGECAPTCHA';

  /// "Click here to Change Image" — a fresh captcha without reloading.
  static const captchaRefresh = '#TEXTIMAGE';

  static const loginButton = '#VALIDATE_RM_PLUS_CREDENTIALS_CATCHA_DISABLED, '
      r'input[name="Action.VALIDATE_RM_PLUS_CREDENTIALS_CATCHA_DISABLED"]';

  /// The on-screen keypad's buffer. `settingPinPadCtl(...)` calls
  /// `disbleTextField('AuthenticationFG.ACCESS_CODE', 'true')`, so if the agent
  /// has ever opened the keypad the real password field is left **readonly**
  /// and assigning `.value` to it silently does nothing. Check for this before
  /// blaming the Keystore for an empty password.
  static const pinPadBuffer = '#input_buffer';

  // --- Dashboard / menu (03, 04, 05) --------------------------------------

  /// Top-level "Accounts" menu. Stable across all authenticated pages.
  static const accountsMenu = '#Accounts, a[name="HREF_Accounts"]';

  /// "Agent Enquire & Update Screen". Present only **after** the Accounts menu
  /// has been opened — it is absent from the dashboard DOM entirely, so not
  /// finding it there is normal and must not be read as a failure.
  ///
  /// The id and name both contain spaces and an ampersand, so `#Agent Enquire…`
  /// is not a usable selector; go through the attribute.
  static const enquireLink = 'a[name="HREF_Agent Enquire & Update Screen"], '
      'a[id="Agent Enquire & Update Screen"], '
      'a[name*="Enquire"], a[id*="Enquire"]';

  /// Any authenticated page carries these; the login page carries none.
  static const authenticatedMarker =
      '#Accounts, a[name="HREF_Accounts"], #HREF_Logout, '
      r'input[name*="GOTO_NEXT"]';

  // --- The account list (05_account_list__page_2 = page 1 of 48) ----------

  static const listTable = 'table#SummaryList';

  /// Row cells are addressed by a stable Finacle array id rather than by
  /// column position — `HREF_CustomAgentRDAccountFG.<FIELD>_ALL_ARRAY[i]`.
  /// Reading these directly is immune to column reordering, to the "Select"
  /// checkbox column shifting, and to the header being relabelled.
  static const rowIdPrefix = 'HREF_CustomAgentRDAccountFG.';
  static const accountNumberArray = 'ACCOUNT_NUMBER_ALL_ARRAY';
  static const accountNameArray = 'ACCOUNT_NAME_ALL_ARRAY';
  static const depositAmountArray = 'DEPOSIT_AMOUNT_ALL_ARRAY';
  static const monthPaidUptoArray = 'MONTH_PAID_UPTO_ALL_ARRAY';
  static const nextDueDateArray = 'NEXT_RD_INSTALLMENT_DATE_ALL_ARRAY';

  /// CSS for every account-number anchor on the page — also the row count.
  static const rowAnchors =
      r'[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]';

  // --- Pagination ---------------------------------------------------------
  //
  // These are `<input type="Submit">`, i.e. real form posts, not links. Note
  // the capital S in `type="Submit"`: CSS attribute matching is case-sensitive
  // for `type` (it is not on HTML's case-insensitive attribute list), so
  // `input[type="submit"]` does **not** match them. Never filter on it.

  static const nextButton =
      r'input[name="Action.AgentRDActSummaryAllListing.GOTO_NEXT__"], '
      r'input[name*="GOTO_NEXT"], input[title="Next"], input[alt="Next"]';

  static const prevButton =
      r'input[name="Action.AgentRDActSummaryAllListing.GOTO_PREV__"], '
      r'input[name*="GOTO_PREV"]';

  static const gotoPageField =
      r'input[name="CustomAgentRDAccountFG.AgentRDActSummaryAllListing_REQUESTED_PAGE_NUMBER"], '
      r'input[name*="REQUESTED_PAGE_NUMBER" i]';

  static const gotoPageButton =
      r'input[name="Action.AgentRDActSummaryAllListing.GOTO_PAGE__"], '
      r'input[name*="GOTO_PAGE" i]';

  /// `<span class="paginationtxt1">Page 1 of 48</span>`.
  static const pageLabel = 'span.paginationtxt1';

  /// The "doc" icon on the listing — *"Print only main page content"*. Its href
  /// returns the ENTIRE listing in one document, which is the fastest honest
  /// way to read the book: one request instead of forty-seven Next clicks.
  ///
  /// Do not click it. Its `onclick` is
  /// `window.open(this.href, ...); return false;` — a popup the WebView will
  /// not open. Read the `href` and navigate to it directly; same request,
  /// same document, no popup.
  static const printPreviewLink =
      '#HREF_printPreview, a[name="HREFprintPreview"]';

  /// The agent's TRUE id, as the portal itself states it, on every
  /// authenticated page:
  ///
  /// ```html
  /// <input type="Hidden" name="corpId"     value="DOP">
  /// <input type="Hidden" name="cxpsUserId" value="MI8472350100005">
  /// ```
  ///
  /// `corpId.cxpsUserId` is the canonical identity. The one the agent TYPES to
  /// log in is close enough that Finacle accepts a slip — a real one-character
  /// typo logged in fine and then bound a second, duplicate account on the
  /// backend, because two spellings are two identities to a 1:1 rule. Read the
  /// id, never trust the typing.
  static const corpIdField = '#corpId';
  static const cxpsUserIdField = '#cxpsUserId';

  // --- Session ------------------------------------------------------------

  /// The keep-alive control — and a trap. It is
  /// `<input type="Submit" name="Action.Action.Action.PREVENT_SESSION_TIMEOUT__">`,
  /// so clicking it **submits the listing form and navigates the page**. Fired
  /// on a timer during a page walk it collides with the walk's own post, which
  /// is what produces Finacle's "previous click was still being processed"
  /// banner and, downstream, a killed session. Only ever click it when nothing
  /// else owns the page — see `PortalSyncEngine.keepSessionAlive`.
  static const keepAliveButton =
      r'input[name="Action.Action.Action.PREVENT_SESSION_TIMEOUT__"], '
      r'input[name*="PREVENT_SESSION_TIMEOUT" i], '
      r'input[value*="Prevent Session Timeout" i]';

  /// `<input type="Hidden" name="sessionTimeout" value="...">` — the portal's
  /// idle allowance. The July capture said 300 (five minutes); the live portal
  /// on 21 Aug 2026 said **240** (four). Read it, never assume it: it is the
  /// budget every step of a walk has to fit inside, and it has already moved
  /// once.
  static const sessionTimeoutField = '#sessionTimeout';
  static const sessionAlertField = '#sessionAlertTime';

  // --- Page-text markers --------------------------------------------------

  /// "Your Session is Expired" (06_session_expired__as_seen). Both the `<title>`
  /// and the body carry it.
  static const sessionExpiredMarkers = [
    'Session is Expired',
    'Session Expired'
  ];

  /// The recovery link on that page: "To access DOP Agent Portal Application.
  /// Please Click Here." A fresh session needs this, not a retry.
  static const relaunchUrl = 'https://dopagent.indiapost.gov.in';

  /// Finacle's stale-transaction-token guard.
  static const blockedMarkers = ['close this window', 'new browser window'];

  /// The double-post banner:
  /// "You clicked on a link or a button when your previous click was still
  /// being processed. System is considering your first request."
  ///
  /// Crucially this is **not fatal** — the portal honoured the first click and
  /// renders the correct page underneath the banner. It means "you are going
  /// too fast", so the right response is to back off and re-read, never to
  /// click again.
  static const busyMarker = 'previous click was still being processed';

  /// Rendered above the table; harmless, but it is the reason some rows come
  /// back disabled and unselectable.
  static const mobileLinkNotice =
      'link valid mobile number to the Accounts which are shown disabled';

  // --- Classification -----------------------------------------------------

  /// "Page X of N" — the only honest answer to "where am I?".
  static final pageOfRe =
      RegExp(r'Page\s+(\d+)\s+of\s+(\d+)', caseSensitive: false);

  /// "Displaying 1 - 10 of  480 results" — note the portal emits a double space
  /// before the total, so the whitespace has to be tolerant.
  static final displayingRe = RegExp(
      r'Displaying\s+(\d+)\s*-\s*(\d+)\s+of\s+(\d+)\s+results',
      caseSensitive: false);

  /// Classify a page of HTML. Order matters: the failure interstitials are
  /// checked first because a poisoned page can still carry menu markup.
  static PortalScreen classify(String html) {
    if (sessionExpiredMarkers.any(html.contains)) {
      return PortalScreen.sessionExpired;
    }
    final lower = html.toLowerCase();
    if (blockedMarkers.every(lower.contains)) return PortalScreen.blocked;
    if (html.contains('AuthenticationFG.ACCESS_CODE')) {
      return PortalScreen.login;
    }
    final hasAccountHeader =
        lower.contains('account no') || lower.contains('account name');
    if (pageOfRe.hasMatch(html) && hasAccountHeader) {
      return PortalScreen.list;
    }
    // Same table, no pager: the print-preview of the whole listing. Checked
    // after `list` so a normal page can never be mistaken for it.
    if (hasAccountHeader && html.contains('id="SummaryList"')) {
      return PortalScreen.fullList;
    }
    if (html.contains('AgentAccountHomePage')) return PortalScreen.accountsHome;
    if (html.contains('RMDashboard') || html.contains('HREF_Accounts')) {
      return PortalScreen.dashboard;
    }
    return PortalScreen.unknown;
  }

  /// True when the portal is telling us we posted while it was still working.
  static bool isBusyBanner(String html) => html.contains(busyMarker);
}
