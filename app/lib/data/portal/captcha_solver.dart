import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// On-device OCR for the DOP login captcha. Everything runs locally (Google ML
/// Kit) — the captcha image never leaves the phone. Best-effort: captchas are
/// built to resist OCR, so the guess is pre-filled for the user to confirm, not
/// auto-submitted.
class CaptchaSolver {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  int _seq = 0;

  /// Recognise text from a PNG data URL (`data:image/png;base64,....`) or a bare
  /// base64 PNG string. Returns the cleaned alphanumeric guess, or null.
  Future<String?> solveFromDataUrl(String dataUrl) async {
    try {
      final b64 = dataUrl.contains(',') ? dataUrl.split(',').last : dataUrl;
      if (b64.trim().isEmpty) return null;
      final bytes = base64Decode(b64);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/captcha_${_seq++}.png');
      await file.writeAsBytes(bytes, flush: true);

      final result =
          await _recognizer.processImage(InputImage.fromFilePath(file.path));
      // Captcha codes are a single token; strip spaces/punctuation/newlines.
      final cleaned = result.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      try {
        await file.delete();
      } catch (_) {/* best effort */}
      return cleaned.isEmpty ? null : cleaned;
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() => _recognizer.close();
}
