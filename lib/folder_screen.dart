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
  bool _searchOpen = false;
  String _searchQuery = '';
  String? _highlightedMessageId;
  bool _initialTargetHandled = false;

  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      });
    }

    if (!_initialTargetHandled && widget.initialMessageId != null) {
      _initialTargetHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToMessage(widget.initialMessageId!, closeSearch: false);
      });
    }
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
    }

    if (_scrollController.hasClients) {
      final estimated = (index * 105.0)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      await _scrollController.animateTo(
        estimated,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }

    await Future.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final key = _messageKeys[id];
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        alignment: 0.35,
      );
    }

    if (!mounted) return;
    setState(() => _highlightedMessageId = id);

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      if (_highlightedMessageId == id) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  // ---- Send text ----

  Future<void> _send() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    await FolderStore.appendUserMessage(widget.folderName, text);
    _composerController.clear();
    await _load(scrollToEnd: true);
    if (mounted) setState(() => _sending = false);
  }

  // ---- Send image(s) — multi-select from gallery ----

  Future<void> _pickAndSendImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 85);
    if (picked.isEmpty) return;

    setState(() => _sending = true);

    try {
      final base = await NativeBridge.getAppFilesDir();
      final imagesDir = Directory(p.join(base, 'images'));
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      for (final asset in picked) {
        final ext =
            p.extension(asset.path).isEmpty ? '.jpg' : p.extension(asset.path);
        final savedPath = p.join(
          imagesDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_${asset.name}$ext'
              .replaceAll(RegExp(r'\.{2,}'), '.'),
        );
        await File(asset.path).copy(savedPath);

        // This image was picked and sent by the user, inside the
        // app — always source: 'user'.
        await FolderStore.appendImageMessage(
          widget.folderName,
          savedPath,
          source: 'user',
        );
      }

      await _load(scrollToEnd: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add image: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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

  // ---- Single message actions ----

  void _onBubbleTap(Map<String, dynamic> message) {
    if (_selectionMode) {
      _toggleSelected(message['id'] as String);
      return;
    }

    if (message['type'] == 'image') {
      _openImageViewer(message);
      return;
    }

    _showMessageActions(message);
  }

  void _onBubbleLongPress(Map<String, dynamic> message) {
    if (_selectionMode) return;
    _enterSelectionMode(message['id'] as String);
  }

  // ---- Full-screen image viewer ----

  void _openImageViewer(Map<String, dynamic> tappedMessage) async {
    final images = _messages.where((m) => m['type'] == 'image').toList();
    final startIndex =
        images.indexWhere((m) => m['id'] == tappedMessage['id']);

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewerScreen(
          folderName: widget.folderName,
          images: images,
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
                  _editMessage(id, text);
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

  /// Large, full-screen edit box — never cramped, works well for
  /// long messages in any script.
  Future<void> _editMessage(String id, String currentText) async {
    final newText = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _EditMessageScreen(initialText: currentText),
      ),
    );

    if (newText == null || newText.trim().isEmpty || newText == currentText) {
      return;
    }

    await FolderStore.updateMessageText(widget.folderName, id, newText);
    await _load();
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
              onRefresh: _load,
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
                            imagePath: message['image_path'] as String?,
                            important: message['important'] == true,
                            edited: message['edited'] == true,
                            selectionMode: _selectionMode,
                            selected: _selectedIds.contains(id),
                            highlighted: _highlightedMessageId == id,
                            searchQuery: _searchOpen ? _searchQuery : '',
                            onTap: () => _onBubbleTap(message),
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
              onSend: _send,
              onAttachImage: _pickAndSendImage,
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
                autofocus: true,
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
//
// Opened by tapping any image bubble. Shows every image in the
// folder (not just the tapped one) in a PageView so the user can
// swipe through them like a gallery. Top bar: back button + a
// three-dot menu with Download / Share / Delete, each fully wired.
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
      _images.isEmpty ? null : _images[_currentIndex]['image_path'] as String?;

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
    final id = _images[_currentIndex]['id'] as String?;
    if (id == null) return;

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

    await FolderStore.deleteMessages(widget.folderName, {id});
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
                  final path = _images[index]['image_path'] as String?;
                  final caption = _images[index]['text'] as String? ?? '';

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
// Full-screen message editor — deliberately NOT a small dialog box,
// so long messages in any script stay easy to read and edit.
// ================================================================

class _EditMessageScreen extends StatefulWidget {
  final String initialText;
  const _EditMessageScreen({required this.initialText});

  @override
  State<_EditMessageScreen> createState() => _EditMessageScreenState();
}

class _EditMessageScreenState extends State<_EditMessageScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit message'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          autofocus: true,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontSize: 16, height: 1.4),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'Message text…',
          ),
        ),
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
  final VoidCallback onSend;
  final VoidCallback onAttachImage;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttachImage,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Attach image(s)',
              onPressed: sending ? null : onAttachImage,
              icon: const Icon(Icons.image_outlined),
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
                  decoration: const InputDecoration(
                    hintText: 'Type a message…',
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
    );
  }
}

// ================================================================
// Message bubble — numbered, supports text or image content.
// `isUser` now comes from the `source` field (who sent it), fully
// independent from whether the content is text or an image.
// ================================================================

class _MessageBubble extends StatelessWidget {
  final int index;
  final String text;
  final String? timestamp;
  final bool isUser;
  final bool isImage;
  final String? imagePath;
  final bool important;
  final bool edited;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final String searchQuery;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.index,
    required this.text,
    required this.isUser,
    required this.onTap,
    required this.onLongPress,
    this.isImage = false,
    this.imagePath,
    this.timestamp,
    this.important = false,
    this.edited = false,
    this.selectionMode = false,
    this.selected = false,
    this.highlighted = false,
    this.searchQuery = '',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bubbleColor =
        isUser ? scheme.primary : Colors.grey.withOpacity(0.14);
    final textColor = isUser ? scheme.onPrimary : null;

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? Colors.amber.withOpacity(isUser ? 0.55 : 0.28)
            : bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isUser ? 16 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 16),
        ),
        border: highlighted
            ? Border.all(color: Colors.amber.shade600, width: 2)
            : important
                ? Border.all(color: Colors.amber.shade600, width: 1.4)
                : null,
        boxShadow: highlighted
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
                    color: (isUser ? scheme.onPrimary : scheme.primary)
                        .withOpacity(0.16),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: isUser ? textColor : scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  isImage
                      ? Icons.image_outlined
                      : isUser
                          ? Icons.person_rounded
                          : Icons.content_paste_rounded,
                  size: 12,
                  color: isUser ? textColor : scheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  isUser ? 'You' : 'System',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isUser ? textColor : scheme.primary,
                  ),
                ),
                if (important) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.star_rounded,
                      size: 13, color: Colors.amber.shade700),
                ],
              ],
            ),
          ),
          if (isImage && imagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Hero(
                tag: 'image_$imagePath',
                child: Image.file(
                  File(imagePath!),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: 180,
                  errorBuilder: (_, __, ___) => Container(
                    width: double.infinity,
                    height: 120,
                    color: Colors.grey.withOpacity(0.15),
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined, size: 28),
                  ),
                ),
              ),
            ),
          if (isImage && text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(text, style: TextStyle(color: textColor)),
            ),
          if (!isImage)
            searchQuery.trim().isNotEmpty
                ? HighlightedText(
                    text: text,
                    query: searchQuery,
                    style: TextStyle(color: textColor),
                    highlightColor: isUser
                        ? Colors.amber.withOpacity(0.6)
                        : Colors.amber.withOpacity(0.45),
                  )
                : Text(text, style: TextStyle(color: textColor)),
          if (timestamp != null || edited)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  if (timestamp != null) _formatDateTime(timestamp!),
                  if (edited) 'edited',
                ].join(' \u00B7 '),
                style: TextStyle(
                  fontSize: 10,
                  color: isUser
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
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (selectionMode) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? scheme.primary : Colors.transparent,
              border: Border.all(
                color: selected ? scheme.primary : Colors.grey,
                width: 1.6,
              ),
            ),
            child: selected
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
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withOpacity(0.08) : null,
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: row,
        ),
      ),
    );
  }
}

// ================================================================
// Date/time helper — "18 Aug 2026, 3:45 PM"
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