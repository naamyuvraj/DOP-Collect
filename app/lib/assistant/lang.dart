/// Tiny language helper shared by the assistant and voice. Devanagari in the
/// text => treat the exchange as Hindi (so replies and TTS match the user).
final RegExp _devanagari = RegExp(r'[ऀ-ॿ]');

bool isHindiText(String text) => _devanagari.hasMatch(text);

/// 'hi' if the text is written in Hindi script, else 'en'.
String langOf(String text) => isHindiText(text) ? 'hi' : 'en';
