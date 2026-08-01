import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../theme/app_theme.dart';
import '../../widgets/push_button.dart';

/// Full-screen, pinch-to-zoom preview of a list's PDF. The pages are rasterised
/// on-device (via the printing engine) and shown in an [InteractiveViewer] so
/// the agent can zoom right in to read the small account numbers before it
/// leaves the phone. "Download" saves it as a PDF file; the top-bar icon shares
/// it. Used for a single list, a draft, or a whole bundled batch.
class LotPreviewScreen extends StatefulWidget {
  const LotPreviewScreen({
    super.key,
    required this.title,
    required this.bytes,
    required this.filename,
    this.onDownloaded,
  });

  final String title;
  final Uint8List bytes;
  final String filename;

  /// Called after a successful download/share — e.g. to mark it "downloaded".
  final VoidCallback? onDownloaded;

  @override
  State<LotPreviewScreen> createState() => _LotPreviewScreenState();
}

class _LotPreviewScreenState extends State<LotPreviewScreen> {
  late final Future<List<Uint8List>> _pages = _rasterize();

  /// Render every page to a PNG at a readable DPI. 150 keeps memory sane on a
  /// budget phone while zoom handles the fine print.
  Future<List<Uint8List>> _rasterize() async {
    final out = <Uint8List>[];
    await for (final page in Printing.raster(widget.bytes, dpi: 150)) {
      out.add(await page.toPng());
    }
    return out;
  }

  /// Real download: Android's print framework "Save as PDF" writes the file to
  /// the device (Downloads). Distinct from Share below.
  Future<void> _download() async {
    await Printing.layoutPdf(
        onLayout: (_) async => widget.bytes, name: widget.filename);
    widget.onDownloaded?.call();
  }

  /// Send the PDF to WhatsApp / Drive / Files.
  Future<void> _share() async {
    await Printing.sharePdf(bytes: widget.bytes, filename: widget.filename);
    widget.onDownloaded?.call();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Share PDF',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _share,
          ),
        ],
      ),
      // A LIGHT document-viewer surface. The rasterised pages can be partly
      // transparent, so each page also gets a solid white backing — otherwise
      // the sheet looks dim/grey.
      backgroundColor: const Color(0xFFE9E9E9),
      body: FutureBuilder<List<Uint8List>>(
        future: _pages,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final pages = snap.data ?? const <Uint8List>[];
          if (snap.hasError || pages.isEmpty) return _fallback();
          return InteractiveViewer(
            constrained: false,
            minScale: 0.5,
            maxScale: 6,
            boundaryMargin: const EdgeInsets.all(120),
            child: SizedBox(
              width: w,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final png in pages)
                    Container(
                      margin: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                      color: Colors.white, // solid white sheet behind the page
                      child: Image.memory(png,
                          width: w, fit: BoxFit.fitWidth, gaplessPlayback: true),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: PushButton(
            onPressed: _download,
            color: AppTheme.black,
            foreground: Colors.white,
            radius: 14,
            expand: false, // else it balloons to full height in a bottom bar
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_rounded, size: 20, color: Colors.white),
                SizedBox(width: 8),
                Text('Download PDF'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// If on-device rasterising isn't available, don't show a black void — let the
  /// agent still download/share the PDF and open it in their normal PDF app.
  Widget _fallback() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Preview isn\'t available on this phone.\n'
            'Tap "Download PDF" below to save and open it.',
            textAlign: TextAlign.center,
            style: AppTheme.body(14, color: AppTheme.inkMuted),
          ),
        ),
      );
}
