import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

// ================================================================
// Native bridge
// ================================================================

class NativeBridge {
  static const _channel = MethodChannel('com.excerpt/native');

  static Future<String> getAppFilesDir() async {
    final value = await _channel.invokeMethod<String>('getAppFilesDir');
    return value!;
  }

  static Future<bool> isClipboardEnabled() async {
    final value = await _channel.invokeMethod<bool>('isClipboardEnabled');
    return value ?? false;
  }

  static Future<void> setClipboardEnabled(bool value) {
    return _channel.invokeMethod('setClipboardEnabled', value);
  }

  static Future<bool> isExcerptDefaultIme() async {
    final value = await _channel.invokeMethod<bool>('isExcerptDefaultIme');
    return value ?? false;
  }

  static Future<void> openImeSettings() {
    return _channel.invokeMethod('openImeSettings');
  }

  static Future<void> openInputMethodPicker() {
    return _channel.invokeMethod('openInputMethodPicker');
  }

  static Future<bool> canDrawOverlays() async {
    final value = await _channel.invokeMethod<bool>('canDrawOverlays');
    return value ?? false;
  }

  static Future<void> requestOverlayPermission() {
    return _channel.invokeMethod('requestOverlayPermission');
  }

  static Future<bool> hasNotificationPermission() async {
    final value =
        await _channel.invokeMethod<bool>('hasNotificationPermission');
    return value ?? false;
  }

  static Future<void> requestNotificationPermission() {
    return _channel.invokeMethod('requestNotificationPermission');
  }

  static Future<String?> getPendingClipText() {
    return _channel.invokeMethod<String>('getPendingClipText');
  }

  static Future<void> clearPendingClipText() {
    return _channel.invokeMethod('clearPendingClipText');
  }

  static void setPendingTextHandler(void Function(String text) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingClipText') {
        final value = call.arguments as String;
        handler(value);
      }
    });
  }

  /// Opens the native "share / save" sheet for the file at [path].
  static Future<void> shareFile(String path) {
    return _channel.invokeMethod('shareFile', path);
  }

  /// Opens a native document picker (filtered to `.json`) and returns
  /// the local path of the picked file, or `null` if cancelled.
  static Future<String?> pickImportFile() {
    return _channel.invokeMethod<String>('pickImportFile');
  }

  /// Saves the image at [path] into the device's public gallery
  /// (Pictures/Excerpt on Android, via MediaStore). The native side
  /// of this call (MainActivity.kt) ships in the next batch — this
  /// stub lets the UI be wired up now without breaking the build.
  static Future<void> saveImageToGallery(String path) {
    return _channel.invokeMethod('saveImageToGallery', path);
  }
}

// ================================================================
// Onboarding flag
// ================================================================

class OnboardingStore {
  static Future<File> _flagFile() async {
    final base = await NativeBridge.getAppFilesDir();
    return File('$base/onboarding_done.flag');
  }

  static Future<bool> isDone() async {
    final file = await _flagFile();
    return file.exists();
  }

  static Future<void> markDone() async {
    final file = await _flagFile();
    await file.writeAsString('done');
  }
}

// ================================================================
// SQLite database — schema + migrations
// ================================================================
//
// v3 splits the old single `type` column (which used to mean three
// different things: 'system'/'user'/'image') into two clear columns:
//
//   type   — WHAT the message is:   'text' | 'image'
//   source — WHO sent it:           'user' | 'system'
//
// Migration backfills existing rows: old type='system' -> source
// 'system'; everything else defaults to source='user' (matches
// reality, since every existing image was added by hand in the
// composer). Old type='system'/'user' both collapse into type='text'.
//
// IMPORTANT: android/.../ExcerptDatabaseHelper.kt mirrors this same
// schema on the native side (same physical SQLite file) — its
// DATABASE_VERSION and onUpgrade() must be bumped in lockstep with
// this file, or the two sides silently disagree (this bit us once
// already: a mismatched version made the native side treat the file
// as a "downgrade" and quietly fail to read folders).
// ================================================================

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const int schemaVersion = 3;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _opening ??= _open();
    _db = await _opening;
    return _db!;
  }

  Future<Database> _open() async {
    final base = await NativeBridge.getAppFilesDir();
    final dbDir = Directory(base);
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    final path = p.join(base, 'excerpt.db');

    return openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createV1(db);
        await _upgradeToV2(db);
        await _upgradeToV3(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _upgradeToV2(db);
        }
        if (oldVersion < 3) {
          await _upgradeToV3(db);
        }
      },
    );
  }

  Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        folder_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'system',
        timestamp TEXT NOT NULL,
        important INTEGER NOT NULL DEFAULT 0,
        edited INTEGER NOT NULL DEFAULT 0,
        extra TEXT,
        FOREIGN KEY (folder_id) REFERENCES folders (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
        'CREATE INDEX idx_messages_folder ON messages (folder_id)');
    await db.execute(
        'CREATE INDEX idx_messages_timestamp ON messages (timestamp)');

    await db.execute('''
      CREATE TABLE app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _upgradeToV2(Database db) async {
    await _addColumnIfMissing(
        db, 'folders', 'archived', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'messages', 'image_path', 'TEXT');
  }

  Future<void> _upgradeToV3(Database db) async {
    final added = await _addColumnIfMissing(
        db, 'messages', 'source', "TEXT NOT NULL DEFAULT 'user'");

    if (added) {
      // Backfill from the old overloaded `type` column, then
      // normalise `type` down to just 'text' | 'image'.
      await db.execute(
          "UPDATE messages SET source = 'system' WHERE type = 'system'");
      await db.execute(
          "UPDATE messages SET type = 'text' WHERE type IN ('system', 'user')");
    }
  }

  Future<bool> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final exists = cols.any((c) => c['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
      return true;
    }
    return false;
  }
}

// ================================================================
// Folder summary
// ================================================================

class FolderSummary {
  final String name;
  final String createdAt;
  final bool archived;
  final int totalMessages;
  final int textCount;
  final int imageCount;
  final String? lastUpdated;
  final String? lastMessagePreview;

  const FolderSummary({
    required this.name,
    required this.createdAt,
    required this.archived,
    required this.totalMessages,
    required this.textCount,
    required this.imageCount,
    this.lastUpdated,
    this.lastMessagePreview,
  });

  factory FolderSummary.empty(String name) => FolderSummary(
        name: name,
        createdAt: DateTime.now().toIso8601String(),
        archived: false,
        totalMessages: 0,
        textCount: 0,
        imageCount: 0,
      );
}

// ================================================================
// Folder / message storage (SQLite-backed)
// ================================================================

class FolderStore {
  static Future<Database> get _db async => AppDatabase.instance.database;

  static Future<int> _folderId(String name, {bool create = true}) async {
    final db = await _db;
    final rows =
        await db.query('folders', where: 'name = ?', whereArgs: [name]);

    if (rows.isNotEmpty) return rows.first['id'] as int;

    if (!create) {
      throw StateError('Folder "$name" does not exist');
    }

    final insertedId = await db.insert(
      'folders',
      {
        'name': name,
        'created_at': DateTime.now().toIso8601String(),
        'archived': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    if (insertedId != 0) return insertedId;

    final again =
        await db.query('folders', where: 'name = ?', whereArgs: [name]);
    return again.first['id'] as int;
  }

  // ---- Folder listing ----

  static Future<List<String>> listFolders({bool archived = false}) async {
    final db = await _db;
    final rows = await db.query(
      'folders',
      where: 'archived = ?',
      whereArgs: [archived ? 1 : 0],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map((r) => r['name'] as String).toList();
  }

  static Future<void> createFolder(String name) async {
    await _folderId(name, create: true);
  }

  // ---- Folder CRUD: rename / delete ----

  static Future<void> renameFolder(String oldName, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;

    final db = await _db;
    final clash =
        await db.query('folders', where: 'name = ?', whereArgs: [trimmed]);
    if (clash.isNotEmpty) {
      throw StateError('A folder named "$trimmed" already exists.');
    }

    await db.update(
      'folders',
      {'name': trimmed},
      where: 'name = ?',
      whereArgs: [oldName],
    );
  }

  static Future<void> deleteFolder(String name) async {
    final db = await _db;
    await db.delete('folders', where: 'name = ?', whereArgs: [name]);
  }

  // ---- Archive ----

  static Future<void> setArchived(String name, bool archived) async {
    final db = await _db;
    await db.update(
      'folders',
      {'archived': archived ? 1 : 0},
      where: 'name = ?',
      whereArgs: [name],
    );
  }

  static Future<void> archiveFolder(String name) => setArchived(name, true);
  static Future<void> unarchiveFolder(String name) =>
      setArchived(name, false);

  // ---- Merge ----

  static Future<void> mergeFolderInto(
    String sourceFolder,
    String targetFolder,
  ) async {
    if (sourceFolder == targetFolder) return;

    final db = await _db;
    final sourceId = await _folderId(sourceFolder, create: false);
    final targetId = await _folderId(targetFolder, create: true);

    await db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        where: 'folder_id = ?',
        whereArgs: [sourceId],
        orderBy: 'seq ASC',
      );

      for (final row in rows) {
        await txn.insert('messages', {
          'id': '${DateTime.now().microsecondsSinceEpoch}_${row['seq']}',
          'folder_id': targetId,
          'text': row['text'],
          'type': row['type'],
          'source': row['source'],
          'timestamp': row['timestamp'],
          'important': row['important'],
          'edited': row['edited'],
          'image_path': row['image_path'],
        });
      }

      await txn.delete('folders', where: 'id = ?', whereArgs: [sourceId]);
    });
  }

  // ---- Stats ----

  static Future<FolderSummary> getFolderSummary(String name) async {
    final db = await _db;
    final folderRows =
        await db.query('folders', where: 'name = ?', whereArgs: [name]);

    if (folderRows.isEmpty) return FolderSummary.empty(name);

    final row = folderRows.first;
    final folderId = row['id'] as int;

    return _summaryForFolderRow(db, row, folderId);
  }

  static Future<FolderSummary> _summaryForFolderRow(
    Database db,
    Map<String, dynamic> folderRow,
    int folderId,
  ) async {
    final countRow = await db.rawQuery('''
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN type = 'image' THEN 1 ELSE 0 END) AS images,
        MAX(timestamp) AS last_ts
      FROM messages WHERE folder_id = ?
    ''', [folderId]);

    final total = (countRow.first['total'] as int?) ?? 0;
    final images = (countRow.first['images'] as int?) ?? 0;
    final lastTs = countRow.first['last_ts'] as String?;

    String? preview;
    if (lastTs != null) {
      final lastRow = await db.query(
        'messages',
        where: 'folder_id = ?',
        whereArgs: [folderId],
        orderBy: 'seq DESC',
        limit: 1,
      );
      if (lastRow.isNotEmpty) {
        preview = lastRow.first['text'] as String?;
      }
    }

    return FolderSummary(
      name: folderRow['name'] as String,
      createdAt: folderRow['created_at'] as String,
      archived: (folderRow['archived'] as int? ?? 0) == 1,
      totalMessages: total,
      textCount: total - images,
      imageCount: images,
      lastUpdated: lastTs,
      lastMessagePreview: preview,
    );
  }

  static Future<List<FolderSummary>> listFolderSummaries({
    bool archived = false,
  }) async {
    final db = await _db;
    final folderRows = await db.query(
      'folders',
      where: 'archived = ?',
      whereArgs: [archived ? 1 : 0],
      orderBy: 'name COLLATE NOCASE ASC',
    );

    final results = <FolderSummary>[];
    for (final row in folderRows) {
      final folderId = row['id'] as int;
      results.add(await _summaryForFolderRow(db, row, folderId));
    }
    return results;
  }

  // ---- Messages ----

  static Map<String, dynamic> _rowToMessage(Map<String, dynamic> row) {
    return {
      'id': row['id'] as String,
      'text': row['text'] as String,
      'type': row['type'] as String,
      'source': (row['source'] as String?) ?? 'user',
      'timestamp': row['timestamp'] as String,
      'important': (row['important'] as int) == 1,
      'edited': (row['edited'] as int) == 1,
      'image_path': row['image_path'] as String?,
    };
  }

  static Future<List<Map<String, dynamic>>> readMessages(
    String folder,
  ) async {
    final db = await _db;
    final folderRows =
        await db.query('folders', where: 'name = ?', whereArgs: [folder]);

    if (folderRows.isEmpty) return [];

    final folderId = folderRows.first['id'] as int;
    final rows = await db.query(
      'messages',
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: 'seq ASC',
    );

    return rows.map(_rowToMessage).toList();
  }

  static Future<void> _appendMessage(
    String folder,
    String text,
    String type, {
    String source = 'user',
    String? imagePath,
  }) async {
    final db = await _db;
    final folderId = await _folderId(folder);

    await db.insert('messages', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'folder_id': folderId,
      'text': text,
      'type': type,
      'source': source,
      'timestamp': DateTime.now().toIso8601String(),
      'important': 0,
      'edited': 0,
      'image_path': imagePath,
    });
  }

  /// Text captured from another app via the overlay/clipboard.
  static Future<void> appendSystemMessage(String folder, String text) {
    return _appendMessage(folder, text, 'text', source: 'system');
  }

  /// Text the user typed directly inside the app.
  static Future<void> appendUserMessage(String folder, String text) {
    return _appendMessage(folder, text, 'text', source: 'user');
  }

  /// An image attachment. [source] defaults to 'user' (composer /
  /// picker) — the Android share-target writes 'system' directly to
  /// SQLite for images that arrive via the OS share sheet.
  static Future<void> appendImageMessage(
    String folder,
    String imagePath, {
    String caption = '',
    String source = 'user',
  }) {
    return _appendMessage(folder, caption, 'image',
        source: source, imagePath: imagePath);
  }

  static Future<void> deleteMessages(String folder, Set<String> ids) async {
    if (ids.isEmpty) return;

    final db = await _db;
    final folderRows =
        await db.query('folders', where: 'name = ?', whereArgs: [folder]);
    if (folderRows.isEmpty) return;

    final folderId = folderRows.first['id'] as int;
    final placeholders = List.filled(ids.length, '?').join(',');

    await db.delete(
      'messages',
      where: 'folder_id = ? AND id IN ($placeholders)',
      whereArgs: [folderId, ...ids],
    );
  }

  static Future<void> updateMessageText(
    String folder,
    String id,
    String newText,
  ) async {
    final db = await _db;

    try {
      final folderId = await _folderId(folder, create: false);
      await db.update(
        'messages',
        {'text': newText, 'edited': 1},
        where: 'folder_id = ? AND id = ?',
        whereArgs: [folderId, id],
      );
    } on StateError {
      // Folder disappeared under us — nothing to update.
    }
  }

  static Future<void> setImportant(
    String folder,
    String id,
    bool important,
  ) async {
    final db = await _db;

    try {
      final folderId = await _folderId(folder, create: false);
      await db.update(
        'messages',
        {'important': important ? 1 : 0},
        where: 'folder_id = ? AND id = ?',
        whereArgs: [folderId, id],
      );
    } on StateError {
      // Folder disappeared under us — nothing to update.
    }
  }

  static Future<void> copyMessageToFolder(
    String targetFolder,
    Map<String, dynamic> message,
  ) async {
    final db = await _db;
    final folderId = await _folderId(targetFolder);

    await db.insert('messages', {
      'id': '${DateTime.now().microsecondsSinceEpoch}_${message.hashCode}',
      'folder_id': folderId,
      'text': message['text'] as String,
      'type': (message['type'] as String?) ?? 'text',
      'source': (message['source'] as String?) ?? 'user',
      'timestamp': DateTime.now().toIso8601String(),
      'important': message['important'] == true ? 1 : 0,
      'edited': 0,
      'image_path': message['image_path'] as String?,
    });
  }
}

// ================================================================
// Import / export
// ================================================================

class ImportValidationException implements Exception {
  final String message;
  ImportValidationException(this.message);

  @override
  String toString() => message;
}

class ImportPreview {
  final int schemaVersion;
  final int folderCount;
  final int messageCount;
  final Map<String, dynamic> data;

  ImportPreview({
    required this.schemaVersion,
    required this.folderCount,
    required this.messageCount,
    required this.data,
  });
}

class ImportResult {
  final int insertedFolders;
  final int insertedMessages;
  final int skippedMessages;

  ImportResult({
    required this.insertedFolders,
    required this.insertedMessages,
    required this.skippedMessages,
  });
}

class ImportExportService {
  static const int formatVersion = 1;

  static Future<String> exportToJsonString() async {
    final db = await AppDatabase.instance.database;
    final folderRows =
        await db.query('folders', orderBy: 'name COLLATE NOCASE ASC');

    final folders = <Map<String, dynamic>>[];

    for (final folderRow in folderRows) {
      final folderId = folderRow['id'] as int;
      final messageRows = await db.query(
        'messages',
        where: 'folder_id = ?',
        whereArgs: [folderId],
        orderBy: 'seq ASC',
      );

      folders.add({
        'name': folderRow['name'],
        'created_at': folderRow['created_at'],
        'archived': (folderRow['archived'] as int? ?? 0) == 1,
        'messages': messageRows
            .map((m) => {
                  'id': m['id'],
                  'text': m['text'],
                  'type': m['type'],
                  'source': m['source'] ?? 'user',
                  'timestamp': m['timestamp'],
                  'important': (m['important'] as int) == 1,
                  'edited': (m['edited'] as int) == 1,
                  'image_path': m['image_path'],
                })
            .toList(),
      });
    }

    final payload = {
      'app': 'excerpt',
      'schema_version': formatVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'folders': folders,
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Future<String> exportToFile() async {
    final json = await exportToJsonString();

    final base = await NativeBridge.getAppFilesDir();
    final dir = Directory(p.join(base, 'exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final stamp =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, 'excerpt_export_$stamp.json'));
    await file.writeAsString(json);

    return file.path;
  }

  static ImportPreview validate(String jsonString) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (_) {
      throw ImportValidationException('That file is not valid JSON.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw ImportValidationException('Unrecognised export file format.');
    }

    final version = decoded['schema_version'];
    if (version is! int) {
      throw ImportValidationException(
          'That file is missing a schema_version and can\'t be imported.');
    }
    if (version > formatVersion) {
      throw ImportValidationException(
        'This file was exported by a newer version of Excerpt '
        '(format $version, this app supports up to $formatVersion). '
        'Update the app before importing it.',
      );
    }

    final foldersRaw = decoded['folders'];
    if (foldersRaw is! List) {
      throw ImportValidationException('No folders were found in that file.');
    }

    var folderCount = 0;
    var messageCount = 0;

    for (final folderEntry in foldersRaw) {
      if (folderEntry is! Map) {
        throw ImportValidationException('A folder entry is malformed.');
      }

      final name = folderEntry['name'];
      if (name is! String || name.trim().isEmpty) {
        throw ImportValidationException('A folder is missing its name.');
      }

      final messagesRaw = folderEntry['messages'];
      if (messagesRaw is! List) {
        throw ImportValidationException(
            'Folder "$name" doesn\'t have a message list.');
      }

      for (final messageEntry in messagesRaw) {
        if (messageEntry is! Map ||
            messageEntry['id'] is! String ||
            messageEntry['text'] is! String ||
            messageEntry['type'] is! String ||
            messageEntry['timestamp'] is! String) {
          throw ImportValidationException(
              'A message inside "$name" is missing required fields.');
        }
        messageCount++;
      }

      folderCount++;
    }

    return ImportPreview(
      schemaVersion: version,
      folderCount: folderCount,
      messageCount: messageCount,
      data: decoded,
    );
  }

  static Future<ImportResult> commit(ImportPreview preview) async {
    final db = await AppDatabase.instance.database;

    var insertedFolders = 0;
    var insertedMessages = 0;
    var skippedMessages = 0;

    final folders =
        (preview.data['folders'] as List).cast<Map<String, dynamic>>();

    await db.transaction((txn) async {
      for (final folderEntry in folders) {
        final name = folderEntry['name'] as String;

        final folderRows =
            await txn.query('folders', where: 'name = ?', whereArgs: [name]);

        int folderId;
        if (folderRows.isEmpty) {
          folderId = await txn.insert('folders', {
            'name': name,
            'created_at': folderEntry['created_at'] as String? ??
                DateTime.now().toIso8601String(),
            'archived': folderEntry['archived'] == true ? 1 : 0,
          });
          insertedFolders++;
        } else {
          folderId = folderRows.first['id'] as int;
        }

        final messages =
            (folderEntry['messages'] as List).cast<Map<String, dynamic>>();

        for (final m in messages) {
          final id = m['id'] as String;

          final exists = await txn
              .query('messages', where: 'id = ?', whereArgs: [id], limit: 1);

          if (exists.isNotEmpty) {
            skippedMessages++;
            continue;
          }

          // Older export files (pre-source-column) won't have
          // `source` — default it sensibly from the legacy `type`.
          final legacyType = m['type'] as String;
          final source = m['source'] as String? ??
              (legacyType == 'system' ? 'system' : 'user');
          final normalizedType =
              legacyType == 'system' || legacyType == 'user'
                  ? 'text'
                  : legacyType;

          await txn.insert('messages', {
            'id': id,
            'folder_id': folderId,
            'text': m['text'] as String,
            'type': normalizedType,
            'source': source,
            'timestamp': m['timestamp'] as String,
            'important': m['important'] == true ? 1 : 0,
            'edited': m['edited'] == true ? 1 : 0,
            'image_path': m['image_path'] as String?,
          });
          insertedMessages++;
        }
      }
    });

    return ImportResult(
      insertedFolders: insertedFolders,
      insertedMessages: insertedMessages,
      skippedMessages: skippedMessages,
    );
  }
}