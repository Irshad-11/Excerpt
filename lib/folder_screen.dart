import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import 'data.dart';
import 'search_screen.dart';

// ================================================================
// Folder screen — chat-style view with a composer + in-folder search
// ================================================================

List<String> imagePathsOf(Map<String, dynamic> message) {
  final list = message['image_paths'];
  if (list is List) return list.cast<String>();
  final single = message['image_path'] as String?;
  return single != null ? [single] : [];
}

Future<List<String>> pickAndSaveImages() async {
  final picker = ImagePicker();
  final picked = await picker.pickMultiImage(imageQuality: 85);
  if (picked.isEmpty) return [];

  final base = await NativeBridge.getAppFilesDir();
  final imagesDir = Directory(p.join(base, 'images'));
  if (!await imagesDir.exists()) {
    await imagesDir.create(recursive: true);
  }

  final saved = <String>[];
  for (final asset in picked) {
    final ext =
        p.extension(asset.path).isEmpty ? '.jpg' : p.extension(asset.path);
    final savedPath = p.join(
      imagesDir.path,
      '${DateTime.now().microsecondsSinceEpoch}_${asset.name}$ext'
          .replaceAll(RegExp(r'\.{2,}'), '.'),
    );
    await File(asset.path).copy(savedPath);
    saved.add(savedPath);
  }
  return saved;
}

class FolderScreen extends StatefulWidget {
  final String folderName;
  final String? initialMessageId;

  const FolderScreen({
    super.key,
    required this.folderName,
    this.initialMessageId,
  });

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};

  bool _sending = false;
  bool _pickingImages = false;
  final List<String> _pendingImages = [];

  bool _searchOpen = false;
  String _searchQuery = '';
  String? _highlightedMessageId;
  bool _initialTargetHandled = false;

  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load(scrollToEnd: true); // চ্যাটে ঢোকার সাথে সাথে নিচে স্ক্রোল করবে
    _searchController.addListener(() {
      final value = _searchController.text;
      if (!mounted) return;
      setState(() => _searchQuery = value);
    });
  }

  @override
  void dispose() {
    _composerController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---- Loading ----

  Future<void> _load({bool scrollToEnd = false}) async {
    final messages = await FolderStore.readMessages(widget.folderName);
    if (!mounted) return;

    setState(() {
      _messages = messages;
      _messageKeys.clear();
      for (final message in messages) {
        final id = message['id']?.toString();
        if (id != null) _messageKeys[id] = GlobalKey();
      }
    });

    if (scrollToEnd) {
      _scrollToBottom();
    }

    if (!_initialTargetHandled && widget.initialMessageId != null) {
      _initialTargetHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToMessage(widget.initialMessageId!, closeSearch: false);
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  // ---- Search ----

  void _openSearch() => setState(() => _searchOpen = true);

  void _closeSearch() {
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _searchOpen = false;
      _searchQuery = '';
    });
  }

  // ---- Scroll to exact message ----

  Future<void> _scrollToMessage(String id, {bool closeSearch = true}) async {
    final index =
        _messages.indexWhere((message) => message['id']?.toString() == id);
    if (index == -1) return;

    if (closeSearch) {
      FocusScope.of(context).unfocus();
      setState(() {
        _searchOpen = false;
        _searchQuery = '';
      });
      _searchController.clear();
      await Future.delayed(const Duration(milliseconds: 16));
    }

    if (!mounted) return;
    await _bringMessageIntoView(id, index);

    if (!mounted) return;
    setState(() => _highlightedMessageId = id);

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      if (_highlightedMessageId == id) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  Future<void> _bringMessageIntoView(String id, int index) async {
    if (!_scrollController.hasClients) return;

    final denom = (_messages.length - 1).clamp(1, 1 << 30);
    final fraction = index / denom;

    final maxExtentStart = _scrollController.position.maxScrollExtent;
    final viewport = _scrollController.position.viewportDimension;

    final startTarget =
        (fraction * maxExtentStart).clamp(0.0, maxExtentStart);
    _scrollController.jumpTo(startTarget);
    await Future.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;

    final step = viewport > 0 ? viewport * 0.85 : 400.0;
    const maxSteps = 30;

    for (var i = 0; i < maxSteps; i++) {
      final key = _messageKeys[id];
      if (key?.currentContext != null) break;
      if (!_scrollController.hasClients) return;

      final pixels = _scrollController.position.pixels;
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent <= 0) break;

      final targetGuess = (fraction * maxExtent).clamp(0.0, maxExtent);
      final next = targetGuess >= pixels
          ? (pixels + step).clamp(0.0, maxExtent)
          : (pixels - step).clamp(0.0, maxExtent);

      if (next == pixels) break;

      _scrollController.jumpTo(next);
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
    }

    final key = _messageKeys[id];
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
        alignment: 0.35,
      );
    }
  }

  // ---- Send ----

  Future<void> _send() async {
    if (_sending) return;

    final text = _composerController.text.trim();
    final images = List<String>.from(_pendingImages);
    if (text.isEmpty && images.isEmpty) return;

    setState(() => _sending = true);
    try {
      if (images.isNotEmpty) {
        await FolderStore.appendImageGroupMessage(
          widget.folderName,
          images,
          caption: text,
        );
      } else {
        await FolderStore.appendUserMessage(widget.folderName, text);
      }
      _composerController.clear();
      _pendingImages.clear();
      await _load(scrollToEnd: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---- Composer image attach ----

  Future<void> _pickImagesForComposer() async {
    setState(() => _pickingImages = true);
    try {
      final added = await pickAndSaveImages();
      if (added.isNotEmpty && mounted) {
        setState(() => _pendingImages.addAll(added));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add image: $e')));
      }
    } finally {
      if (mounted) setState(() => _pickingImages = false);
    }
  }

  void _removePendingImage(String path) {
    setState(() => _pendingImages.remove(path));
  }

  // ---- Selection mode ----

  void _enterSelectionMode(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _cancelSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;

    final confirmed = await _confirmDialog(
      title: count == 1 ? 'Delete message?' : 'Delete $count messages?',
      message: 'This can\'t be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    await FolderStore.deleteMessages(widget.folderName, _selectedIds);
    _cancelSelection();
    await _load();
  }

  Future<void> _copySelectedToFolder() async {
    final target = await _pickTargetFolder();
    if (target == null) return;

    final selected =
        _messages.where((m) => _selectedIds.contains(m['id'])).toList();

    for (final message in selected) {
      await FolderStore.copyMessageToFolder(target, message);
    }

    if (!mounted) return;
    _cancelSelection();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Copied to "$target"')));
  }

  // ---- Bubble tap dispatch ----

  void _onBubbleBorderTap(Map<String, dynamic> message) {
    if (_selectionMode) {
      _toggleSelected(message['id'] as String);
      return;
    }
    _showMessageActions(message);
  }

  void _onImageThumbTap(Map<String, dynamic> message, String path) {
    if (_selectionMode) {
      _toggleSelected(message['id'] as String);
      return;
    }
    _openImageViewer(message, path);
  }

  void _onBubbleLongPress(Map<String, dynamic> message) {
    if (_selectionMode) return;
    _enterSelectionMode(message['id'] as String);
  }

  // ---- Full-screen image viewer ----

  List<Map<String, dynamic>> _flattenImages() {
    final result = <Map<String, dynamic>>[];
    for (final m in _messages) {
      if (m['type'] != 'image') continue;
      final id = m['id'] as String;
      final caption = m['text'] as String? ?? '';
      for (final path in imagePathsOf(m)) {
        result.add({'messageId': id, 'path': path, 'caption': caption});
      }
    }
    return result;
  }

  void _openImageViewer(Map<String, dynamic> message, String tappedPath) async {
    final flat = _flattenImages();
    final startIndex = flat.indexWhere(
      (e) => e['messageId'] == message['id'] && e['path'] == tappedPath,
    );

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewerScreen(
          folderName: widget.folderName,
          images: flat,
          initialIndex: startIndex < 0 ? 0 : startIndex,
        ),
        fullscreenDialog: true,
      ),
    );

    if (changed == true) await _load();
  }

  Future<void> _showMessageActions(Map<String, dynamic> message) async {
    final id = message['id'] as String;
    final text = message['text'] as String? ?? '';
    final important = message['important'] == true;
    final isImage = message['type'] == 'image';
    final showCopy = !isImage || text.trim().isNotEmpty;

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
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
              if (showCopy)
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Copy'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: text));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(message);
                },
              ),
              ListTile(
                leading: Icon(
                  important ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: important ? Colors.amber.shade700 : null,
                ),
                title: Text(important ? 'Unmark important' : 'Mark important'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await FolderStore.setImportant(
                      widget.folderName, id, !important);
                  await _load();
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Select'),
                onTap: () {
                  Navigator.pop(ctx);
                  _enterSelectionMode(id);
                },
              ),
              ListTile(
                leading:
                    Icon(Icons.delete_outline, color: Colors.red.shade400),
                title: Text('Delete', style: TextStyle(color: Colors.red.shade400)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirmed = await _confirmDialog(
                    title: 'Delete message?',
                    message: 'This can\'t be undone.',
                    confirmLabel: 'Delete',
                    destructive: true,
                  );
                  if (confirmed != true) return;
                  await FolderStore.deleteMessages(widget.folderName, {id});
                  await _load();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editMessage(Map<String, dynamic> message) async {
    final id = message['id'] as String;
    final currentText = message['text'] as String? ?? '';
    final isImage = message['type'] == 'image';
    final currentImages = isImage ? imagePathsOf(message) : <String>[];

    final result = await Navigator.push<_EditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _EditMessageScreen(
          initialText: currentText,
          initialImages: currentImages,
          allowImages: isImage,
        ),
      ),
    );

    if (result == null) return;

    final newText = result.text.trim();
    final textChanged = newText != currentText;
    final imagesChanged =
        isImage && !_sameStringList(result.images, currentImages);

    if (!textChanged && !imagesChanged) return;

    if (textChanged) {
      await FolderStore.updateMessageText(widget.folderName, id, newText);
    }
    if (imagesChanged) {
      await FolderStore.updateMessageImages(
          widget.folderName, id, result.images);
    }
    await _load();
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: Colors.red.shade400)
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _pickTargetFolder() async {
    final allFolders = await FolderStore.listFolders();
    final folders = allFolders.where((f) => f != widget.folderName).toList();
    final controller = TextEditingController();

    return showModalBottomSheet<String>(
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
              const Text('Copy to folder',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              if (folders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('No other folders yet. Create one below.',
                      style: TextStyle(color: Colors.grey.shade600)),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: folders.map((folder) {
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(folder),
                      onTap: () => Navigator.pop(ctx, folder),
                    );
                  }).toList(),
                ),
              ),
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
                      if (ctx.mounted) Navigator.pop(ctx, name);
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
  }

  // ---- Local (in-folder) search results panel ----

  Widget _buildLocalSearchPanel() {
    if (!_searchOpen || _searchQuery.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final results = _messages.where((message) {
      final text = message['text']?.toString() ?? '';
      return messageMatchesQuery(text, _searchQuery);
    }).toList();

    if (results.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text('No matching messages'),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      constraints: const BoxConstraints(maxHeight: 230),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: Colors.black.withOpacity(0.08),
          ),
        ],
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        shrinkWrap: true,
        itemCount: results.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final message = results[index];
          final id = message['id']?.toString() ?? '';
          final text = message['text']?.toString() ?? '';

          final originalIndex =
              _messages.indexWhere((m) => m['id']?.toString() == id);

          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              child: Icon(
                message['type'] == 'image'
                    ? Icons.image_outlined
                    : message['source'] == 'user'
                        ? Icons.person_outline
                        : Icons.content_paste,
                size: 16,
              ),
            ),
            title: HighlightedText(
              text: makeSearchPreview(text, _searchQuery),
              query: _searchQuery,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '#${originalIndex + 1} of ${_messages.length}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
            onTap: () => _scrollToMessage(id),
          );
        },
      ),
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectionMode ? _selectionAppBar() : _defaultAppBar(),
      body: Column(
        children: [
          _buildLocalSearchPanel(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(scrollToEnd: false),
              child: _messages.isEmpty
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text('No messages yet.',
                                style: TextStyle(color: Colors.grey.shade600)),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        final id = message['id'] as String;
                        final isUser = message['source'] == 'user';
                        final isImage = message['type'] == 'image';

                        final key = _messageKeys[id] ?? GlobalKey();
                        _messageKeys[id] = key;

                        return Container(
                          key: key,
                          child: _MessageBubble(
                            index: index,
                            text: message['text'] as String? ?? '',
                            timestamp: message['timestamp'] as String?,
                            isUser: isUser,
                            isImage: isImage,
                            imagePaths: isImage ? imagePathsOf(message) : const [],
                            important: message['important'] == true,
                            edited: message['edited'] == true,
                            selectionMode: _selectionMode,
                            selected: _selectedIds.contains(id),
                            highlighted: _highlightedMessageId == id,
                            searchQuery: _searchOpen ? _searchQuery : '',
                            onTap: () => _onBubbleBorderTap(message),
                            onImageTap: (path) => _onImageThumbTap(message, path),
                            onLongPress: () => _onBubbleLongPress(message),
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (!_selectionMode)
            _Composer(
              controller: _composerController,
              sending: _sending,
              pickingImages: _pickingImages,
              pendingImages: _pendingImages,
              onSend: _send,
              onAttachImage: _pickImagesForComposer,
              onRemovePendingImage: _removePendingImage,
            ),
        ],
      ),
    );
  }

  PreferredSizeWidget _defaultAppBar() {
    return AppBar(
      title: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _searchOpen
            ? TextField(
                key: const ValueKey('folder-search'),
                controller: _searchController,
                autofocus: false,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search this chat',
                  border: InputBorder.none,
                ),
              )
            : Text(widget.folderName, key: const ValueKey('folder-title')),
      ),
      actions: [
        if (_searchOpen)
          IconButton(
            tooltip: 'Close search',
            icon: const Icon(Icons.close_rounded),
            onPressed: _closeSearch,
          )
        else
          IconButton(
            tooltip: 'Search this chat',
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _cancelSelection,
      ),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Copy to folder',
          icon: const Icon(Icons.drive_file_move_outline),
          onPressed: _selectedIds.isEmpty ? null : _copySelectedToFolder,
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
        ),
      ],
    );
  }
}

// ================================================================
// Full-screen, swipeable multi-image viewer
// ================================================================

class _ImageViewerScreen extends StatefulWidget {
  final String folderName;
  final List<Map<String, dynamic>> images;
  final int initialIndex;

  const _ImageViewerScreen({
    required this.folderName,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<_ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<_ImageViewerScreen> {
  late List<Map<String, dynamic>> _images = List.of(widget.images);
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _currentIndex = widget.initialIndex;
  bool _changed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _currentPath =>
      _images.isEmpty ? null : _images[_currentIndex]['path'] as String?;

  Future<void> _download() async {
    final path = _currentPath;
    if (path == null) return;

    try {
      await NativeBridge.saveImageToGallery(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to gallery')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  Future<void> _share() async {
    final path = _currentPath;
    if (path == null) return;

    try {
      await NativeBridge.shareFile(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final entry = _images[_currentIndex];
    final messageId = entry['messageId'] as String?;
    final path = entry['path'] as String?;
    if (messageId == null || path == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete image?'),
        content: const Text('This can\'t be undone.'),
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

    final remaining = _images
        .where((e) => e['messageId'] == messageId && e['path'] != path)
        .map((e) => e['path'] as String)
        .toList();

    if (remaining.isEmpty) {
      await FolderStore.deleteMessages(widget.folderName, {messageId});
    } else {
      await FolderStore.updateMessageImages(
          widget.folderName, messageId, remaining);
    }

    _changed = true;
    if (!mounted) return;

    setState(() {
      _images.removeAt(_currentIndex);
      if (_images.isEmpty) {
        Navigator.pop(context, true);
        return;
      }
      if (_currentIndex >= _images.length) {
        _currentIndex = _images.length - 1;
      }
    });

    if (_images.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpToPage(_currentIndex);
        }
      });
    }
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                iconColor: Colors.white,
                textColor: Colors.white,
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download();
                },
              ),
              ListTile(
                iconColor: Colors.white,
                textColor: Colors.white,
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(ctx);
                  _share();
                },
              ),
              ListTile(
                iconColor: Colors.red.shade300,
                textColor: Colors.red.shade300,
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.pop(ctx);
                  _delete();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
          title: _images.isEmpty
              ? const Text('')
              : Text('${_currentIndex + 1} / ${_images.length}'),
          actions: [
            if (_images.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: _showMenu,
              ),
          ],
        ),
        body: _images.isEmpty
            ? const SizedBox.shrink()
            : PageView.builder(
                controller: _controller,
                itemCount: _images.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (context, index) {
                  final path = _images[index]['path'] as String?;
                  final caption = _images[index]['caption'] as String? ?? '';

                  return Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: path == null
                              ? const Icon(Icons.broken_image_outlined,
                                  color: Colors.white54, size: 48)
                              : InteractiveViewer(
                                  minScale: 1,
                                  maxScale: 4,
                                  child: Image.file(
                                    File(path),
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white54,
                                      size: 48,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      if (caption.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          child: Text(
                            caption,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

// ================================================================
// Full-screen message editor
// ================================================================

class _EditResult {
  final String text;
  final List<String> images;
  const _EditResult(this.text, this.images);
}

class _EditMessageScreen extends StatefulWidget {
  final String initialText;
  final List<String> initialImages;
  final bool allowImages;

  const _EditMessageScreen({
    required this.initialText,
    this.initialImages = const [],
    this.allowImages = false,
  });

  @override
  State<_EditMessageScreen> createState() => _EditMessageScreenState();
}

class _EditMessageScreenState extends State<_EditMessageScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  late final List<String> _images = List.of(widget.initialImages);
  bool _addingImages = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _removeImage(String path) {
    setState(() => _images.remove(path));
  }

  Future<void> _addImages() async {
    setState(() => _addingImages = true);
    try {
      final added = await pickAndSaveImages();
      if (added.isNotEmpty && mounted) {
        setState(() => _images.addAll(added));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add image: $e')));
      }
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  void _save() {
    if (widget.allowImages && _images.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('At least one image is required')),
      );
      return;
    }
    Navigator.pop(context, _EditResult(_controller.text.trim(), _images));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit message'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Column(
        children: [
          if (widget.allowImages) _buildImagesSection(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                autofocus: !widget.allowImages,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 16, height: 1.4),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText:
                      widget.allowImages ? 'Caption…' : 'Message text…',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImagesSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
      ),
      child: SizedBox(
        height: 88,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            ..._images.map((path) => Padding(
                  padding: const EdgeInsets.only(right: 10, top: 6),
                  child: _EditableThumb(
                    path: path,
                    onRemove: () => _removeImage(path),
                  ),
                )),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _AddImageButton(busy: _addingImages, onTap: _addImages),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditableThumb extends StatelessWidget {
  final String path;
  final VoidCallback onRemove;
  final double size;

  const _EditableThumb({
    required this.path,
    required this.onRemove,
    this.size = 76,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(path),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: size,
                height: size,
                color: Colors.grey.withOpacity(0.15),
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined, size: 20),
              ),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Colors.black87,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddImageButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _AddImageButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : const Icon(Icons.add_photo_alternate_outlined),
      ),
    );
  }
}

// ================================================================
// Composer
// ================================================================

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final bool pickingImages;
  final List<String> pendingImages;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;
  final void Function(String path) onRemovePendingImage;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.pickingImages,
    required this.pendingImages,
    required this.onSend,
    required this.onAttachImage,
    required this.onRemovePendingImage,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pendingImages.isNotEmpty) _buildPendingImagesStrip(),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Attach image(s)',
                  onPressed: (sending || pickingImages) ? null : onAttachImage,
                  icon: pickingImages
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.image_outlined),
                ),
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: pendingImages.isNotEmpty
                            ? 'Add a caption…'
                            : 'Type a message…',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: sending
                      ? const Padding(
                          key: ValueKey('loading'),
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                        )
                      : IconButton.filled(
                          key: const ValueKey('send'),
                          onPressed: onSend,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingImagesStrip() {
    return Container(
      height: 84,
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pendingImages.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final path = pendingImages[index];
          return _EditableThumb(
            path: path,
            onRemove: () => onRemovePendingImage(path),
            size: 72,
          );
        },
      ),
    );
  }
}

// ================================================================
// Message bubble with Expandable "Read More" logic
// ================================================================

class _MessageBubble extends StatefulWidget {
  final int index;
  final String text;
  final String? timestamp;
  final bool isUser;
  final bool isImage;
  final List<String> imagePaths;
  final bool important;
  final bool edited;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final String searchQuery;
  final VoidCallback onTap;
  final void Function(String path) onImageTap;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.index,
    required this.text,
    required this.isUser,
    required this.onTap,
    required this.onImageTap,
    required this.onLongPress,
    this.isImage = false,
    this.imagePaths = const [],
    this.timestamp,
    this.important = false,
    this.edited = false,
    this.selectionMode = false,
    this.selected = false,
    this.highlighted = false,
    this.searchQuery = '',
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _isExpanded = false;
  static const int _characterLimit = 200; // মেসেজের অক্ষরের লিমিট

  Widget _buildTextWidget(Color? textColor) {
    final text = widget.text;
    final isLongText = text.length > _characterLimit;
    final displayText = (_isExpanded || !isLongText)
        ? text
        : '${text.substring(0, _characterLimit)}... ';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.searchQuery.trim().isNotEmpty
            ? HighlightedText(
                text: displayText,
                query: widget.searchQuery,
                style: TextStyle(color: textColor),
                highlightColor: widget.isUser
                    ? Colors.amber.withOpacity(0.6)
                    : Colors.amber.withOpacity(0.45),
              )
            : Text(displayText, style: TextStyle(color: textColor)),
        if (isLongText)
          GestureDetector(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _isExpanded ? 'Read Less' : 'Read More',
                style: TextStyle(
                  color: widget.isUser
                      ? Colors.white.withOpacity(0.9)
                      : Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bubbleColor =
        widget.isUser ? scheme.primary : Colors.grey.withOpacity(0.14);
    final textColor = widget.isUser ? scheme.onPrimary : null;

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: widget.highlighted
            ? Colors.amber.withOpacity(widget.isUser ? 0.55 : 0.28)
            : bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(widget.isUser ? 16 : 4),
          bottomRight: Radius.circular(widget.isUser ? 4 : 16),
        ),
        border: widget.highlighted
            ? Border.all(color: Colors.amber.shade600, width: 2)
            : widget.important
                ? Border.all(color: Colors.amber.shade600, width: 1.4)
                : null,
        boxShadow: widget.highlighted
            ? [
                BoxShadow(
                  color: Colors.amber.withOpacity(0.22),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (widget.isUser ? scheme.onPrimary : scheme.primary)
                        .withOpacity(0.16),
                  ),
                  child: Text(
                    '${widget.index + 1}',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: widget.isUser ? textColor : scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  widget.isImage
                      ? Icons.image_outlined
                      : widget.isUser
                          ? Icons.person_rounded
                          : Icons.content_paste_rounded,
                  size: 12,
                  color: widget.isUser ? textColor : scheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.isUser ? 'You' : 'System',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: widget.isUser ? textColor : scheme.primary,
                  ),
                ),
                if (widget.important) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.star_rounded,
                      size: 13, color: Colors.amber.shade700),
                ],
              ],
            ),
          ),
          if (widget.isImage && widget.imagePaths.isNotEmpty)
            _buildImageGrid(context),
          if (widget.isImage && widget.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _buildTextWidget(textColor),
            ),
          if (!widget.isImage) _buildTextWidget(textColor),
          if (widget.timestamp != null || widget.edited)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  if (widget.timestamp != null)
                    _formatDateTime(widget.timestamp!),
                  if (widget.edited) 'edited',
                ].join(' \u00B7 '),
                style: TextStyle(
                  fontSize: 10,
                  color: widget.isUser
                      ? scheme.onPrimary.withOpacity(0.7)
                      : Colors.grey,
                ),
              ),
            ),
        ],
      ),
    );

    final row = Row(
      mainAxisAlignment:
          widget.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.selectionMode) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.selected ? scheme.primary : Colors.transparent,
              border: Border.all(
                color: widget.selected ? scheme.primary : Colors.grey,
                width: 1.6,
              ),
            ),
            child: widget.selected
                ? const Icon(Icons.check, size: 15, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(child: bubble),
      ],
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 8),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.selected ? scheme.primary.withOpacity(0.08) : null,
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: row,
        ),
      ),
    );
  }

  Widget _buildImageGrid(BuildContext context) {
    if (widget.imagePaths.length == 1) {
      return _imageTile(widget.imagePaths[0], height: 180);
    }

    final visibleCount = widget.imagePaths.length >= 3 ? 3 : 2;
    final overlayCount =
        widget.imagePaths.length > 3 ? widget.imagePaths.length - 3 : 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(visibleCount, (i) {
        final isLastVisible = i == visibleCount - 1;
        final showOverlay = isLastVisible && overlayCount > 0;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
            child: _imageTile(
              widget.imagePaths[i],
              height: 140,
              overlayText: showOverlay ? '+$overlayCount' : null,
            ),
          ),
        );
      }),
    );
  }

  Widget _imageTile(
    String path, {
    required double height,
    String? overlayText,
  }) {
    return GestureDetector(
      onTap: () => widget.onImageTap(path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Hero(
              tag: 'image_$path',
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                width: double.infinity,
                height: height,
                errorBuilder: (_, __, ___) => Container(
                  width: double.infinity,
                  height: height,
                  color: Colors.grey.withOpacity(0.15),
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined, size: 28),
                ),
              ),
            ),
            if (overlayText != null)
              Container(
                color: Colors.black.withOpacity(0.45),
                alignment: Alignment.center,
                child: Text(
                  overlayText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// Date/time helper
// ================================================================

const _kMonthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDateTime(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${_kMonthNames[dt.month - 1]} ${dt.year}, '
        '$hour12:$minute $period';
  } catch (_) {
    return '';
  }
}