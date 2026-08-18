import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'settings.dart';

void main() {
  runApp(const ExcerptApp());
}

class ExcerptApp extends StatelessWidget {
  const ExcerptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Excerpt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const AppRoot(),
    );
  }
}

// ================================================================
// App root — decides whether to show onboarding or home
// ================================================================

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  bool _loading = true;
  bool _onboardingDone = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final done = await OnboardingStore.isDone();

    if (!mounted) return;

    setState(() {
      _onboardingDone = done;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_onboardingDone) {
      return WelcomeScreen(
        onFinished: () {
          setState(() {
            _onboardingDone = true;
          });
        },
      );
    }

    return const HomeScreen();
  }
}

// ================================================================
// Welcome / permission screen
// ================================================================

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const WelcomeScreen({super.key, required this.onFinished});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with WidgetsBindingObserver {
  bool _defaultIme = false;
  bool _overlayEnabled = false;
  bool _notificationEnabled = false;
  bool _clipboardEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
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

  bool get _readyForToggle => _defaultIme && _overlayEnabled;

  Future<void> _toggleMasterSwitch(bool value) async {
    if (value && !_readyForToggle) return;

    await NativeBridge.setClipboardEnabled(value);

    if (!mounted) return;

    setState(() {
      _clipboardEnabled = value;
    });
  }

  Future<void> _finish() async {
    await OnboardingStore.markDone();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.content_paste_go_rounded,
                size: 46,
                color: scheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                'Welcome to Excerpt',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Grant these permissions once so Excerpt can capture and save text from anywhere, instantly.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    PermissionCard(
                      icon: Icons.keyboard_alt_outlined,
                      title: 'Set as default keyboard',
                      description:
                          'Needed so Excerpt can stay active as the system input method and detect copied text.',
                      granted: _defaultIme,
                      onTap: NativeBridge.openImeSettings,
                    ),
                    const SizedBox(height: 12),
                    PermissionCard(
                      icon: Icons.layers_outlined,
                      title: 'Display over other apps',
                      description:
                          'Lets Excerpt show the save popup above whatever app you\'re in.',
                      granted: _overlayEnabled,
                      onTap: NativeBridge.requestOverlayPermission,
                    ),
                    const SizedBox(height: 12),
                    PermissionCard(
                      icon: Icons.notifications_none_rounded,
                      title: 'Notifications',
                      description:
                          'Shows a quiet status notification while Excerpt is your active keyboard.',
                      granted: _notificationEnabled,
                      onTap: NativeBridge.requestNotificationPermission,
                    ),
                    const SizedBox(height: 20),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 250),
                      opacity: _readyForToggle ? 1 : 0.4,
                      child: Card(
                        elevation: 0,
                        color: scheme.primaryContainer.withOpacity(0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SwitchListTile(
                          title: const Text('Enable Excerpt'),
                          subtitle: Text(
                            _readyForToggle
                                ? 'Turn on clipboard capturing'
                                : 'Grant the permissions above first',
                          ),
                          value: _clipboardEnabled,
                          onChanged:
                              _readyForToggle ? _toggleMasterSwitch : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _finish,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Continue'),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: _finish,
                  child: Text(
                    'Skip for now',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================
// Home screen
// ================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  bool _clipboardEnabled = false;
  bool _defaultIme = false;
  bool _overlayEnabled = false;

  List<String> _folders = [];

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
    final folders = await FolderStore.listFolders();

    if (!mounted) return;

    setState(() {
      _folders = folders;
    });
  }

  Future<void> _checkPendingOnStart() async {
    final text = await NativeBridge.getPendingClipText();

    if (text != null && text.isNotEmpty) {
      _onPendingText(text);
    }
  }

  void _onPendingText(String text) {
    NativeBridge.clearPendingClipText();

    if (_pickerOpen) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showFolderPicker(text);
    });
  }

  Future<void> _toggleClipboard(bool value) async {
    if (value && !_defaultIme) {
      _openSettings();
      return;
    }

    if (value && !_overlayEnabled) {
      _openSettings();
      return;
    }

    await NativeBridge.setClipboardEnabled(value);

    if (!mounted) return;

    setState(() {
      _clipboardEnabled = value;
    });
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
      MaterialPageRoute(
        builder: (_) => const GlobalSearchScreen(),
      ),
    );
  }

  // Kept as a fallback path — mainly used now for messages that were
  // pending when the app was opened directly (the overlay itself
  // handles folder picking for normal clipboard captures).
  Future<void> _showFolderPicker(String text) async {
    _pickerOpen = true;

    await _refreshFolders();

    if (!mounted) {
      _pickerOpen = false;
      return;
    }

    final controller = TextEditingController();

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
              const Text(
                'Save captured text',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 12),
              if (_folders.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No folders yet. Create one below.'),
                ),
              ..._folders.map((folder) {
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
                      decoration: const InputDecoration(
                        hintText: 'New folder name',
                      ),
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

  void _openFolder(String folder, {String? initialMessageId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FolderScreen(
          folderName: folder,
          initialMessageId: initialMessageId,
        ),
      ),
    ).then((_) => _refreshFolders());
  }

  Future<void> _createFolderDialog() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
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
        title: const Text('Excerpt'),
        actions: [
          IconButton(
            tooltip: 'Search all folders',
            onPressed: _openGlobalSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'New folder',
            onPressed: _createFolderDialog,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.withOpacity(0.2)),
            ),
            child: SwitchListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: (!_defaultIme || !_overlayEnabled)
                ? Padding(
                    key: const ValueKey('warning'),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Colors.orange.shade800),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Some permissions are missing — open Settings above to fix.',
                            style: TextStyle(
                              color: Colors.orange.shade800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('nowarning')),
          ),
          const Divider(height: 24),
          Expanded(
            child: _folders.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Icon(Icons.folder,
                              color: scheme.onPrimaryContainer, size: 20),
                        ),
                        title: Text(folder),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openFolder(folder),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// Search result model
// ================================================================

class _SearchHit {
  final String folder;
  final Map<String, dynamic> message;
  final int messageIndex;
  final String preview;

  const _SearchHit({
    required this.folder,
    required this.message,
    required this.messageIndex,
    required this.preview,
  });
}

// ================================================================
// Search helpers
// ================================================================

String _normalizeSearchText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<String> _searchTokens(String query) {
  return _normalizeSearchText(query)
      .split(' ')
      .where((e) => e.trim().isNotEmpty)
      .toSet()
      .toList();
}

bool _messageMatchesQuery(String text, String query) {
  final normalizedText = _normalizeSearchText(text);
  final tokens = _searchTokens(query);

  if (tokens.isEmpty) return false;

  return tokens.any(normalizedText.contains);
}

String _makeSearchPreview(
  String text,
  String query, {
  int maxWords = 10,
}) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  if (normalized.isEmpty) return '';

  final tokens = _searchTokens(query);

  int matchPosition = -1;

  if (tokens.isNotEmpty) {
    final lower = normalized.toLowerCase();

    for (final token in tokens) {
      final index = lower.indexOf(token);
      if (index != -1) {
        matchPosition = index;
        break;
      }
    }
  }

  String result;

  if (matchPosition > 0) {
    final start = (matchPosition - 45).clamp(0, normalized.length);
    final end = (matchPosition + 100).clamp(0, normalized.length);

    result = normalized.substring(start, end);

    if (start > 0) {
      result = '…$result';
    }

    if (end < normalized.length) {
      result = '$result…';
    }
  } else {
    final words =
        normalized.split(' ').where((word) => word.isNotEmpty).toList();

    result = words.take(maxWords).join(' ');

    if (words.length > maxWords) {
      result += '…';
    }
  }

  return result;
}

// ================================================================
// Highlighted search text
// ================================================================

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final Color? highlightColor;

  const _HighlightedText({
    required this.text,
    required this.query,
    this.style,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = _searchTokens(query);

    if (tokens.isEmpty || text.isEmpty) {
      return Text(text, style: style);
    }

    final escapedTokens =
        tokens.where((token) => token.isNotEmpty).map(RegExp.escape).toList();

    if (escapedTokens.isEmpty) {
      return Text(text, style: style);
    }

    final regex = RegExp(escapedTokens.join('|'), caseSensitive: false);

    final spans = <TextSpan>[];
    int current = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > current) {
        spans.add(
          TextSpan(text: text.substring(current, match.start), style: style),
        );
      }

      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: (style ?? const TextStyle()).copyWith(
            backgroundColor: highlightColor ?? Colors.amber.withOpacity(0.45),
            fontWeight: FontWeight.w700,
          ),
        ),
      );

      current = match.end;
    }

    if (current < text.length) {
      spans.add(TextSpan(text: text.substring(current), style: style));
    }

    return RichText(text: TextSpan(children: spans));
  }
}

// ================================================================
// Folder screen — chat-style view with a composer + search bar
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

      setState(() {
        _searchQuery = value;
      });
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
        if (id != null) {
          _messageKeys[id] = GlobalKey();
        }
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

  void _openSearch() {
    setState(() {
      _searchOpen = true;
    });
  }

  void _closeSearch() {
    _searchController.clear();
    FocusScope.of(context).unfocus();

    setState(() {
      _searchOpen = false;
      _searchQuery = '';
    });
  }

  // ---- Scroll to exact message ----

  Future<void> _scrollToMessage(
    String id, {
    bool closeSearch = true,
  }) async {
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

    // First jump approximately near the target — handles messages
    // far outside the current viewport that haven't been built yet.
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

    setState(() {
      _highlightedMessageId = id;
    });

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;

      if (_highlightedMessageId == id) {
        setState(() {
          _highlightedMessageId = null;
        });
      }
    });
  }

  // ---- Send ----

  Future<void> _send() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    await FolderStore.appendUserMessage(widget.folderName, text);
    _composerController.clear();

    await _load(scrollToEnd: true);

    if (mounted) setState(() => _sending = false);
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

      if (_selectedIds.isEmpty) {
        _selectionMode = false;
      }
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied to "$target"')),
    );
  }

  // ---- Single message actions ----

  void _onBubbleTap(Map<String, dynamic> message) {
    final id = message['id'] as String;

    if (_selectionMode) {
      _toggleSelected(id);
      return;
    }

    _showMessageActions(message);
  }

  void _onBubbleLongPress(Map<String, dynamic> message) {
    if (_selectionMode) return;
    _enterSelectionMode(message['id'] as String);
  }

  Future<void> _showMessageActions(Map<String, dynamic> message) async {
    final id = message['id'] as String;
    final text = message['text'] as String;
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
                  important ? Icons.star_rounded : Icons.star_border_rounded,
                  color: important ? Colors.amber.shade700 : null,
                ),
                title:
                    Text(important ? 'Unmark important' : 'Mark as important'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await FolderStore.setImportant(
                    widget.folderName,
                    id,
                    !important,
                  );
                  await _load();
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('Copy to other folder'),
                onTap: () async {
                  Navigator.pop(ctx);

                  final target = await _pickTargetFolder();
                  if (target == null) return;

                  await FolderStore.copyMessageToFolder(target, message);

                  if (!mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied to "$target"')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Select'),
                onTap: () {
                  Navigator.pop(ctx);
                  _enterSelectionMode(id);
                },
              ),
              ListTile(
                leading:
                    Icon(Icons.delete_outline, color: Colors.red.shade400),
                title: Text(
                  'Delete',
                  style: TextStyle(color: Colors.red.shade400),
                ),
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

  Future<void> _editMessage(String id, String currentText) async {
    final controller = TextEditingController(text: currentText);

    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Edit message'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (newText == null || newText.isEmpty || newText == currentText) return;

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

  /// Shows existing folders (minus the current one) plus a
  /// "new folder" field, and returns the chosen folder name.
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
              const Text(
                'Copy to folder',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              if (folders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No other folders yet. Create one below.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
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
                      decoration: const InputDecoration(
                        hintText: 'New folder name',
                      ),
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
      return _messageMatchesQuery(text, _searchQuery);
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
                message['type'] == 'user'
                    ? Icons.person_outline
                    : Icons.content_paste,
                size: 16,
              ),
            ),
            title: _HighlightedText(
              text: _makeSearchPreview(text, _searchQuery),
              query: _searchQuery,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '${originalIndex + 1} of ${_messages.length}',
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
                            child: Text(
                              'No messages yet.',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
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
                        final type = message['type'] as String? ?? 'system';
                        final id = message['id'] as String;

                        final key = _messageKeys[id] ?? GlobalKey();
                        _messageKeys[id] = key;

                        return Container(
                          key: key,
                          child: _MessageBubble(
                            text: message['text'] as String,
                            timestamp: message['timestamp'] as String?,
                            isUser: type == 'user',
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
            : Text(
                widget.folderName,
                key: const ValueKey('folder-title'),
              ),
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
// Composer
// ================================================================

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
// Message bubble
// ================================================================

class _MessageBubble extends StatelessWidget {
  final String text;
  final String? timestamp;
  final bool isUser;
  final bool important;
  final bool edited;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final String searchQuery;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.text,
    required this.isUser,
    required this.onTap,
    required this.onLongPress,
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
        maxWidth: MediaQuery.of(context).size.width * 0.72,
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
                Icon(
                  isUser ? Icons.person_rounded : Icons.content_paste_rounded,
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
          if (searchQuery.trim().isNotEmpty)
            _HighlightedText(
              text: text,
              query: searchQuery,
              style: TextStyle(color: textColor),
              highlightColor: isUser
                  ? Colors.amber.withOpacity(0.6)
                  : Colors.amber.withOpacity(0.45),
            )
          else
            Text(text, style: TextStyle(color: textColor)),
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
// Date/time helper — "18 Aug 2026 · 3:45 PM"
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

// ================================================================
// Global search — across every folder
// ================================================================

class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _controller = TextEditingController();

  List<_SearchHit> _results = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_runSearch);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _controller.text.trim();

    if (query.isEmpty) {
      if (!mounted) return;

      setState(() {
        _results = [];
        _searching = false;
      });

      return;
    }

    if (mounted) {
      setState(() => _searching = true);
    }

    final folders = await FolderStore.listFolders();
    final hits = <_SearchHit>[];

    for (final folder in folders) {
      final messages = await FolderStore.readMessages(folder);

      for (int i = 0; i < messages.length; i++) {
        final message = messages[i];
        final text = message['text']?.toString() ?? '';

        if (text.isEmpty) continue;

        final folderMatches = _messageMatchesQuery(text, query);
        final folderNameMatches = _normalizeSearchText(folder)
            .contains(_normalizeSearchText(query));

        if (folderMatches || folderNameMatches) {
          hits.add(
            _SearchHit(
              folder: folder,
              message: message,
              messageIndex: i,
              preview: _makeSearchPreview(text, query, maxWords: 9),
            ),
          );
        }
      }
    }

    // Guard: the query field may have changed while awaiting.
    if (!mounted || _controller.text.trim() != query) return;

    setState(() {
      _results = hits;
      _searching = false;
    });
  }

  void _openResult(_SearchHit hit) {
    final messageId = hit.message['id']?.toString();
    if (messageId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FolderScreen(
          folderName: hit.folder,
          initialMessageId: messageId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search all folders...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _controller.clear(),
                      )
                    : null,
                filled: true,
                fillColor:
                    scheme.surfaceContainerHighest.withOpacity(0.55),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _controller.text.trim().isEmpty
                ? const _SearchEmptyState(
                    icon: Icons.search_rounded,
                    title: 'Search your archive',
                    subtitle: 'Find messages across every folder.',
                  )
                : _results.isEmpty && !_searching
                    ? const _SearchEmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No results',
                        subtitle: 'Try another word or phrase.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final hit = _results[index];
                          final type =
                              hit.message['type']?.toString() ?? 'system';

                          return _GlobalSearchResultTile(
                            folder: hit.folder,
                            preview: hit.preview,
                            query: _controller.text,
                            type: type,
                            messageIndex: hit.messageIndex,
                            onTap: () => _openResult(hit),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlobalSearchResultTile extends StatelessWidget {
  final String folder;
  final String preview;
  final String query;
  final String type;
  final int messageIndex;
  final VoidCallback onTap;

  const _GlobalSearchResultTile({
    required this.folder,
    required this.preview,
    required this.query,
    required this.type,
    required this.messageIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.14)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    type == 'user'
                        ? Icons.person_outline
                        : Icons.content_paste,
                    size: 19,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              folder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            '#${messageIndex + 1}',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      _HighlightedText(
                        text: preview,
                        query: query,
                        style: const TextStyle(fontSize: 13, height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                const Icon(Icons.chevron_right_rounded, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}