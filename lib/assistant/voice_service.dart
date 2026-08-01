import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'lang.dart';

/// Wraps on-device speech-to-text (mic -> text) and text-to-speech (answer read
/// aloud). Both are free and offline-capable. Hindi-first, but the recognizer
/// also handles English/Hinglish.
class VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;

  bool get isListening => _stt.isListening;

  Future<bool> initStt() async {
    if (_sttReady) return true;
    _sttReady = await _stt.initialize(
      onError: (_) {},
      onStatus: (_) {},
    );
    return _sttReady;
  }

  Future<void> initTts() async {
    await _tts.setSpeechRate(0.46);
    await _tts.setPitch(1.0);
  }

  /// Starts listening. [onResult] fires with partial + final transcripts;
  /// [onFinal] fires once with the final phrase. Returns false if mic/STT
  /// isn't available (e.g. permission denied).
  Future<bool> listen({
    required void Function(String text) onResult,
    required void Function(String text) onFinal,
    String? localeId, // 'en_IN' / 'hi_IN'; null = device default
  }) async {
    if (!await initStt()) return false;
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        localeId: localeId,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 3),
      ),
      onResult: (r) {
        onResult(r.recognizedWords);
        if (r.finalResult) onFinal(r.recognizedWords);
      },
    );
    return true;
  }

  Future<void> stop() => _stt.stop();

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.setLanguage(isHindiText(text) ? 'hi-IN' : 'en-IN');
    await _tts.speak(text);
  }

  Future<void> shutUp() => _tts.stop();
}
