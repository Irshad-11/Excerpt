import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
}

// ================================================================
// Onboarding flag (stored next to the folders, no extra plugin
// needed since we already have the native files dir).
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
// Folder / message storage
// ================================================================

class FolderStore {
  static Directory? _root;

  static Future<Directory> _foldersRoot() async {
    if (_root != null) return _root!;

    final base = await NativeBridge.getAppFilesDir();
    final dir = Directory('$base/folders');

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _root = dir;
    return dir;
  }

  static Future<List<String>> listFolders() async {
    final root = await _foldersRoot();
    final entries = await root.list().toList();

    final names = entries
        .whereType<Directory>()
        .map(
          (d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
        )
        .toList();

    names.sort();
    return names;
  }

  static Future<void> createFolder(String name) async {
    final root = await _foldersRoot();
    final dir = Directory('${root.path}/$name');

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  static Future<File> _messagesFile(String folder) async {
    final root = await _foldersRoot();
    final dir = Directory('${root.path}/$folder');

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return File('${dir.path}/messages.json');
  }

  static Future<List<Map<String, dynamic>>> readMessages(
    String folder,
  ) async {
    final file = await _messagesFile(folder);

    if (!await file.exists()) return [];

    final content = await file.readAsString();
    if (content.trim().isEmpty) return [];

    final decoded = jsonDecode(content);
    if (decoded is! List) return [];

    return decoded
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<void> _appendMessage(
    String folder,
    String text,
    String type,
  ) async {
    final file = await _messagesFile(folder);
    final messages = await readMessages(folder);

    messages.add({
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'text': text,
      'type': type,
      'timestamp': DateTime.now().toIso8601String(),
    });

    await file.writeAsString(jsonEncode(messages));
  }

  /// Text captured from another app via the overlay/clipboard.
  static Future<void> appendSystemMessage(String folder, String text) {
    return _appendMessage(folder, text, 'system');
  }

  /// Text the user typed directly inside the app.
  static Future<void> appendUserMessage(String folder, String text) {
    return _appendMessage(folder, text, 'user');
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
                    _PermissionCard(
                      icon: Icons.keyboard_alt_outlined,
                      title: 'Set as default keyboard',
                      description:
                          'Needed so Excerpt can stay active as the system input method and detect copied text.',
                      granted: _defaultIme,
                      onTap: NativeBridge.openImeSettings,
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
                      icon: Icons.layers_outlined,
                      title: 'Display over other apps',
                      description:
                          'Lets Excerpt show the save popup above whatever app you\'re in.',
                      granted: _overlayEnabled,
                      onTap: NativeBridge.requestOverlayPermission,
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
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

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool granted;
  final Future<void> Function() onTap;

  const _PermissionCard({
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
          color: granted
              ? scheme.primary.withOpacity(0.5)
              : Colors.grey.withOpacity(0.25),
        ),
        color: granted ? scheme.primary.withOpacity(0.06) : null,
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        leading: Icon(icon, color: scheme.primary),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          description,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: granted
              ? Icon(
                  Icons.check_circle_rounded,
                  color: Colors.teal,
                  key: const ValueKey('granted'),
                )
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
      _openPermissions();
      return;
    }

    if (value && !_overlayEnabled) {
      _openPermissions();
      return;
    }

    await NativeBridge.setClipboardEnabled(value);

    if (!mounted) return;

    setState(() {
      _clipboardEnabled = value;
    });
  }

  void _openPermissions() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WelcomeScreen(
          onFinished: () {
            Navigator.pop(context);
            _refreshAll();
          },
        ),
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

  void _openFolder(String folder) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FolderScreen(folderName: folder),
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
            tooltip: 'Permissions',
            onPressed: _openPermissions,
            icon: const Icon(Icons.shield_outlined),
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
                            'Some permissions are missing — tap the shield icon above to fix.',
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
// Folder screen — chat-style view with a composer at the bottom
// ================================================================

class FolderScreen extends StatefulWidget {
  final String folderName;

  const FolderScreen({super.key, required this.folderName});

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool scrollToEnd = false}) async {
    final messages = await FolderStore.readMessages(widget.folderName);

    if (!mounted) return;

    setState(() {
      _messages = messages;
    });

    if (scrollToEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _send() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    await FolderStore.appendUserMessage(widget.folderName, text);
    _composerController.clear();

    await _load(scrollToEnd: true);

    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      body: Column(
        children: [
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

                        return _MessageBubble(
                          text: message['text'] as String,
                          timestamp: message['timestamp'] as String?,
                          isUser: type == 'user',
                        );
                      },
                    ),
            ),
          ),
          _Composer(
            controller: _composerController,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

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

class _MessageBubble extends StatelessWidget {
  final String text;
  final String? timestamp;
  final bool isUser;

  const _MessageBubble({
    required this.text,
    required this.isUser,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bubbleColor =
        isUser ? scheme.primary : Colors.grey.withOpacity(0.14);
    final textColor = isUser ? scheme.onPrimary : null;

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
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_paste, size: 12, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'Captured',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              Text(text, style: TextStyle(color: textColor)),
              if (timestamp != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _formatTime(timestamp!),
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
        ),
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}