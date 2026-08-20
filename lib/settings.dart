import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'data.dart';

// ================================================================
// Modular Settings Contracts & Shared Architecture
// ================================================================

/// Represents a distinct section in the Settings screen.
abstract class SettingsSection {
  String get title;
  List<Widget> buildTiles(BuildContext context);
}

/// A standard section header widget.
class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.6,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }
}

// ================================================================
// Enhanced Import / Export Service (ZIP & Disk Image Preservation)
// ================================================================

enum ImportMode { replace, merge }

class ReplacementHistory {
  final String timestamp;
  final String fileName;
  final String mode;

  ReplacementHistory({
    required this.timestamp,
    required this.fileName,
    required this.mode,
  });

  static Future<void> save(String fileName, ImportMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_import_timestamp', DateTime.now().toIso8601String());
    await prefs.setString('last_import_filename', fileName);
    await prefs.setString('last_import_mode', mode == ImportMode.replace ? 'Replace' : 'Add/Merge');
  }

  static Future<ReplacementHistory?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getString('last_import_timestamp');
    final fn = prefs.getString('last_import_filename');
    final md = prefs.getString('last_import_mode');

    if (ts == null || fn == null || md == null) return null;
    return ReplacementHistory(timestamp: ts, fileName: fn, mode: md);
  }
}

class ModularImportExportService {
  static const int formatVersion = 1;

  /// Creates a ZIP file containing `data.json` and all referenced disk images.
  static Future<String> exportToZipArchive() async {
    final db = await AppDatabase.instance.database;
    final folderRows = await db.query('folders', orderBy: 'name COLLATE NOCASE ASC');

    final folders = <Map<String, dynamic>>[];
    final archive = Archive();
    final addedImageFiles = <String>{};

    for (final folderRow in folderRows) {
      final folderId = folderRow['id'] as int;
      final messageRows = await db.query(
        'messages',
        where: 'folder_id = ?',
        whereArgs: [folderId],
        orderBy: 'seq ASC',
      );

      final exportedMessages = <Map<String, dynamic>>[];

      for (final m in messageRows) {
        final msgMap = <String, dynamic>{
          'id': m['id'],
          'text': m['text'],
          'type': m['type'],
          'source': m['source'] ?? 'user',
          'timestamp': m['timestamp'],
          'important': (m['important'] as int) == 1,
          'edited': (m['edited'] as int) == 1,
          'image_path': m['image_path'],
          'image_paths': m['image_paths'],
        };

        // Collect all images attached to this message
        final pathsToArchive = <String>[];
        if (m['image_path'] != null) pathsToArchive.add(m['image_path'] as String);
        if (m['image_paths'] != null) {
          try {
            final decoded = jsonDecode(m['image_paths'] as String);
            if (decoded is List) pathsToArchive.addAll(decoded.cast<String>());
          } catch (_) {}
        }

        // Add physical files to archive under an `images/` directory
        for (final imgPath in pathsToArchive) {
          if (imgPath.isNotEmpty && !addedImageFiles.contains(imgPath)) {
            final file = File(imgPath);
            if (await file.exists()) {
              final fileName = p.basename(imgPath);
              final bytes = await file.readAsBytes();
              archive.addFile(ArchiveFile('images/$fileName', bytes.length, bytes));
              addedImageFiles.add(imgPath);
            }
          }
        }

        exportedMessages.add(msgMap);
      }

      folders.add({
        'name': folderRow['name'],
        'created_at': folderRow['created_at'],
        'archived': (folderRow['archived'] as int? ?? 0) == 1,
        'messages': exportedMessages,
      });
    }

    final payload = {
      'app': 'excerpt',
      'schema_version': formatVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'folders': folders,
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(payload);
    final jsonBytes = utf8.encode(jsonString);
    archive.addFile(ArchiveFile('data.json', jsonBytes.length, jsonBytes));

    final zipEncoder = ZipEncoder();
    final zipData = zipEncoder.encode(archive);

    final base = await NativeBridge.getAppFilesDir();
    final dir = Directory(p.join(base, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);

    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final zipFile = File(p.join(dir.path, 'excerpt_backup_$stamp.zip'));
    await zipFile.writeAsBytes(zipData!);

    return zipFile.path;
  }

  /// Processes and imports data from a `.zip` file or legacy `.json` file.
  static Future<ImportResult> processImport(String filePath, ImportMode mode) async {
    final db = await AppDatabase.instance.database;
    final appFilesDir = await NativeBridge.getAppFilesDir();
    final mediaDir = Directory(p.join(appFilesDir, 'media'));
    if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

    String jsonContent = '';
    final mapExtractedImages = <String, String>{}; // archive path -> new local path
    final lowerPath = filePath.toLowerCase();

    // 1. Process ZIP Archives
    if (lowerPath.endsWith('.zip')) {
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? jsonFile;
      for (final file in archive) {
        if (file.name == 'data.json') {
          jsonFile = file;
        } else if (file.name.startsWith('images/') && file.isFile) {
          final fileName = p.basename(file.name);
          final localImageFile = File(p.join(mediaDir.path, fileName));
          await localImageFile.writeAsBytes(file.content as List<int>);
          mapExtractedImages[fileName] = localImageFile.path;
        }
      }

      if (jsonFile == null) {
        throw ImportValidationException('Archive missing data.json file.');
      }
      jsonContent = utf8.decode(jsonFile.content as List<int>);
    } 
    // 2. Process Legacy JSON Files
    else if (lowerPath.endsWith('.json')) {
      jsonContent = await File(filePath).readAsString();
    } 
    // 3. Fallback: Attempt to decode as ZIP first, then JSON if ZIP fails
    else {
      try {
        final bytes = await File(filePath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final jsonFile = archive.firstWhere(
          (f) => f.name == 'data.json',
          orElse: () => throw ImportValidationException('Archive missing data.json file.'),
        );
        
        for (final file in archive) {
          if (file.name.startsWith('images/') && file.isFile) {
            final fileName = p.basename(file.name);
            final localImageFile = File(p.join(mediaDir.path, fileName));
            await localImageFile.writeAsBytes(file.content as List<int>);
            mapExtractedImages[fileName] = localImageFile.path;
          }
        }
        jsonContent = utf8.decode(jsonFile.content as List<int>);
      } catch (_) {
        jsonContent = await File(filePath).readAsString();
      }
    }

    // Parse and validate extracted JSON content
    final preview = ImportExportService.validate(jsonContent);

    if (mode == ImportMode.replace) {
      await db.transaction((txn) async {
        await txn.delete('messages');
        await txn.delete('folders');
      });
    }

    var insertedFolders = 0;
    var insertedMessages = 0;
    var skippedMessages = 0;

    final folders = (preview.data['folders'] as List).cast<Map<String, dynamic>>();

    await db.transaction((txn) async {
      for (final folderEntry in folders) {
        final name = folderEntry['name'] as String;
        final folderRows = await txn.query('folders', where: 'name = ?', whereArgs: [name]);

        int folderId;
        if (folderRows.isEmpty) {
          folderId = await txn.insert('folders', {
            'name': name,
            'created_at': folderEntry['created_at'] as String? ?? DateTime.now().toIso8601String(),
            'archived': folderEntry['archived'] == true ? 1 : 0,
          });
          insertedFolders++;
        } else {
          folderId = folderRows.first['id'] as int;
        }

        final messages = (folderEntry['messages'] as List).cast<Map<String, dynamic>>();

        for (final m in messages) {
          final id = m['id'] as String;

          if (mode == ImportMode.merge) {
            final exists = await txn.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
            if (exists.isNotEmpty) {
              skippedMessages++;
              continue;
            }
          }

          final legacyType = m['type'] as String;
          final source = m['source'] as String? ?? (legacyType == 'system' ? 'system' : 'user');
          final normalizedType = legacyType == 'system' || legacyType == 'user' ? 'text' : legacyType;

          // Remap image paths to local restored paths if applicable
          String? restoredImagePath = m['image_path'] as String?;
          if (restoredImagePath != null && mapExtractedImages.containsKey(p.basename(restoredImagePath))) {
            restoredImagePath = mapExtractedImages[p.basename(restoredImagePath)];
          }

          String? restoredImagePaths = m['image_paths'] as String?;
          if (restoredImagePaths != null) {
            try {
              final decoded = jsonDecode(restoredImagePaths) as List;
              final remappedList = decoded.map((pStr) {
                final baseName = p.basename(pStr.toString());
                return mapExtractedImages[baseName] ?? pStr;
              }).toList();
              restoredImagePaths = jsonEncode(remappedList);
            } catch (_) {}
          }

          await txn.insert('messages', {
            'id': id,
            'folder_id': folderId,
            'text': m['text'] as String,
            'type': normalizedType,
            'source': source,
            'timestamp': m['timestamp'] as String,
            'important': m['important'] == true ? 1 : 0,
            'edited': m['edited'] == true ? 1 : 0,
            'image_path': restoredImagePath,
            'image_paths': restoredImagePaths,
          });
          insertedMessages++;
        }
      }
    });

    await ReplacementHistory.save(p.basename(filePath), mode);

    return ImportResult(
      insertedFolders: insertedFolders,
      insertedMessages: insertedMessages,
      skippedMessages: skippedMessages,
    );
  }
}

// ================================================================
// Settings Screen (Modular Main Entry)
// ================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool _defaultIme = false;
  bool _overlayEnabled = false;
  bool _notificationEnabled = false;
  bool _clipboardEnabled = false;
  bool _busy = false;

  ReplacementHistory? _lastReplacement;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
    _loadReplacementHistory();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    final ime = await NativeBridge.isExcerptDefaultIme();
    final overlay = await NativeBridge.canDrawOverlays();
    final notif = await NativeBridge.hasNotificationPermission();
    final clip = await NativeBridge.isClipboardEnabled();

    if (!mounted) return;
    setState(() {
      _defaultIme = ime;
      _overlayEnabled = overlay;
      _notificationEnabled = notif;
      _clipboardEnabled = clip;
    });
  }

  Future<void> _loadReplacementHistory() async {
    final history = await ReplacementHistory.load();
    if (!mounted) return;
    setState(() => _lastReplacement = history);
  }

  bool get _readyForToggle => _defaultIme && _overlayEnabled;

  Future<void> _toggleClipboard(bool value) async {
    if (value && !_readyForToggle) return;
    await NativeBridge.setClipboardEnabled(value);
    if (!mounted) return;
    setState(() => _clipboardEnabled = value);
  }

  // ---- Export Flow ----

  Future<void> _exportData() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final path = await ModularImportExportService.exportToZipArchive();
      await NativeBridge.shareFile(path);
      _showSnack('Export ready (.zip) — choose where to save or send it.');
    } catch (e) {
      _showSnack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Import Flow ----

  Future<void> _importData() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final path = await NativeBridge.pickImportFile();
      if (path == null) return; // User cancelled

      if (!mounted) return;
      final mode = await _showImportModeDialog();
      if (mode == null) return;

      final result = await ModularImportExportService.processImport(path, mode);
      await _loadReplacementHistory();

      final extra = result.skippedMessages > 0
          ? ' (${result.skippedMessages} existing messages skipped)'
          : '';

      _showSnack(
        'Successfully imported ${result.insertedMessages} message(s) into '
        '${result.insertedFolders} folder(s)$extra.',
      );
    } on ImportValidationException catch (e) {
      await _showErrorDialog(e.message);
    } catch (e) {
      await _showErrorDialog('Could not import file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ImportMode?> _showImportModeDialog() {
    return showDialog<ImportMode>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Select Import Option'),
          content: const Text(
            'Choose how you want to import this data backup:\n\n'
            '• Add new data: Keeps existing messages and appends new content.\n'
            '• Replace whole app data: Wipes all current messages/folders and restores exact backup.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, ImportMode.merge),
              child: const Text('Add new data'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, ImportMode.replace),
              child: const Text('Replace all data'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showErrorDialog(String message) {
    if (!mounted) return Future.value();
    return showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Import failed'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  List<SettingsSection> _buildSections() {
    return [
      PermissionsSection(
        defaultIme: _defaultIme,
        overlayEnabled: _overlayEnabled,
        notificationEnabled: _notificationEnabled,
        clipboardEnabled: _clipboardEnabled,
        readyForToggle: _readyForToggle,
        onToggleClipboard: _toggleClipboard,
      ),
      DataSection(
        busy: _busy,
        onExport: _exportData,
        onImport: _importData,
        lastReplacement: _lastReplacement,
      ),
      AboutSection(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sections = _buildSections();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: sections.expand((section) {
          return [
            _SectionHeader(section.title),
            const SizedBox(height: 8),
            ...section.buildTiles(context),
            const SizedBox(height: 16),
          ];
        }).toList(),
      ),
    );
  }
}

// ================================================================
// Modular Section Components
// ================================================================

class PermissionsSection implements SettingsSection {
  @override
  String get title => 'Permissions';

  final bool defaultIme;
  final bool overlayEnabled;
  final bool notificationEnabled;
  final bool clipboardEnabled;
  final bool readyForToggle;
  final Function(bool) onToggleClipboard;

  PermissionsSection({
    required this.defaultIme,
    required this.overlayEnabled,
    required this.notificationEnabled,
    required this.clipboardEnabled,
    required this.readyForToggle,
    required this.onToggleClipboard,
  });

  @override
  List<Widget> buildTiles(BuildContext context) {
    return [
      PermissionCard(
        icon: Icons.keyboard_alt_outlined,
        title: 'Set as default keyboard',
        description: 'Needed so Excerpt can stay active as system input and capture text.',
        granted: defaultIme,
        onTap: NativeBridge.openImeSettings,
      ),
      const SizedBox(height: 10),
      PermissionCard(
        icon: Icons.layers_outlined,
        title: 'Display over other apps',
        description: 'Lets Excerpt show the save popup above active apps.',
        granted: overlayEnabled,
        onTap: NativeBridge.requestOverlayPermission,
      ),
      const SizedBox(height: 10),
      PermissionCard(
        icon: Icons.notifications_none_rounded,
        title: 'Notifications',
        description: 'Shows status notification while keyboard is active.',
        granted: notificationEnabled,
        onTap: NativeBridge.requestNotificationPermission,
      ),
      const SizedBox(height: 10),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
        child: SwitchListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Clipboard listening'),
          subtitle: Text(
            !readyForToggle
                ? 'Grant required permissions above first'
                : clipboardEnabled
                    ? 'ON — Active system listener'
                    : 'OFF',
          ),
          value: clipboardEnabled,
          onChanged: readyForToggle ? onToggleClipboard : null,
        ),
      ),
    ];
  }
}

class DataSection implements SettingsSection {
  @override
  String get title => 'Data & Storage';

  final bool busy;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final ReplacementHistory? lastReplacement;

  DataSection({
    required this.busy,
    required this.onExport,
    required this.onImport,
    this.lastReplacement,
  });

  @override
  List<Widget> buildTiles(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            ListTile(
              leading: Icon(Icons.upload_file_outlined, color: scheme.primary),
              title: const Text('Export data (.zip)'),
              subtitle: const Text('Save messages, folders, and original images to a single archive.'),
              trailing: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right_rounded),
              onTap: busy ? null : onExport,
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.download_outlined, color: scheme.primary),
              title: const Text('Import data'),
              subtitle: const Text('Restore from backup file. Supports replacing or appending data.'),
              trailing: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right_rounded),
              onTap: busy ? null : onImport,
            ),
          ],
        ),
      ),
      if (lastReplacement != null) ...[
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.withOpacity(0.2)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last Import Operation',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: scheme.primary),
                ),
                const SizedBox(height: 4),
                Text('File: ${lastReplacement!.fileName}', style: const TextStyle(fontSize: 12)),
                Text('Mode: ${lastReplacement!.mode}', style: const TextStyle(fontSize: 12)),
                Text('Date: ${lastReplacement!.timestamp}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ],
    ];
  }
}

class AboutSection implements SettingsSection {
  @override
  String get title => 'About';

  @override
  List<Widget> buildTiles(BuildContext context) {
    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
        child: ExpansionTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('About Excerpt'),
          subtitle: const Text('Version v4.7.0'),
          children: const [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Excerpt is your intelligent clipboard and snippet management system. '
                'It organizes captured text, grouped image messages, and metadata directly '
                'on disk to ensure seamless cross-device synchronization and backup capability.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

// ================================================================
// Reusable Permission Row
// ================================================================

class PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool granted;
  final Future<void> Function() onTap;

  const PermissionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: granted ? scheme.primary.withOpacity(0.5) : Colors.grey.withOpacity(0.25),
        ),
        color: granted ? scheme.primary.withOpacity(0.06) : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(icon, color: scheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          description,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: granted
              ? const Icon(Icons.check_circle_rounded, color: Colors.teal, key: ValueKey('granted'))
              : OutlinedButton(
                  key: const ValueKey('grant'),
                  onPressed: onTap,
                  child: const Text('Grant'),
                ),
        ),
      ),
    );
  }
}