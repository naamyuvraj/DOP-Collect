import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'lang.dart';

/// Wraps on-device speech-to-text (mic -> text) and text-to-speech (answer read
/// aloud). Both are free and offline-capable. Hindi-first, but the recognizer
/// also handles English/Hinglish.
///
/// Everything here is written for one situation: a man standing at a doorstep
/// with a bag of cash in one hand and the phone in the other. He cannot look at
/// the screen to find out whether it heard him, so a failure has to announce
/// itself rather than leave a button glowing.
class VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;

  /// Locales the device can actually recognise, resolved once. A phone without
  /// the Hindi pack installed will silently ignore a `hi_IN` request and
  /// dictate in English, which reads as "the app didn't understand me".
  List<String>? _localeIds;

  bool get isListening => _stt.isListening;

  /// Why the last listen ended badly, if it did — plain enough to show him.
  String? lastError;

  Future<bool> initStt({void Function(String reason)? onFailure}) async {
    if (_sttReady) return true;
    _sttReady = await _stt.initialize(
      // These used to be empty. A denied permission, a recogniser that dies
      // mid-phrase, or simple silence all end the session WITHOUT a final
      // result — so the caller's `onFinal` never fired and the mic button sat
      // there red until he gave up and pressed it again.
      onError: (e) {
        lastError = _explain(e.errorMsg);
        onFailure?.call(lastError!);
      },
      onStatus: (status) {
        // 'done' / 'notListening' with nothing recognised is the silent case.
        if (status == 'done' || status == 'notListening') {
          _statusDone?.call();
        }
      },
    );
    if (!_sttReady) {
      lastError = 'Mic band hai — settings me permission dein.';
      onFailure?.call(lastError!);
    }
    return _sttReady;
  }

  void Function()? _statusDone;

  /// Turn a recogniser error code into something worth reading aloud.
  static String _explain(String code) {
    switch (code) {
      case 'error_permission' || 'error_audio_error':
        return 'Mic ki permission chahiye.';
      case 'error_no_match' || 'error_speech_timeout':
        return 'Sunai nahi diya — dobara boliye.';
      case 'error_network' || 'error_network_timeout':
        // Hindi recognition often needs the offline pack; without it the engine
        // reaches for the network and fails where there is no signal.
        return 'Awaaz pehchanne ke liye net chahiye. Type karke poochhein.';
      case 'error_busy':
        return 'Mic abhi busy hai — ek pal ruk kar dobara.';
      default:
        return 'Mic me dikkat aayi — dobara koshish karein.';
    }
  }

  /// The closest locale the device really has to [wanted].
  ///
  /// Falls back along a chain that keeps dictation usable rather than correct:
  /// exact match, then the same language in any region, then Indian English,
  /// then whatever the device defaults to.
  Future<String?> resolveLocale(String wanted) async {
    if (!await initStt()) return null;
    _localeIds ??= (await _stt.locales()).map((l) => l.localeId).toList();
    final ids = _localeIds!;
    if (ids.isEmpty) return null;

    String norm(String s) => s.replaceAll('-', '_').toLowerCase();
    final target = norm(wanted);
    for (final id in ids) {
      if (norm(id) == target) return id;
    }
    final lang = target.split('_').first;
    for (final id in ids) {
      if (norm(id).startsWith('${lang}_')) return id;
    }
    for (final id in ids) {
      if (norm(id) == 'en_in') return id;
    }
    return null; // let the platform pick its default
  }

  /// True when the device can dictate in [wanted] — the UI uses this to say so
  /// before he discovers it by being misheard.
  Future<bool> supportsLocale(String wanted) async {
    final resolved = await resolveLocale(wanted);
    if (resolved == null) return false;
    return resolved.replaceAll('-', '_').toLowerCase().split('_').first ==
        wanted.replaceAll('-', '_').toLowerCase().split('_').first;
  }

  /// Starts listening. [onResult] fires with partial + final transcripts;
  /// [onFinal] fires once with the final phrase. [onDone] always fires when the
  /// session ends for any reason, so the caller can reset its own state.
  Future<bool> listen({
    required void Function(String text) onResult,
    required void Function(String text) onFinal,
    void Function()? onDone,
    void Function(String reason)? onError,
    String? localeId, // 'en_IN' / 'hi_IN'; null = device default
  }) async {
    lastError = null;
    if (!await initStt(onFailure: onError)) {
      onDone?.call();
      return false;
    }

    var finished = false;
    var latest = '';
    void finish() {
      if (finished) return;
      finished = true;
      _statusDone = null;
      onDone?.call();
    }

    // The recogniser can stop without ever delivering a final result — a long
    // silence, or a phrase it could not score. Treat the last partial as the
    // answer rather than dropping what he said on the floor.
    _statusDone = () {
      if (finished) return;
      if (latest.trim().isNotEmpty) onFinal(latest);
      finish();
    };

    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          localeId: localeId == null ? null : await resolveLocale(localeId),
          // A name and an amount is a short phrase, but an older speaker takes
          // his time getting to it — long enough not to cut him off, and a
          // generous pause so a mid-sentence breath doesn't end the turn.
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 5),
          cancelOnError: true,
        ),
        onResult: (r) {
          latest = r.recognizedWords;
          onResult(latest);
          if (r.finalResult) {
            if (latest.trim().isNotEmpty) onFinal(latest);
            finish();
          }
        },
      );
    } catch (e) {
      lastError = 'Mic shuru nahi hua — dobara koshish karein.';
      onError?.call(lastError!);
      finish();
      return false;
    }
    return true;
  }

  Future<void> stop() async {
    _statusDone = null;
    try {
      await _stt.stop();
    } catch (_) {/* already stopped */}
  }

  // --- Speaking ------------------------------------------------------------

  bool _ttsReady = false;

  Future<void> initTts() async {
    try {
      await _tts.setSpeechRate(0.46);
      await _tts.setPitch(1.0);
      _ttsReady = true;
    } catch (_) {
      _ttsReady = false; // no engine installed — stay silent, never crash
    }
  }

  /// Read [text] aloud in the language it is written in.
  ///
  /// Wrapped because a missing voice pack throws from the platform channel, and
  /// an answer that is on screen must not be lost to a crash just because the
  /// phone cannot pronounce it.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty || !_ttsReady) return;
    try {
      await _tts.stop();
      final wanted = isHindiText(text) ? 'hi-IN' : 'en-IN';
      final available = await _tts.isLanguageAvailable(wanted);
      await _tts.setLanguage(available == true ? wanted : 'en-IN');
      await _tts.speak(text);
    } catch (_) {/* speech is a nicety; the text is already on screen */}
  }

  Future<void> shutUp() async {
    try {
      await _tts.stop();
    } catch (_) {/* nothing playing */}
  }
}
