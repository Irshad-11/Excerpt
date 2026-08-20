import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'data.dart';
import 'folder_screen.dart' show FolderScreen;
import 'pdf_export.dart';
import 'search_screen.dart' show GlobalSearchScreen;
import 'settings.dart' show SettingsScreen;

// ================================================================
// Brand asset URLs — update these if the logo/GIF ever move.
// ================================================================

const String kMainLogoUrl =
    'https://raw.githubusercontent.com/Irshad-11/Documents/refs/heads/main/ExcerptLogoHQ.png';
const String kBrandGifUrl =
    'https://raw.githubusercontent.com/Irshad-11/Documents/refs/heads/main/logo5-ezgif.gif';

// ================================================================
// Home screen
// ================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _clipboardEnabled = false;
  bool _defaultIme = false;
  bool _overlayEnabled = false;

  List<FolderSummary> _folders = [];
  int _archivedCount = 0;

  bool _loading = true;
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeBridge.setPendingTextHandler(_onPendingText);
    _refreshAll();
    _checkPendingOnStart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
      _checkPendingOnStart();
    }
  }

  Future<void> _refreshAll() async {
    await _refreshPermissions();
    await _refreshFolders();
  }

  Future<void> _refreshPermissions() async {
    final enabled = await NativeBridge.isClipboardEnabled();
    final ime = await NativeBridge.isExcerptDefaultIme();
    final overlay = await NativeBridge.canDrawOverlays();
    if (!mounted) return;
    setState(() {
      _clipboardEnabled = enabled;
      _defaultIme = ime;
      _overlayEnabled = overlay;
    });
  }

  Future<void> _refreshFolders() async {
    final active = await FolderStore.listFolderSummaries(archived: false);
    final archived = await FolderStore.listFolderSummaries(archived: true);
    if (!mounted) return;
    setState(() {
      _folders = active;
      _archivedCount = archived.length;
      _loading = false;
    });
  }

  Future<void> _checkPendingOnStart() async {
    final text = await NativeBridge.getPendingClipText();
    if (text != null && text.isNotEmpty) _onPendingText(text);
  }

  void _onPendingText(String text) {
    NativeBridge.clearPendingClipText();
    if (_pickerOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showFolderPicker(text);
    });
  }

  Future<void> _toggleClipboard(bool value) async {
    if (value && (!_defaultIme || !_overlayEnabled)) {
      _openSettings();
      return;
    }
    await NativeBridge.setClipboardEnabled(value);
    if (!mounted) return;
    setState(() => _clipboardEnabled = value);
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    ).then((_) => _refreshAll());
  }

  void _openGlobalSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GlobalSearchScreen()),
    );
  }

  void _openArchive() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ArchiveScreen()),
    ).then((_) => _refreshFolders());
  }

  // Fallback path for text pending when the app is opened directly —
  // the overlay itself handles folder picking for normal captures.
  Future<void> _showFolderPicker(String text) async {
    _pickerOpen = true;
    await _refreshFolders();
    if (!mounted) {
      _pickerOpen = false;
      return;
    }

    final controller = TextEditingController();
    final names = _folders.map((f) => f.name).toList();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Save captured text',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 12),
              if (names.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No folders yet. Create one below.'),
                ),
              ...names.map((folder) {
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folder),
                  onTap: () async {
                    await FolderStore.appendSystemMessage(folder, text);
                    if (ctx.mounted) Navigator.pop(ctx);
                    _openFolder(folder);
                  },
                );
              }),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      decoration:
                          const InputDecoration(hintText: 'New folder name'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: Colors.teal),
                    onPressed: () async {
                      final name = controller.text.trim();
                      if (name.isEmpty) return;
                      await FolderStore.createFolder(name);
                      await FolderStore.appendSystemMessage(name, text);
                      if (ctx.mounted) Navigator.pop(ctx);
                      _openFolder(name);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );

    _pickerOpen = false;
  }

  void _openFolder(String folder) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FolderScreen(folderName: folder)),
    ).then((_) => _refreshFolders());
  }

  Future<void> _createFolderDialog() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('New Folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Folder name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  await FolderStore.createFolder(name);
                  await _refreshFolders();
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const _BrandTitle(),
        actions: [
          IconButton(
            tooltip: 'Search all folders',
            onPressed: _openGlobalSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: 'New folder',
            onPressed: _createFolderDialog,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    child: SwitchListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      title: const Text('Clipboard listening'),
                      subtitle: Text(
                        _clipboardEnabled
                            ? 'ON — Excerpt is active as the system keyboard'
                            : 'OFF',
                      ),
                      value: _clipboardEnabled,
                      onChanged: _toggleClipboard,
                    ),
                  ),
                  if (!_defaultIme || !_overlayEnabled)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: Colors.orange.shade800),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Some permissions are missing — open Settings to fix.',
                              style: TextStyle(
                                  color: Colors.orange.shade800, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
                    child: Text(
                      'Your chats',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  if (_archivedCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: _openArchive,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest
                                  .withOpacity(0.5),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.archive_outlined,
                                    color: scheme.primary),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text('Archived',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: scheme.primary)),
                                ),
                                Text('$_archivedCount',
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 12)),
                                const SizedBox(width: 4),
                                const Icon(Icons.chevron_right_rounded,
                                    size: 20),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_folders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 60),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.folder_off_outlined,
                                size: 40, color: Colors.grey.shade400),
                            const SizedBox(height: 8),
                            Text(
                              'No folders yet.\nCopy text somewhere to get started.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._folders.map(
                      (f) => FolderTile(
                        summary: f,
                        onTap: () => _openFolder(f.name),
                        onChanged: _refreshFolders,
                        allFolderNames:
                            _folders.map((e) => e.name).toList(),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ================================================================
// Archive screen — same folder list UI, archived folders only.
// ================================================================

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<FolderSummary> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final archived = await FolderStore.listFolderSummaries(archived: true);
    if (!mounted) return;
    setState(() {
      _folders = archived;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Archive')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _folders.isEmpty
              ? Center(
                  child: Text('No archived chats.',
                      style: TextStyle(color: Colors.grey.shade600)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: _folders
                        .map(
                          (f) => FolderTile(
                            summary: f,
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      FolderScreen(folderName: f.name),
                                ),
                              ).then((_) => _load());
                            },
                            onChanged: _load,
                            allFolderNames:
                                _folders.map((e) => e.name).toList(),
                          ),
                        )
                        .toList(),
                  ),
                ),
    );
  }
}

// ================================================================
// Folder tile — chat preview card + three-dot menu.
// Shared between HomeScreen and ArchiveScreen.
// ================================================================

class FolderTile extends StatelessWidget {
  final FolderSummary summary;
  final VoidCallback onTap;
  final Future<void> Function() onChanged;
  final List<String> allFolderNames;

  const FolderTile({
    super.key,
    required this.summary,
    required this.onTap,
    required this.onChanged,
    required this.allFolderNames,
  });

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: summary.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == summary.name) return;

    try {
      await FolderStore.renameFolder(summary.name, newName);
      await onChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete folder?'),
        content: Text(
            '"${summary.name}" and all ${summary.totalMessages} message(s) in it will be deleted permanently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade400),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await FolderStore.deleteFolder(summary.name);
    await onChanged();
  }

  Future<void> _toggleArchive(BuildContext context) async {
    await FolderStore.setArchived(summary.name, !summary.archived);
    await onChanged();
  }

  Future<void> _mergeInto(BuildContext context) async {
    final targets =
        allFolderNames.where((n) => n != summary.name).toList();

    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Move / merge "${summary.name}" into…',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              'Its messages will be added to the chosen folder and this folder will be removed.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            if (targets.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No other folders to merge into yet.'),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(
                shrinkWrap: true,
                children: targets
                    .map((f) => ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(f),
                          onTap: () => Navigator.pop(ctx, f),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    if (target == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Merge folders?'),
        content: Text(
            'All messages from "${summary.name}" will move into "$target". This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await FolderStore.mergeFolderInto(summary.name, target);
    await onChanged();
  }

  Future<void> _downloadPdf(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing PDF…'), duration: Duration(seconds: 2)),
    );
    try {
      final path = await PdfExportService.exportFolderToPdf(summary.name);
      await NativeBridge.shareFile(path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
    }
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.4),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(context);
              },
            ),
            ListTile(
              leading: Icon(
                  summary.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(summary.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleArchive(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move / Merge into…'),
              onTap: () {
                Navigator.pop(ctx);
                _mergeInto(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Download as PDF'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadPdf(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
              title: Text('Delete', style: TextStyle(color: Colors.red.shade400)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: () => _showMenu(context),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.16)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.folder, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              summary.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ),
                          if (summary.lastUpdated != null)
                            Text(
                              _relativeTime(summary.lastUpdated!),
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey.shade500),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        summary.lastMessagePreview?.trim().isNotEmpty == true
                            ? summary.lastMessagePreview!
                            : 'No messages yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        children: [
                          _statChip(Icons.forum_outlined, '${summary.totalMessages}'),
                          _statChip(Icons.notes_rounded, '${summary.textCount}'),
                          _statChip(Icons.image_outlined, '${summary.imageCount}'),
                          _statChip(Icons.event_outlined,
                              _shortDate(summary.createdAt)),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _showMenu(context),
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.grey.shade500),
        const SizedBox(width: 3),
        Text(value, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _shortDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.day} ${_months[dt.month - 1]}';
  }

  String _relativeTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return _shortDate(iso);
  }
}

// ================================================================
// Brand title — custom display font + logo/GIF crossfade.
// The rest of the app keeps the system default font; only this
// header mark uses a distinct typeface, per design request.
// ================================================================

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _BrandMark(size: 30),
        const SizedBox(width: 10),
        Text(
          'Excerpt',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/// Shows the static main logo first. Once it — and the GIF — have
/// both been confirmed loadable, it periodically crossfades to the
/// animated GIF for a few seconds, then back. If the GIF (or even
/// the main logo) fails to load, it quietly falls back to a plain
/// icon instead of showing a broken-image glyph.
class _BrandMark extends StatefulWidget {
  final double size;
  const _BrandMark({required this.size});

  @override
  State<_BrandMark> createState() => _BrandMarkState();
}

class _BrandMarkState extends State<_BrandMark> {
  bool _logoReady = false;
  bool _gifReady = false;
  bool _logoFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _preload());
  }

  Future<void> _preload() async {
    // ১. প্রথমে মেইন লোগো লোড হবে
    try {
      await precacheImage(const NetworkImage(kMainLogoUrl), context);
      if (mounted) setState(() => _logoReady = true);
    } catch (_) {
      if (mounted) setState(() => _logoFailed = true);
    }

    // ২. ব্যাকগ্রাউন্ডে GIF ফেচ হবে
    try {
      await precacheImage(const NetworkImage(kBrandGifUrl), context);
      if (mounted) {
        setState(() {
          _gifReady = true; // ফেচ শেষ হওয়ামাত্র সবসময় GIF শো করবে
        });
      }
    } catch (_) {
      // GIF লোড করতে ব্যর্থ হলে স্ট্যাটিক লোগোটাই থেকে যাবে
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;

    if (_logoFailed && !_gifReady) {
      return Icon(
        Icons.content_paste_go_rounded,
        size: size,
        color: Theme.of(context).colorScheme.primary,
      );
    }

    if (!_logoReady && !_gifReady) {
      return SizedBox(width: size, height: size);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: SizedBox(
          key: ValueKey(_gifReady),
          width: size,
          height: size,
          child: Image.network(
            _gifReady ? kBrandGifUrl : kMainLogoUrl,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Icon(
              Icons.content_paste_go_rounded,
              size: size,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}