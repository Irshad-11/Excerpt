import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'data.dart';

// ================================================================
// PDF export
// ================================================================
//
// Produces a Unicode PDF for one folder:
//
//   Page 1        — cover page
//   Page 2..N     — table of contents
//   Page N+1..end — every message
//
// Images are resized/compressed before embedding and are also
// explicitly constrained inside the PDF page so that a large image
// can never cause a MultiPage "TooManyPagesException".
//
// ----------------------------------------------------------------
// Large-folder handling (NEW)
// ----------------------------------------------------------------
//
// `package:pdf`'s MultiPage widget refuses to render past a default
// safety cap of 20 pages, which is what was throwing
// "TooManyPagesException" whenever a folder had a lot of
// messages/images. Two independent fixes are applied:
//
//   1. `maxPages` is now explicitly raised (see `_kMaxPdfPages`) on
//      every MultiPage we build, so a normal-to-large folder never
//      hits the cap.
//   2. For *very* large folders, `analyzeExport()` lets the caller
//      (the UI layer) detect this ahead of time and show a "split
//      into parts?" dialog. Each part is generated as its own
//      independent PDF — its own cover page and its own table of
//      contents, scoped to just the range of messages it contains —
//      and parts are generated one at a time via
//      `exportFolderToPdfPart(...)`. Only that part's images are
//      decoded/held in memory, so the user can download part 1,
//      then part 2, etc. without the whole folder's images ever
//      being in memory at once.
//
// ----------------------------------------------------------------
// Fonts (UPDATED)
// ----------------------------------------------------------------
//
// All text is drawn through a single Unicode-capable font stack
// (Noto Sans as the Latin base, with per-script fallbacks attached
// via `fontFallback`). Bangla now uses Hind Siliguri specifically —
// it shapes Bangla conjuncts/matras more reliably than the generic
// Noto Sans Bengali fallback, which is what was causing Bangla text
// to visually break/mis-render. Devanagari, Arabic and Urdu keep
// their Noto fallbacks. Because every fallback font is loaded up
// front, mixed-script text (Bangla + English + emoji, etc.) renders
// from a single TextStyle without manually switching fonts.
//
// ================================================================

const String kPdfAppName = 'Excerpt';

/// Maximum source image dimension before JPEG compression.
const int _kMaxImageDimension = 1000;

const int _kJpegQuality = 72;

/// Maximum visual height of an image inside an A4 message block.
///
/// This is deliberately smaller than the usable A4 page height so
/// the image can always coexist with the message header/padding.
const double _kMaxPdfImageHeight = 360;

/// Maximum width of an embedded image.
const double _kMaxPdfImageWidth = 520;

/// Safety cap passed to every [pw.MultiPage]. `package:pdf` defaults
/// this to 20, which is what was causing `TooManyPagesException` on
/// any folder whose content spilled past ~20 pages. Set high enough
/// that a single export (or a single part of a split export) will
/// never realistically hit it.
const int _kMaxPdfPages = 20000;

/// A recommendation for whether a folder should be exported as one
/// PDF or split into multiple, more manageable parts. Call
/// [PdfExportService.analyzeExport] *before* generating a PDF so the
/// UI can show a confirmation dialog, e.g.:
/// "This export is large — split into N parts?".
class PdfExportPlan {
  const PdfExportPlan({
    required this.totalMessages,
    required this.estimatedPages,
    required this.shouldSplit,
    required this.suggestedParts,
    required this.messagesPerPart,
  });

  final int totalMessages;

  /// Rough estimate of how many PDF pages the *unsplit* export would
  /// need. Heuristic only (text messages are cheap, images are
  /// expensive) — meant to decide whether to suggest a split, not to
  /// be pixel-accurate.
  final int estimatedPages;

  /// True when the folder is large enough that exporting as a single
  /// PDF would be slow/heavy on a mobile device.
  final bool shouldSplit;

  /// Suggested number of parts if the user agrees to split.
  final int suggestedParts;

  /// Suggested number of messages inside each part. Pass this to
  /// [PdfExportService.exportFolderToPdfPart].
  final int messagesPerPart;
}

/// Describes the slice of messages a single part covers, plus its
/// position among the other parts. Used internally to render the
/// cover page / TOC header / message numbering for a part.
class _PartRange {
  const _PartRange({
    required this.partNumber,
    required this.totalParts,
    required this.startIndex,
    required this.endIndex,
  });

  final int partNumber; // 1-based
  final int totalParts;
  final int startIndex; // inclusive, into the full messages list
  final int endIndex; // exclusive, into the full messages list

  int get count => endIndex - startIndex;

  bool get isSplit => totalParts > 1;
}

class PdfExportService {
  static pw.ThemeData? _cachedTheme;

  // --------------------------------------------------------------
  // Fonts
  // --------------------------------------------------------------

  static Future<pw.ThemeData> _theme() async {
    if (_cachedTheme != null) return _cachedTheme!;

    final base = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final italic = await PdfGoogleFonts.notoSansItalic();

    // Bangla: Hind Siliguri instead of Noto Sans Bengali — better
    // Bangla conjunct/matra shaping, which is what was breaking.
    final bengali = await PdfGoogleFonts.hindSiliguriRegular();
    final bengaliBold = await PdfGoogleFonts.hindSiliguriBold();

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

  // --------------------------------------------------------------
  // Planning (NEW) — call this before exporting to decide
  // single-PDF vs split-into-parts.
  // --------------------------------------------------------------

  /// Reads the folder's messages (cheap — no image decoding happens
  /// here) and returns a [PdfExportPlan] describing whether this
  /// folder should be split into multiple PDF parts, and how many.
  static Future<PdfExportPlan> analyzeExport(
    String folderName, {
    int maxPagesPerPart = 250,
  }) async {
    final messages = await FolderStore.readMessages(folderName);

    int textCount = 0;
    int imageCount = 0;

    for (final m in messages) {
      if (m['type'] == 'image') {
        imageCount++;
      } else {
        textCount++;
      }
    }

    // Heuristic page cost: short text bubbles pack several per page,
    // images take much more vertical space. Only used to decide
    // whether/how to split — not used for anything visual.
    final estimatedPages = 2 + // cover + first toc page
        (textCount / 7).ceil() +
        (imageCount / 2).ceil();

    final total = messages.length;

    final shouldSplit = total > 0 &&
        (estimatedPages > maxPagesPerPart || total > 600);

    if (!shouldSplit) {
      return PdfExportPlan(
        totalMessages: total,
        estimatedPages: estimatedPages,
        shouldSplit: false,
        suggestedParts: 1,
        messagesPerPart: total,
      );
    }

    final suggestedParts =
        (estimatedPages / maxPagesPerPart).ceil().clamp(2, 1000);

    final messagesPerPart = (total / suggestedParts).ceil();

    return PdfExportPlan(
      totalMessages: total,
      estimatedPages: estimatedPages,
      shouldSplit: true,
      suggestedParts: suggestedParts,
      messagesPerPart: messagesPerPart,
    );
  }

  // --------------------------------------------------------------
  // Export — single PDF (whole folder)
  // --------------------------------------------------------------
  //
  // Signature/behaviour unchanged for existing callers. Only the
  // internal `maxPages` cap changed, so this now also works for
  // folders that used to hit `TooManyPagesException`. For very
  // large folders, call [analyzeExport] first and, if it recommends
  // a split, use [exportFolderToPdfPart] instead of this.
  // --------------------------------------------------------------

  static Future<String> exportFolderToPdf(String folderName) async {
    final messages = await FolderStore.readMessages(folderName);
    final summary = await FolderStore.getFolderSummary(folderName);

    return _buildAndSave(
      folderName: folderName,
      allMessages: messages,
      range: _PartRange(
        partNumber: 1,
        totalParts: 1,
        startIndex: 0,
        endIndex: messages.length,
      ),
      totalMessages: summary.totalMessages,
      textCount: summary.textCount,
      imageCount: summary.imageCount,
      createdAt: DateTime.tryParse(summary.createdAt) ?? DateTime.now(),
      lastUpdated: summary.lastUpdated != null
          ? DateTime.tryParse(summary.lastUpdated!)
          : null,
    );
  }

  // --------------------------------------------------------------
  // Export — a single part of a split export (NEW)
  // --------------------------------------------------------------

  /// Generates and saves *only one part* of a split export. Only the
  /// messages/images belonging to this part are loaded, so this is
  /// safe to call one part at a time (e.g. from a
  /// "Download part 2 of 4" button) without ever holding the whole
  /// folder's images in memory at once.
  ///
  /// [partNumber] is 1-based. [totalParts] and [messagesPerPart]
  /// should normally come from [PdfExportPlan] (via [analyzeExport]).
  static Future<String> exportFolderToPdfPart(
    String folderName, {
    required int partNumber,
    required int totalParts,
    required int messagesPerPart,
  }) async {
    assert(partNumber >= 1 && partNumber <= totalParts);

    final messages = await FolderStore.readMessages(folderName);
    final summary = await FolderStore.getFolderSummary(folderName);

    final rawStart = (partNumber - 1) * messagesPerPart;

    final startIndex = rawStart.clamp(0, messages.length);
    final endIndex =
        (rawStart + messagesPerPart).clamp(0, messages.length);

    final range = _PartRange(
      partNumber: partNumber,
      totalParts: totalParts,
      startIndex: startIndex,
      endIndex: endIndex,
    );

    return _buildAndSave(
      folderName: folderName,
      allMessages: messages,
      range: range,
      totalMessages: summary.totalMessages,
      textCount: summary.textCount,
      imageCount: summary.imageCount,
      createdAt: DateTime.tryParse(summary.createdAt) ?? DateTime.now(),
      lastUpdated: summary.lastUpdated != null
          ? DateTime.tryParse(summary.lastUpdated!)
          : null,
    );
  }

  // --------------------------------------------------------------
  // Shared build/save pipeline
  // --------------------------------------------------------------

  static Future<String> _buildAndSave({
    required String folderName,
    required List<Map<String, dynamic>> allMessages,
    required _PartRange range,
    required int totalMessages,
    required int textCount,
    required int imageCount,
    required DateTime createdAt,
    DateTime? lastUpdated,
  }) async {
    final theme = await _theme();

    final partMessages =
        allMessages.sublist(range.startIndex, range.endIndex);

    // Only decode/compress images that belong to *this* part — the
    // main lever for keeping memory/CPU usage down on large, split
    // exports.
    final imageCache = await _preloadImages(partMessages);

    final doc = pw.Document(theme: theme);

    doc.addPage(
      _coverPage(
        folderName: folderName,
        totalMessages: totalMessages,
        textCount: textCount,
        imageCount: imageCount,
        createdAt: createdAt,
        lastUpdated: lastUpdated,
        range: range,
      ),
    );

    doc.addPage(
      _tocPage(folderName, partMessages, range),
    );

    doc.addPage(
      _bodyPages(folderName, partMessages, imageCache, range),
    );

    final bytes = await doc.save();

    // ------------------------------------------------------------
    // Save PDF
    // ------------------------------------------------------------

    final base = await NativeBridge.getAppFilesDir();

    final dir = Directory(
      p.join(base, 'pdf_exports'),
    );

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final safeName = folderName.replaceAll(
      RegExp(r'[^\w\-]+'),
      '_',
    );

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');

    final partSuffix = range.isSplit
        ? '_Part${range.partNumber}of${range.totalParts}'
        : '';

    final file = File(
      p.join(
        dir.path,
        'Excerpt_${safeName}${partSuffix}_$stamp.pdf',
      ),
    );

    await file.writeAsBytes(
      bytes,
      flush: true,
    );

    if (!await file.exists()) {
      throw Exception(
        'PDF was generated but could not be saved.',
      );
    }

    return file.path;
  }

  // --------------------------------------------------------------
  // Image loading
  // --------------------------------------------------------------

  static Future<Map<String, pw.MemoryImage>> _preloadImages(
    List<Map<String, dynamic>> messages,
  ) async {
    final cache = <String, pw.MemoryImage>{};

    for (final m in messages) {
      if (m['type'] != 'image') continue;

      final id = m['id'] as String?;
      final path = m['image_path'] as String?;

      if (id == null || path == null) continue;

      final loaded = await _loadCompressedImage(path);

      if (loaded != null) {
        cache[id] = loaded;
      }
    }

    return cache;
  }

  static Future<pw.MemoryImage?> _loadCompressedImage(
    String path,
  ) async {
    try {
      final file = File(path);

      if (!await file.exists()) {
        return null;
      }

      final bytes = await file.readAsBytes();

      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        return null;
      }

      img.Image resized = decoded;

      if (decoded.width > _kMaxImageDimension ||
          decoded.height > _kMaxImageDimension) {
        resized = decoded.width >= decoded.height
            ? img.copyResize(
                decoded,
                width: _kMaxImageDimension,
              )
            : img.copyResize(
                decoded,
                height: _kMaxImageDimension,
              );
      }

      final jpg = img.encodeJpg(
        resized,
        quality: _kJpegQuality,
      );

      return pw.MemoryImage(
        Uint8List.fromList(jpg),
      );
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------
  // Cover
  // --------------------------------------------------------------

  static pw.Page _coverPage({
    required String folderName,
    required int totalMessages,
    required int textCount,
    required int imageCount,
    required DateTime createdAt,
    DateTime? lastUpdated,
    required _PartRange range,
  }) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Stack(
        children: [
          pw.Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: pw.Container(
              height: 160,
              color: _accent,
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(
              40,
              60,
              40,
              40,
            ),
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
                  range.isSplit
                      ? 'Exported Chat Archive — Part ${range.partNumber} of ${range.totalParts}'
                      : 'Exported Chat Archive',
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
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: _muted,
                  ),
                ),
                if (range.isSplit) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'This part covers messages '
                    '${range.startIndex + 1}\u2013${range.endIndex} '
                    'of $totalMessages',
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: _accent,
                    ),
                  ),
                ],
                pw.SizedBox(height: 36),
                pw.Container(
                  padding: const pw.EdgeInsets.all(18),
                  decoration: pw.BoxDecoration(
                    color: _accentSoft,
                    borderRadius: pw.BorderRadius.circular(12),
                  ),
                  child: pw.Column(
                    crossAxisAlignment:
                        pw.CrossAxisAlignment.start,
                    children: [
                      _coverStatRow(
                        range.isSplit
                            ? 'Messages in this part'
                            : 'Total messages',
                        '${range.isSplit ? range.count : totalMessages}',
                      ),
                      _coverStatRow(
                        'Text messages',
                        '$textCount',
                      ),
                      _coverStatRow(
                        'Images',
                        '$imageCount',
                      ),
                      _coverStatRow(
                        'Folder created',
                        _formatFullDate(createdAt),
                      ),
                      if (lastUpdated != null)
                        _coverStatRow(
                          'Last updated',
                          _formatFullDate(lastUpdated),
                        ),
                    ],
                  ),
                ),
                pw.Spacer(),
                pw.Divider(
                  color: _muted,
                  thickness: 0.5,
                ),
                pw.SizedBox(height: 8),
                pw.Text(
                  range.isSplit
                      ? 'The next pages list a table of contents for '
                        'this part only. Every message below is '
                        'numbered — tap an entry in the table of '
                        'contents to jump straight to it.'
                      : 'The next pages list a table of contents. '
                        'Every message below is numbered — tap an '
                        'entry in the table of contents to jump '
                        'straight to it.',
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _coverStatRow(
    String label,
    String value,
  ) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: pw.Row(
        mainAxisAlignment:
            pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: const pw.TextStyle(
              fontSize: 10,
              color: _muted,
            ),
          ),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------
  // Table of contents
  // --------------------------------------------------------------

  static pw.MultiPage _tocPage(
    String folderName,
    List<Map<String, dynamic>> partMessages,
    _PartRange range,
  ) {
    return pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: _kMaxPdfPages,
      margin: const pw.EdgeInsets.fromLTRB(
        36,
        40,
        36,
        40,
      ),
      header: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(
          bottom: 10,
        ),
        child: ctx.pageNumber == 1
            ? pw.Column(
                crossAxisAlignment:
                    pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    range.isSplit
                        ? 'Table of Contents — Part ${range.partNumber} of ${range.totalParts}'
                        : 'Table of Contents',
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                      color: _ink,
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    range.isSplit
                        ? '${partMessages.length} message(s) '
                          '(#${range.startIndex + 1}\u2013${range.endIndex}) '
                          'in "$folderName"'
                        : '${partMessages.length} message(s) in "$folderName"',
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: _muted,
                    ),
                  ),
                ],
              )
            : pw.Text(
                folderName,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _muted,
                ),
              ),
      ),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.only(
          top: 6,
        ),
        child: pw.Text(
          '${ctx.pageNumber}',
          style: const pw.TextStyle(
            fontSize: 8,
            color: _muted,
          ),
        ),
      ),
      build: (ctx) => [
        for (int i = 0; i < partMessages.length; i++)
          _tocRow(
            range.startIndex + i,
            partMessages[i],
          ),
      ],
    );
  }

  static pw.Widget _tocRow(
    int globalIndex,
    Map<String, dynamic> m,
  ) {
    final preview = _previewOf(
      m['text']?.toString() ?? '',
      12,
    );

    final isUser = m['source'] == 'user';

    return pw.Link(
      destination: 'msg_${m['id']}',
      child: pw.Container(
        margin: const pw.EdgeInsets.only(
          bottom: 6,
        ),
        padding: const pw.EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        decoration: pw.BoxDecoration(
          color: globalIndex.isEven
              ? _accentSoft
              : PdfColors.white,
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
                '${globalIndex + 1}',
                style: pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                ),
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
                style: const pw.TextStyle(
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: pw.TextOverflow.clip,
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Text(
              isUser ? 'You' : 'System',
              style: const pw.TextStyle(
                fontSize: 8,
                color: _muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------
  // Body
  // --------------------------------------------------------------

  static pw.MultiPage _bodyPages(
    String folderName,
    List<Map<String, dynamic>> partMessages,
    Map<String, pw.MemoryImage> imageCache,
    _PartRange range,
  ) {
    return pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: _kMaxPdfPages,
      margin: const pw.EdgeInsets.fromLTRB(
        32,
        40,
        32,
        40,
      ),
      header: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(
          bottom: 8,
        ),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(
              color: _accent,
              width: 1,
            ),
          ),
        ),
        child: pw.Row(
          mainAxisAlignment:
              pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              range.isSplit
                  ? '$folderName — Part ${range.partNumber} of ${range.totalParts}'
                  : folderName,
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
            ),
            pw.Text(
              kPdfAppName,
              style: const pw.TextStyle(
                fontSize: 9,
                color: _muted,
              ),
            ),
          ],
        ),
      ),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.only(
          top: 6,
        ),
        child: pw.Text(
          'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(
            fontSize: 8,
            color: _muted,
          ),
        ),
      ),
      build: (ctx) => [
        for (int i = 0; i < partMessages.length; i++)
          _messageBlock(
            range.startIndex + i,
            partMessages[i],
            imageCache,
          ),
      ],
    );
  }

  // --------------------------------------------------------------
  // Message block
  // --------------------------------------------------------------

  static pw.Widget _messageBlock(
    int globalIndex,
    Map<String, dynamic> m,
    Map<String, pw.MemoryImage> imageCache,
  ) {
    final isUser = m['source'] == 'user';
    final isImage = m['type'] == 'image';

    final text = m['text']?.toString() ?? '';

    final ts = DateTime.tryParse(
      m['timestamp']?.toString() ?? '',
    );

    final edited = m['edited'] == true;
    final important = m['important'] == true;

    final image = isImage
        ? imageCache[m['id']]
        : null;

    return pw.Anchor(
      name: 'msg_${m['id']}',
      child: pw.Container(
        margin: const pw.EdgeInsets.only(
          bottom: 10,
        ),
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: isUser
              ? _accentSoft
              : PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(10),
          border: important
              ? pw.Border.all(
                  color: PdfColors.amber700,
                  width: 1,
                )
              : null,
        ),
        child: pw.Column(
          crossAxisAlignment:
              pw.CrossAxisAlignment.start,
          children: [
            // ----------------------------------------------------
            // Header
            // ----------------------------------------------------

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
                    '${globalIndex + 1}',
                    style: pw.TextStyle(
                      fontSize: 7,
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(width: 6),
                pw.Text(
                  isUser ? 'You' : 'System',
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink,
                  ),
                ),
                if (important) ...[
                  pw.SizedBox(width: 4),
                  pw.Text(
                    '★',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.amber700,
                    ),
                  ),
                ],
                pw.Spacer(),
                if (ts != null)
                  pw.Text(
                    _formatFullDateTime(ts),
                    style: const pw.TextStyle(
                      fontSize: 7,
                      color: _muted,
                    ),
                  ),
              ],
            ),

            pw.SizedBox(height: 6),

            // ----------------------------------------------------
            // IMAGE
            //
            // The image is constrained to a fixed box so it can
            // never request more height than an A4 page has left,
            // which is what used to trigger TooManyPagesException.
            // ----------------------------------------------------

            if (isImage && image != null)
              pw.Container(
                width: _kMaxPdfImageWidth,
                height: _kMaxPdfImageHeight,
                alignment: pw.Alignment.center,
                child: pw.ClipRRect(
                  horizontalRadius: 8,
                  verticalRadius: 8,
                  child: pw.Image(
                    image,
                    width: _kMaxPdfImageWidth,
                    height: _kMaxPdfImageHeight,
                    fit: pw.BoxFit.contain,
                  ),
                ),
              ),

            if (isImage && image == null)
              pw.Text(
                '[image unavailable]',
                style: const pw.TextStyle(
                  fontSize: 10,
                  color: _muted,
                ),
              ),

            // ----------------------------------------------------
            // Image note / caption
            // ----------------------------------------------------

            if (isImage && text.trim().isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(
                  top: 6,
                ),
                child: pw.Text(
                  text,
                  style: const pw.TextStyle(
                    fontSize: 10.5,
                    lineSpacing: 2,
                  ),
                ),
              ),

            // ----------------------------------------------------
            // Normal text
            // ----------------------------------------------------

            if (!isImage)
              pw.Text(
                text,
                style: const pw.TextStyle(
                  fontSize: 10.5,
                  lineSpacing: 2,
                ),
              ),

            if (edited)
              pw.Padding(
                padding: const pw.EdgeInsets.only(
                  top: 3,
                ),
                child: pw.Text(
                  '(edited)',
                  style: const pw.TextStyle(
                    fontSize: 7,
                    color: _muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------

  static String _previewOf(
    String text,
    int maxWords,
  ) {
    final normalized = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) {
      return '';
    }

    final words = normalized.split(' ');

    if (words.length <= maxWords) {
      return normalized;
    }

    return '${words.take(maxWords).join(' ')}…';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _formatFullDate(
    DateTime dt,
  ) {
    final local = dt.toLocal();

    return '${local.day} '
        '${_months[local.month - 1]} '
        '${local.year}';
  }

  static String _formatFullDateTime(
    DateTime dt,
  ) {
    final local = dt.toLocal();

    final hour12 =
        local.hour % 12 == 0
            ? 12
            : local.hour % 12;

    final minute =
        local.minute
            .toString()
            .padLeft(2, '0');

    final period =
        local.hour >= 12
            ? 'PM'
            : 'AM';

    return '${local.day} '
        '${_months[local.month - 1]} '
        '${local.year}, '
        '$hour12:$minute $period';
  }
}