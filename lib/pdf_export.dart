import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'data.dart';

// ================================================================
// PDF export
// ================================================================
//
// Produces a premium-styled, fully Unicode PDF for one folder:
//   Page 1        — cover page (app name, folder name, meta stats)
//   Page 2..N     — table of contents (message # + preview, tappable
//                   jump-links straight to the message — more useful
//                   in a digital PDF than a static page number, since
//                   a PDF viewer jumps you there in one tap)
//   Page N+1..end — every message, numbered, with a running
//                   "Page X of Y" footer on every content page
//
// Fonts: Noto Sans + Noto Sans Bengali/Devanagari + Noto Naskh Arabic
// + Noto Nastaliq Urdu are fetched via `printing`'s PdfGoogleFonts
// helper (cached after first use) and wired up as font *fallbacks*,
// so a single pw.Text mixing বাংলা + English + اردو + हिन्दी in one
// message renders correctly without any manual script splitting.
//
// Change `kPdfAppName` below to rebrand the cover page.
// ================================================================

/// Shown on the cover page as the app/brand name. Edit freely.
const String kPdfAppName = 'Excerpt';

class PdfExportService {
  static pw.ThemeData? _cachedTheme;

  static Future<pw.ThemeData> _theme() async {
    if (_cachedTheme != null) return _cachedTheme!;

    final base = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final italic = await PdfGoogleFonts.notoSansItalic();

    final bengali = await PdfGoogleFonts.notoSansBengaliRegular();
    final bengaliBold = await PdfGoogleFonts.notoSansBengaliBold();
    final devanagari = await PdfGoogleFonts.notoSansDevanagariRegular();
    final devanagariBold = await PdfGoogleFonts.notoSansDevanagariBold();
    final arabic = await PdfGoogleFonts.notoNaskhArabicRegular();
    final arabicBold = await PdfGoogleFonts.notoNaskhArabicBold();
    final urdu = await PdfGoogleFonts.notoNastaliqUrduRegular();

    _cachedTheme = pw.ThemeData.withFont(
      base: base,
      bold: bold,
      italic: italic,
      fontFallback: [
        bengali,
        bengaliBold,
        devanagari,
        devanagariBold,
        arabic,
        arabicBold,
        urdu,
      ],
    );
    return _cachedTheme!;
  }

  static const _ink = PdfColor.fromInt(0xFF12312B);
  static const _accent = PdfColor.fromInt(0xFF0F9D8A);
  static const _accentSoft = PdfColor.fromInt(0xFFE3F5F2);
  static const _muted = PdfColor.fromInt(0xFF6B7A78);

  /// Builds and saves the PDF for [folderName], returning the file path.
  static Future<String> exportFolderToPdf(String folderName) async {
    final messages = await FolderStore.readMessages(folderName);
    final summary = await FolderStore.getFolderSummary(folderName);
    final theme = await _theme();

    final doc = pw.Document(theme: theme);

    doc.addPage(_coverPage(folderName, summary));
    doc.addPage(_tocPage(folderName, messages));
    doc.addPage(_bodyPages(folderName, messages));

    final bytes = await doc.save();

    final base = await NativeBridge.getAppFilesDir();
    final dir = Directory(p.join(base, 'pdf_exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final safeName = folderName.replaceAll(RegExp(r'[^\w\-]+'), '_');
    final stamp =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file =
        File(p.join(dir.path, 'Excerpt_${safeName}_$stamp.pdf'));
    await file.writeAsBytes(bytes);

    return file.path;
  }

  // ---- Cover page ----

  static pw.Page _coverPage(String folderName, FolderSummary s) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Stack(
        children: [
          pw.Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: pw.Container(height: 160, color: _accent),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(40, 60, 40, 40),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  kPdfAppName.toUpperCase(),
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 14,
                    letterSpacing: 3,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'Exported Chat Archive',
                  style: const pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 11,
                  ),
                ),
                pw.SizedBox(height: 90),
                pw.Text(
                  folderName,
                  style: pw.TextStyle(
                    fontSize: 30,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Generated on ${_formatFullDate(DateTime.now())}',
                  style: const pw.TextStyle(fontSize: 10, color: _muted),
                ),
                pw.SizedBox(height: 36),
                pw.Container(
                  padding: const pw.EdgeInsets.all(18),
                  decoration: pw.BoxDecoration(
                    color: _accentSoft,
                    borderRadius: pw.BorderRadius.circular(12),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      _coverStatRow('Total messages', '${s.totalMessages}'),
                      _coverStatRow('Text messages', '${s.textCount}'),
                      _coverStatRow('Images', '${s.imageCount}'),
                      _coverStatRow(
                        'Folder created',
                        _formatFullDate(DateTime.tryParse(s.createdAt) ??
                            DateTime.now()),
                      ),
                      if (s.lastUpdated != null)
                        _coverStatRow(
                          'Last updated',
                          _formatFullDate(
                              DateTime.tryParse(s.lastUpdated!) ??
                                  DateTime.now()),
                        ),
                    ],
                  ),
                ),
                pw.Spacer(),
                pw.Divider(color: _muted, thickness: 0.5),
                pw.SizedBox(height: 8),
                pw.Text(
                  'Page 2 lists a table of contents. Every message '
                  'below is numbered — tap an entry in the table of '
                  'contents to jump straight to it.',
                  style: const pw.TextStyle(fontSize: 9, color: _muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _coverStatRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: const pw.TextStyle(fontSize: 10, color: _muted)),
          pw.Text(
            value,
            style: pw.TextStyle(
                fontSize: 11, fontWeight: pw.FontWeight.bold, color: _ink),
          ),
        ],
      ),
    );
  }

  // ---- Table of contents ----

  static pw.Page _tocPage(
    String folderName,
    List<Map<String, dynamic>> messages,
  ) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 44, 36, 40),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Table of Contents',
            style: pw.TextStyle(
                fontSize: 20, fontWeight: pw.FontWeight.bold, color: _ink),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            '${messages.length} message(s) in "$folderName"',
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
          pw.SizedBox(height: 16),
          pw.Expanded(
            child: pw.ListView.builder(
              itemCount: messages.length,
              itemBuilder: (context, i) {
                final m = messages[i];
                final preview = _previewOf(m['text']?.toString() ?? '', 12);
                final isUser = m['type'] == 'user';

                return pw.Link(
                  destination: 'msg_${m['id']}',
                  child: pw.Container(
                    margin: const pw.EdgeInsets.only(bottom: 6),
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: pw.BoxDecoration(
                      color: i.isEven ? _accentSoft : PdfColors.white,
                      borderRadius: pw.BorderRadius.circular(8),
                    ),
                    child: pw.Row(
                      children: [
                        pw.Container(
                          width: 22,
                          height: 22,
                          alignment: pw.Alignment.center,
                          decoration: const pw.BoxDecoration(
                            color: _accent,
                            shape: pw.BoxShape.circle,
                          ),
                          child: pw.Text(
                            '${i + 1}',
                            style: pw.TextStyle(
                                fontSize: 8,
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold),
                          ),
                        ),
                        pw.SizedBox(width: 8),
                        pw.Expanded(
                          child: pw.Text(
                            preview.isEmpty
                                ? (m['type'] == 'image'
                                    ? '[image]'
                                    : '(empty)')
                                : preview,
                            style: const pw.TextStyle(fontSize: 10),
                            maxLines: 1,
                            overflow: pw.TextOverflow.clip,
                          ),
                        ),
                        pw.SizedBox(width: 6),
                        pw.Text(
                          isUser ? 'You' : 'System',
                          style: const pw.TextStyle(
                              fontSize: 8, color: _muted),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---- Body (numbered messages, page footer) ----

  static pw.MultiPage _bodyPages(
    String folderName,
    List<Map<String, dynamic>> messages,
  ) {
    return pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 40, 32, 40),
      header: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _accent, width: 1)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              folderName,
              style: pw.TextStyle(
                  fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink),
            ),
            pw.Text(
              kPdfAppName,
              style: const pw.TextStyle(fontSize: 9, color: _muted),
            ),
          ],
        ),
      ),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.only(top: 6),
        child: pw.Text(
          'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _muted),
        ),
      ),
      build: (ctx) => [
        for (int i = 0; i < messages.length; i++) _messageBlock(i, messages[i]),
      ],
    );
  }

  static pw.Widget _messageBlock(int index, Map<String, dynamic> m) {
    final isUser = m['type'] == 'user';
    final isImage = m['type'] == 'image';
    final text = m['text']?.toString() ?? '';
    final ts = DateTime.tryParse(m['timestamp']?.toString() ?? '');
    final edited = m['edited'] == true;
    final important = m['important'] == true;

    return pw.Anchor(
      name: 'msg_${m['id']}',
      child: pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: isUser ? _accentSoft : PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(10),
          border: important
              ? pw.Border.all(color: PdfColors.amber700, width: 1)
              : null,
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              children: [
                pw.Container(
                  width: 18,
                  height: 18,
                  alignment: pw.Alignment.center,
                  decoration: const pw.BoxDecoration(
                    color: _accent,
                    shape: pw.BoxShape.circle,
                  ),
                  child: pw.Text(
                    '${index + 1}',
                    style: pw.TextStyle(
                        fontSize: 7,
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold),
                  ),
                ),
                pw.SizedBox(width: 6),
                pw.Text(
                  isUser ? 'You' : 'System',
                  style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                      color: _ink),
                ),
                if (important) ...[
                  pw.SizedBox(width: 4),
                  pw.Text('★',
                      style: const pw.TextStyle(
                          fontSize: 8, color: PdfColors.amber700)),
                ],
                pw.Spacer(),
                if (ts != null)
                  pw.Text(
                    _formatFullDateTime(ts),
                    style: const pw.TextStyle(fontSize: 7, color: _muted),
                  ),
              ],
            ),
            pw.SizedBox(height: 5),
            if (isImage)
              pw.Text(
                text.isEmpty ? '[image attachment]' : '[image] $text',
                style: pw.TextStyle(
                    fontSize: 10, fontStyle: pw.FontStyle.italic, color: _ink),
              )
            else
              pw.Text(
                text,
                style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 2),
              ),
            if (edited)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 3),
                child: pw.Text('(edited)',
                    style: const pw.TextStyle(fontSize: 7, color: _muted)),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Helpers ----

  static String _previewOf(String text, int maxWords) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '';
    final words = normalized.split(' ');
    if (words.length <= maxWords) return normalized;
    return '${words.take(maxWords).join(' ')}…';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatFullDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  static String _formatFullDateTime(DateTime dt) {
    final local = dt.toLocal();
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour >= 12 ? 'PM' : 'AM';
    return '${local.day} ${_months[local.month - 1]} ${local.year}, '
        '$hour12:$minute $period';
  }
}