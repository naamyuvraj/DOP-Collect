/// Making sense of what the microphone actually returns.
///
/// Everything else in the assistant assumes tidy text. Dictation is not tidy:
/// it arrives without punctuation, in whichever script the recogniser felt like
/// using, with amounts sometimes as digits and sometimes as words, and with
/// names spelled however the model heard them. This file is the one place that
/// knows about that mess, so the parser and the intent engine can stay simple.
///
/// All of it is pure and offline — the same requirement as the rest of the
/// collect path, because it runs at a doorstep with no signal.
class SpeechText {
  // --- Normalisation -------------------------------------------------------

  static final _devDigits = RegExp(r'[०-९]');
  static const _devDigitBase = 0x0966; // '०'

  /// Lowercase, ASCII digits, no punctuation, single spaces.
  ///
  /// Devanagari **letters** are deliberately preserved — the intent engine
  /// matches Hindi keywords directly, and transliterating here would break
  /// them. Only the digits are converted, since ५०० and 500 are the same
  /// number and nothing downstream should have to know that.
  static String normalize(String raw) {
    final digits = raw.replaceAllMapped(
        _devDigits, (m) => '${m.group(0)!.codeUnitAt(0) - _devDigitBase}');
    return digits
        .toLowerCase()
        // Join a grouped figure BEFORE punctuation is blanked, so "1,000"
        // becomes 1000 rather than a 1 followed by a stray 000 — which read as
        // ₹1 and would have put the wrong amount on a confirmation card. Any
        // comma between two digits goes, which also handles Indian grouping
        // (1,50,000) where the groups are not all three long.
        .replaceAll(RegExp(r'(?<=\d),(?=\d)'), '')
        // Keep letters (both scripts), digits and spaces; a rupee sign carries
        // no meaning once the figure is parsed.
        .replaceAll(RegExp(r'[^a-z0-9ऀ-ॿ\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // --- Amounts -------------------------------------------------------------

  /// Digits, after [normalize] has already joined any grouping.
  static final _digitAmount = RegExp(r'(\d+)');

  static const _units = <String, double>{
    'zero': 0, 'ek': 1, 'one': 1, 'do': 2, 'two': 2, 'teen': 3, 'tin': 3,
    'three': 3, 'char': 4, 'chaar': 4, 'four': 4, 'panch': 5, 'paanch': 5,
    'panj': 5, 'five': 5, 'chah': 6, 'chhah': 6, 'chhe': 6, 'che': 6, 'six': 6,
    'saat': 7, 'sat': 7, 'seven': 7, 'aath': 8, 'ath': 8, 'eight': 8,
    'nau': 9, 'nine': 9, 'das': 10, 'dus': 10, 'ten': 10,
    'gyarah': 11, 'eleven': 11, 'barah': 12, 'twelve': 12, 'terah': 13,
    'thirteen': 13, 'chaudah': 14, 'fourteen': 14, 'pandrah': 15, 'fifteen': 15,
    'solah': 16, 'sixteen': 16, 'satrah': 17, 'seventeen': 17,
    'atharah': 18, 'eighteen': 18, 'unnis': 19, 'nineteen': 19,
    'bees': 20, 'bis': 20, 'twenty': 20, 'tees': 30, 'tis': 30, 'thirty': 30,
    'chalis': 40, 'chaalis': 40, 'forty': 40, 'pachas': 50, 'pachaas': 50,
    'pachhas': 50, 'fifty': 50, 'saath': 60, 'sixty': 60, 'sattar': 70,
    'seventy': 70, 'assi': 80, 'eighty': 80, 'nabbe': 90, 'ninety': 90,
    // Devanagari
    'एक': 1, 'दो': 2, 'तीन': 3, 'चार': 4, 'पांच': 5, 'पाँच': 5, 'छह': 6,
    'छे': 6, 'सात': 7, 'आठ': 8, 'नौ': 9, 'दस': 10, 'बीस': 20, 'तीस': 30,
    'चालीस': 40, 'पचास': 50, 'साठ': 60, 'सत्तर': 70, 'अस्सी': 80, 'नब्बे': 90,
  };

  static const _multipliers = <String, int>{
    'sau': 100, 'so': 100, 'hundred': 100,
    'hazar': 1000, 'hazaar': 1000, 'hajar': 1000, 'hajaar': 1000,
    'thousand': 1000, 'k': 1000,
    'lakh': 100000, 'lac': 100000, 'lakhs': 100000,
    'सौ': 100, 'हज़ार': 1000, 'हजार': 1000, 'लाख': 100000,
  };

  /// Words that adjust the number after them — the way amounts are actually
  /// said aloud in Hindi. "dhai sau" is 250, not two-hundred-and-a-half, and an
  /// agent asked for ₹150 will say "dedh sau" far more often than "ek sau
  /// pachas".
  static const _standalone = <String, double>{
    'dedh': 1.5, 'derh': 1.5, 'डेढ़': 1.5, 'डेढ': 1.5,
    'dhai': 2.5, 'ढाई': 2.5,
  };
  static const _modifiers = <String, double>{
    'sava': 0.25, 'sawa': 0.25, 'सवा': 0.25,
    'sadhe': 0.5, 'saadhe': 0.5, 'sade': 0.5, 'साढ़े': 0.5, 'साढे': 0.5,
    'paune': -0.25, 'pone': -0.25, 'पौने': -0.25,
  };

  /// Words that mean rupees, skipped rather than treated as a quantity.
  static const _currency = {
    'rupaye', 'rupay', 'rupaya', 'rupee', 'rupees', 'rs', 'rupiya',
    'रुपये', 'रुपए', 'रुपया',
  };

  /// The amount in [text], as rupees, or null if there isn't one.
  ///
  /// Digits win when present — someone who says "500" means 500. Otherwise the
  /// words are parsed, which matters more than it looks: a spoken "paanch sau"
  /// that returned null used to fall through to the customer's daily amount,
  /// so the card would offer ₹34 when he had just been handed ₹500.
  static int? amountIn(String text) {
    final q = normalize(text);
    final digits = _digitAmount.firstMatch(q);
    if (digits != null) {
      final v = int.tryParse(digits.group(1)!);
      if (v != null && v > 0) return v;
    }
    return _spokenAmount(q.split(' '));
  }

  /// True when the text contains number words we could not turn into a figure.
  ///
  /// The caller uses this to refuse to guess: if he clearly said a quantity and
  /// we did not understand it, proposing a default amount would be putting
  /// words in his mouth about money.
  static bool hasUnparsedNumber(String text) {
    final q = normalize(text);
    if (amountIn(q) != null) return false;
    return q.split(' ').any((w) =>
        _units.containsKey(w) ||
        _multipliers.containsKey(w) ||
        _standalone.containsKey(w) ||
        _modifiers.containsKey(w));
  }

  static int? _spokenAmount(List<String> words) {
    var total = 0.0;
    var current = 0.0;
    var pending = 0.0; // from sava / sadhe / paune, applied to the next number
    var seen = false;

    void closeCurrent() {
      if (pending != 0) {
        // "sadhe" with nothing after it — treat the half on its own.
        current += pending;
        pending = 0;
      }
      total += current;
      current = 0;
    }

    for (final w in words) {
      if (w.isEmpty || _currency.contains(w)) continue;

      if (_modifiers[w] case final delta?) {
        pending = delta;
        seen = true;
        continue;
      }
      if (_standalone[w] case final value?) {
        current += value;
        seen = true;
        continue;
      }
      if (_units[w] case final value?) {
        current += value + pending;
        pending = 0;
        seen = true;
        continue;
      }
      if (_multipliers[w] case final mult?) {
        // A bare "sau" is one hundred; "sadhe sau" is one and a half hundred.
        final quantity = current == 0 ? 1 + pending : current + pending;
        pending = 0;
        total += quantity * mult;
        current = 0;
        seen = true;
        continue;
      }
      // Any other word ends the run — "500 liya Ramesh se" must not let a name
      // keep accumulating into the figure.
      if (seen && (total > 0 || current > 0)) break;
    }
    closeCurrent();
    if (!seen) return null;
    final v = total.round();
    return v > 0 ? v : null;
  }

  // --- Names ---------------------------------------------------------------

  /// Devanagari consonants and independent vowels to a rough Latin form.
  ///
  /// Only good enough to match a name against the book — the portal stores
  /// names in Latin, and a Hindi-language dictation returns Devanagari, so
  /// without this "रमेश" and "Ramesh" are simply two different customers.
  static const _consonants = <String, String>{
    'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'n',
    'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'n',
    'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n',
    'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n',
    'प': 'p', 'फ': 'ph', 'ब': 'b', 'भ': 'bh', 'म': 'm',
    'य': 'y', 'र': 'r', 'ल': 'l', 'व': 'v', 'श': 'sh',
    'ष': 'sh', 'स': 's', 'ह': 'h', 'ळ': 'l',
    'क़': 'k', 'ख़': 'kh', 'ग़': 'g', 'ज़': 'z', 'ड़': 'r', 'ढ़': 'rh',
    'फ़': 'f',
  };
  static const _independentVowels = <String, String>{
    'अ': 'a', 'आ': 'a', 'इ': 'i', 'ई': 'i', 'उ': 'u', 'ऊ': 'u',
    'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au', 'ऋ': 'ri',
  };
  static const _vowelSigns = <String, String>{
    'ा': 'a', 'ि': 'i', 'ी': 'i', 'ु': 'u', 'ू': 'u',
    'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au', 'ृ': 'ri',
  };
  static const _virama = '्';
  static const _anusvara = {'ं': 'n', 'ँ': 'n', 'ः': 'h'};

  /// Transliterate any Devanagari in [text]; Latin passes through untouched.
  ///
  /// Implements the one rule that makes the output look like a real name:
  /// **schwa deletion**. A Devanagari consonant carries an implicit 'a', but
  /// Hindi does not pronounce it at the end of a word — रमेश is Ramesh, not
  /// Ramesha, and the trailing vowel was enough to stop the name matching the
  /// book at all.
  static String toLatin(String text) {
    final out = StringBuffer();
    // Whether the last thing written was a consonant carrying an implicit 'a'
    // that a following vowel sign or virama should replace.
    var pendingA = false;

    void flushA() {
      if (pendingA) out.write('a');
      pendingA = false;
    }

    for (final ch in text.split('')) {
      if (_consonants[ch] case final c?) {
        flushA();
        out.write(c);
        pendingA = true;
      } else if (_vowelSigns[ch] case final v?) {
        pendingA = false; // the sign replaces the inherent vowel
        out.write(v);
      } else if (ch == _virama) {
        pendingA = false; // no vowel at all
      } else if (_independentVowels[ch] case final v?) {
        flushA();
        out.write(v);
      } else if (_anusvara[ch] case final n?) {
        flushA();
        out.write(n);
      } else {
        // Word boundary (or any non-Devanagari): the implicit final vowel is
        // silent, so it is dropped rather than flushed.
        pendingA = false;
        out.write(ch);
      }
    }
    // End of the last word — same rule.
    return out.toString();
  }

  /// A spelling-insensitive key for comparing two names.
  ///
  /// Hinglish has no agreed spelling — Ramesh/Rameshh, Sunita/Suneeta,
  /// Vijay/Bijay — and dictation picks a different one each time. Folding the
  /// vowel-length and the handful of consonants Indian English swaps freely
  /// lets those all land on the same key.
  static String fold(String name) {
    var s = toLatin(normalize(name));
    s = s.replaceAll(RegExp(r'[^a-z ]'), '');
    s = s
        .replaceAll('aa', 'a')
        .replaceAll('ee', 'i')
        .replaceAll('ii', 'i')
        .replaceAll('oo', 'u')
        .replaceAll('uu', 'u')
        // e and i are the same sound across half of Indian transliteration —
        // Suresh/Sureesh, Deepak/Dipak, Reena/Rina — so they fold together.
        // The lookbehind protects the "ai" diphthong, which is a different
        // vowel and keeps Jai and Ji apart.
        .replaceAll(RegExp(r'(?<!a)e'), 'i')
        .replaceAll('ph', 'f')
        .replaceAll('w', 'v')
        .replaceAll('z', 'j')
        .replaceAll('ksh', 'x')
        .replaceAll('ck', 'k');
    // Collapse any doubled letter: Rameshh -> Ramesh, Sunnita -> Sunita.
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && s[i] == s[i - 1]) continue;
      b.write(s[i]);
    }
    return b.toString().trim();
  }

  /// Levenshtein distance, capped — we only ever care about "close enough".
  static int distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    final cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
            .reduce((x, y) => x < y ? x : y);
      }
      prev = List<int>.from(cur);
    }
    return prev[b.length];
  }

  /// How well [spoken] matches [name], 0 (no match) to 3 (exact).
  ///
  /// Scored rather than boolean so the caller can prefer its best candidate and
  /// refuse to act when two score the same — a tie is a question, not a guess.
  static int nameScore(String spoken, String name) {
    final s = fold(spoken);
    final n = fold(name);
    if (s.isEmpty || n.isEmpty) return 0;
    if (s == n) return 3;

    final spokenWords = s.split(' ').where((w) => w.length > 1).toList();
    final nameWords = n.split(' ').where((w) => w.length > 1).toList();
    if (spokenWords.isEmpty || nameWords.isEmpty) return 0;

    // Every word he said appears in the name: "ramesh kumar" in "ramesh kumar
    // yadav", or a bare "ramesh" in "ramesh kumar".
    if (spokenWords.every(nameWords.contains)) return 2;

    // Allow a typo per word, scaled by length so short names stay strict.
    // "Sita" and "Gita" are one letter apart and are two different customers,
    // so at four letters nothing is forgiven at all — the cost of being wrong
    // here is money recorded against a stranger.
    var matched = 0;
    for (final w in spokenWords) {
      final tolerance = w.length >= 7 ? 2 : (w.length >= 5 ? 1 : 0);
      if (nameWords.any((x) => distance(w, x) <= tolerance)) matched++;
    }
    return matched == spokenWords.length ? 1 : 0;
  }
}
