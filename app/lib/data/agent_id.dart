/// DOP (India Post) agent id parsing.
///
/// A DOP agent id from Finacle (menu HDSAMM) is:
///     MI + <SOL ID> + <5-digit sequence>      e.g. MI + 8472350100 + 00005
/// - "MI" prefix is mandatory.
/// - SOL ID = the attached post office's Service Outlet ID (branch / region).
/// - The last 5 chars are the sequential suffix.
/// - Spaces and dots are invalid inside the id.
///
/// Used to derive the SOL ID for regional analytics without any date/format
/// math elsewhere. Returns '' when the id isn't a valid DOP agent id.
class AgentId {
  /// Just the SOL ID (branch/region key), or '' if [raw] can't be parsed.
  static String solOf(String? raw) {
    final p = parse(raw);
    return p.valid ? p.solId : '';
  }

  static ParsedAgent parse(String? raw) {
    // Uppercase, trim, and peel an optional "DOP." namespace our records add.
    final core = (raw ?? '')
        .trim()
        .toUpperCase()
        .replaceFirst(RegExp(r'^DOP[\s.]*'), '');

    if (!core.startsWith('MI')) return const ParsedAgent(false);
    if (RegExp(r'[\s.]').hasMatch(core)) return const ParsedAgent(false);
    if (!RegExp(r'^MI[A-Z0-9]+$').hasMatch(core)) return const ParsedAgent(false);

    final body = core.substring(2); // SOL ID + 5-digit sequence
    if (body.length < 6) return const ParsedAgent(false);

    final seq = body.substring(body.length - 5);
    final sol = body.substring(0, body.length - 5);
    if (!RegExp(r'^\d{5}$').hasMatch(seq)) return const ParsedAgent(false);
    if (sol.isEmpty) return const ParsedAgent(false);

    return ParsedAgent(true, solId: sol, seq: seq, normalized: core);
  }
}

class ParsedAgent {
  final bool valid;
  final String solId;
  final String seq;
  final String normalized;
  const ParsedAgent(this.valid, {this.solId = '', this.seq = '', this.normalized = ''});
}
