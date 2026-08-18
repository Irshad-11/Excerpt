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
      ),
      home: const HomeScreen(),
    );
  }
}

class NativeBridge {
  static const _channel =
      MethodChannel('com.excerpt/native');

  static Future<String> getAppFilesDir() async {
    final value =
        await _channel.invokeMethod<String>(
      'getAppFilesDir',
    );

    return value!;
  }

  static Future<bool> isClipboardEnabled() async {
    final value =
        await _channel.invokeMethod<bool>(
      'isClipboardEnabled',
    );

    return value ?? false;
  }

  static Future<void> setClipboardEnabled(
    bool value,
  ) {
    return _channel.invokeMethod(
      'setClipboardEnabled',
      value,
    );
  }

  static Future<bool> isExcerptDefaultIme() async {
    final value =
        await _channel.invokeMethod<bool>(
      'isExcerptDefaultIme',
    );

    return value ?? false;
  }

  static Future<void> openImeSettings() {
    return _channel.invokeMethod(
      'openImeSettings',
    );
  }

  static Future<void> openInputMethodPicker() {
    return _channel.invokeMethod(
      'openInputMethodPicker',
    );
  }

  static Future<bool> canDrawOverlays() async {
    final value =
        await _channel.invokeMethod<bool>(
      'canDrawOverlays',
    );

    return value ?? false;
  }

  static Future<void> requestOverlayPermission() {
    return _channel.invokeMethod(
      'requestOverlayPermission',
    );
  }

  static Future<String?> getPendingClipText() {
    return _channel.invokeMethod<String>(
      'getPendingClipText',
    );
  }

  static Future<void> clearPendingClipText() {
    return _channel.invokeMethod(
      'clearPendingClipText',
    );
  }

  static void setPendingTextHandler(
    void Function(String text) handler,
  ) {
    _channel.setMethodCallHandler(
      (call) async {
        if (
          call.method ==
          'pendingClipText'
        ) {
          final value =
              call.arguments as String;

          handler(value);
        }
      },
    );
  }
}

class FolderStore {
  static Directory? _root;

  static Future<Directory> _foldersRoot() async {
    if (_root != null) {
      return _root!;
    }

    final base =
        await NativeBridge.getAppFilesDir();

    final dir =
        Directory(
      '$base/folders',
    );

    if (!await dir.exists()) {
      await dir.create(
        recursive: true,
      );
    }

    _root = dir;

    return dir;
  }

  static Future<List<String>> listFolders() async {
    final root =
        await _foldersRoot();

    final entries =
        await root.list().toList();

    final names =
        entries
            .whereType<Directory>()
            .map(
              (d) => d
                  .uri
                  .pathSegments
                  .where(
                    (s) => s.isNotEmpty,
                  )
                  .last,
            )
            .toList();

    names.sort();

    return names;
  }

  static Future<void> createFolder(
    String name,
  ) async {
    final root =
        await _foldersRoot();

    final dir =
        Directory(
      '${root.path}/$name',
    );

    if (!await dir.exists()) {
      await dir.create(
        recursive: true,
      );
    }
  }

  static Future<File> _messagesFile(
    String folder,
  ) async {
    final root =
        await _foldersRoot();

    final dir =
        Directory(
      '${root.path}/$folder',
    );

    if (!await dir.exists()) {
      await dir.create(
        recursive: true,
      );
    }

    return File(
      '${dir.path}/messages.json',
    );
  }

  static Future<List<Map<String, dynamic>>>
      readMessages(
    String folder,
  ) async {
    final file =
        await _messagesFile(folder);

    if (!await file.exists()) {
      return [];
    }

    final content =
        await file.readAsString();

    if (content.trim().isEmpty) {
      return [];
    }

    final decoded =
        jsonDecode(content);

    if (decoded is! List) {
      return [];
    }

    return decoded
        .map(
          (e) => Map<String, dynamic>.from(
            e as Map,
          ),
        )
        .toList();
  }

  static Future<void> appendSystemMessage(
    String folder,
    String text,
  ) async {
    final file =
        await _messagesFile(folder);

    final messages =
        await readMessages(folder);

    messages.add({
      'id':
          DateTime.now()
              .microsecondsSinceEpoch
              .toString(),
      'text': text,
      'type': 'system',
      'timestamp':
          DateTime.now().toIso8601String(),
    });

    await file.writeAsString(
      jsonEncode(messages),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() =>
      _HomeScreenState();
}

class _HomeScreenState
    extends State<HomeScreen>
    with WidgetsBindingObserver {

  bool _clipboardEnabled = false;
  bool _defaultIme = false;
  bool _overlayEnabled = false;

  List<String> _folders = [];

  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addObserver(this);

    NativeBridge.setPendingTextHandler(
      _onPendingText,
    );

    _refreshAll();

    _checkPendingOnStart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this);

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (
      state ==
      AppLifecycleState.resumed
    ) {
      _refreshAll();

      _checkPendingOnStart();
    }
  }

  Future<void> _refreshAll() async {
    await _refreshPermissions();
    await _refreshFolders();
  }

  Future<void> _refreshPermissions() async {
    final enabled =
        await NativeBridge
            .isClipboardEnabled();

    final ime =
        await NativeBridge
            .isExcerptDefaultIme();

    final overlay =
        await NativeBridge
            .canDrawOverlays();

    if (!mounted) {
      return;
    }

    setState(() {
      _clipboardEnabled =
          enabled;

      _defaultIme =
          ime;

      _overlayEnabled =
          overlay;
    });
  }

  Future<void> _refreshFolders() async {
    final folders =
        await FolderStore.listFolders();

    if (!mounted) {
      return;
    }

    setState(() {
      _folders = folders;
    });
  }

  Future<void> _checkPendingOnStart() async {
    final text =
        await NativeBridge
            .getPendingClipText();

    if (
      text != null &&
      text.isNotEmpty
    ) {
      _onPendingText(text);
    }
  }

  void _onPendingText(
    String text,
  ) {
    NativeBridge
        .clearPendingClipText();

    if (_pickerOpen) {
      return;
    }

    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) {
        if (mounted) {
          _showFolderPicker(text);
        }
      },
    );
  }

  Future<void> _toggleClipboard(
    bool value,
  ) async {

    if (value &&
        !_defaultIme) {

      _showPermissionDialog(
        title:
            'Set Excerpt as default keyboard',
        message:
            'Excerpt must be selected as the default keyboard so Android keeps Excerpt active as the system input method.',
        onConfirm:
            NativeBridge.openImeSettings,
      );

      return;
    }

    if (value &&
        !_overlayEnabled) {

      _showPermissionDialog(
        title:
            'Enable overlay permission',
        message:
            'Excerpt needs Display over other apps permission to show the save prompt above other apps.',
        onConfirm:
            NativeBridge
                .requestOverlayPermission,
      );

      return;
    }

    await NativeBridge
        .setClipboardEnabled(
      value,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _clipboardEnabled =
          value;
    });
  }

  void _showPermissionDialog({
    required String title,
    required String message,
    required Future<void> Function()
        onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title:
              Text(title),
          content:
              Text(message),
          actions: [
            TextButton(
              onPressed:
                  () =>
                      Navigator.pop(ctx),
              child:
                  const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);

                onConfirm();
              },
              child:
                  const Text(
                'Open Settings',
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showFolderPicker(
    String text,
  ) async {

    _pickerOpen = true;

    await _refreshFolders();

    if (!mounted) {
      _pickerOpen = false;
      return;
    }

    final controller =
        TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {

        return Padding(
          padding:
              EdgeInsets.only(
            bottom:
                MediaQuery.of(ctx)
                    .viewInsets
                    .bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [

              const Text(
                'Save captured text',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                  fontSize: 16,
                ),
              ),

              const SizedBox(
                height: 8,
              ),

              Container(
                width:
                    double.infinity,
                padding:
                    const EdgeInsets.all(
                  8,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      Colors.grey.shade100,
                  borderRadius:
                      BorderRadius.circular(
                    8,
                  ),
                ),
                child:
                    Text(
                  text,
                  maxLines: 4,
                  overflow:
                      TextOverflow.ellipsis,
                ),
              ),

              const SizedBox(
                height: 12,
              ),

              if (_folders.isEmpty)
                const Padding(
                  padding:
                      EdgeInsets.symmetric(
                    vertical: 8,
                  ),
                  child:
                      Text(
                    'No folders yet. Create one below.',
                  ),
                ),

              ..._folders.map(
                (folder) {

                  return ListTile(
                    leading:
                        const Icon(
                      Icons.folder_outlined,
                    ),
                    title:
                        Text(folder),
                    onTap: () async {

                      await FolderStore
                          .appendSystemMessage(
                        folder,
                        text,
                      );

                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }

                      _openFolder(
                        folder,
                      );
                    },
                  );
                },
              ),

              const Divider(),

              Row(
                children: [

                  Expanded(
                    child:
                        TextField(
                      controller:
                          controller,
                      decoration:
                          const InputDecoration(
                        hintText:
                            'New folder name',
                      ),
                    ),
                  ),

                  IconButton(
                    icon:
                        const Icon(
                      Icons
                          .add_circle,
                      color:
                          Colors.teal,
                    ),
                    onPressed:
                        () async {

                      final name =
                          controller
                              .text
                              .trim();

                      if (name.isEmpty) {
                        return;
                      }

                      await FolderStore
                          .createFolder(
                        name,
                      );

                      await FolderStore
                          .appendSystemMessage(
                        name,
                        text,
                      );

                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }

                      _openFolder(
                        name,
                      );
                    },
                  ),
                ],
              ),

              const SizedBox(
                height: 12,
              ),
            ],
          ),
        );
      },
    );

    _pickerOpen = false;
  }

  void _openFolder(
    String folder,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            FolderScreen(
          folderName:
              folder,
        ),
      ),
    ).then(
      (_) => _refreshFolders(),
    );
  }

  Future<void> _createFolderDialog()
      async {

    final controller =
        TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {

        return AlertDialog(
          title:
              const Text(
            'New Folder',
          ),
          content:
              TextField(
            controller:
                controller,
            decoration:
                const InputDecoration(
              hintText:
                  'Folder name',
            ),
          ),
          actions: [

            TextButton(
              onPressed:
                  () =>
                      Navigator.pop(ctx),
              child:
                  const Text(
                'Cancel',
              ),
            ),

            TextButton(
              onPressed:
                  () async {

                final name =
                    controller
                        .text
                        .trim();

                if (name.isNotEmpty) {
                  await FolderStore
                      .createFolder(
                    name,
                  );

                  await _refreshFolders();
                }

                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              },
              child:
                  const Text(
                'Create',
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar:
          AppBar(
        title:
            const Text(
          'Excerpt',
        ),
        actions: [

          IconButton(
            onPressed:
                _createFolderDialog,
            icon:
                const Icon(
              Icons
                  .create_new_folder_outlined,
            ),
          ),
        ],
      ),

      body:
          Column(
        children: [

          Card(
            margin:
                const EdgeInsets.all(
              12,
            ),
            child:
                SwitchListTile(
              title:
                  const Text(
                'Clipboard listening',
              ),
              subtitle:
                  Text(
                _clipboardEnabled
                    ? 'ON — Excerpt is active as the system keyboard'
                    : 'OFF',
              ),
              value:
                  _clipboardEnabled,
              onChanged:
                  _toggleClipboard,
            ),
          ),

          if (!_defaultIme)
            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              child:
                  Text(
                'Set Excerpt as the default keyboard.',
                style:
                    TextStyle(
                  color:
                      Colors.orange.shade800,
                  fontSize: 12,
                ),
              ),
            ),

          if (!_overlayEnabled)
            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              child:
                  Text(
                'Display over other apps permission is required.',
                style:
                    TextStyle(
                  color:
                      Colors.orange.shade800,
                  fontSize: 12,
                ),
              ),
            ),

          const Divider(
            height: 24,
          ),

          Expanded(
            child:
                _folders.isEmpty
                    ? const Center(
                        child:
                            Text(
                          'No folders yet.\nCopy text somewhere to get started.',
                          textAlign:
                              TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount:
                            _folders.length,
                        itemBuilder:
                            (
                          context,
                          index,
                        ) {

                          final folder =
                              _folders[index];

                          return ListTile(
                            leading:
                                const Icon(
                              Icons.folder,
                            ),
                            title:
                                Text(
                              folder,
                            ),
                            trailing:
                                const Icon(
                              Icons
                                  .chevron_right,
                            ),
                            onTap:
                                () =>
                                    _openFolder(
                              folder,
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class FolderScreen
    extends StatefulWidget {

  final String folderName;

  const FolderScreen({
    super.key,
    required this.folderName,
  });

  @override
  State<FolderScreen>
      createState() =>
          _FolderScreenState();
}

class _FolderScreenState
    extends State<FolderScreen> {

  List<
      Map<String, dynamic>
  > _messages = [];

  @override
  void initState() {
    super.initState();

    _load();
  }

  Future<void> _load() async {

    final messages =
        await FolderStore
            .readMessages(
      widget.folderName,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _messages =
          messages;
    });
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar:
          AppBar(
        title:
            Text(
          widget.folderName,
        ),
      ),
      body:
          RefreshIndicator(
        onRefresh:
            _load,
        child:
            _messages.isEmpty
                ? ListView(
                    children: const [
                      Padding(
                        padding:
                            EdgeInsets.all(
                          24,
                        ),
                        child:
                            Text(
                          'No messages yet.',
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.all(
                      12,
                    ),
                    itemCount:
                        _messages.length,
                    itemBuilder:
                        (
                      context,
                      index,
                    ) {

                      final message =
                          _messages[index];

                      return
                          _SystemMessageBubble(
                        text:
                            message['text']
                                as String,
                        timestamp:
                            message[
                                'timestamp']
                                as String?,
                      );
                    },
                  ),
      ),
    );
  }
}

class _SystemMessageBubble
    extends StatelessWidget {

  final String text;
  final String? timestamp;

  const _SystemMessageBubble({
    required this.text,
    this.timestamp,
  });

  @override
  Widget build(
    BuildContext context,
  ) {

    return Align(
      alignment:
          Alignment.centerLeft,
      child:
          Container(
        margin:
            const EdgeInsets.symmetric(
          vertical: 6,
        ),
        padding:
            const EdgeInsets.all(
          12,
        ),
        constraints:
            BoxConstraints(
          maxWidth:
              MediaQuery.of(context)
                  .size
                  .width *
                  0.8,
        ),
        decoration:
            BoxDecoration(
          color:
              Colors.teal.shade50,
          borderRadius:
              BorderRadius.circular(
            14,
          ),
          border:
              Border.all(
            color:
                Colors.teal.shade200,
          ),
        ),
        child:
            Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [

            Row(
              children: [

                Icon(
                  Icons.content_paste,
                  size: 14,
                  color:
                      Colors.teal.shade700,
                ),

                const SizedBox(
                  width: 4,
                ),

                Text(
                  'Captured',
                  style:
                      TextStyle(
                    fontSize: 11,
                    color:
                        Colors.teal.shade700,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(
              height: 6,
            ),

            Text(
              text,
            ),

            if (timestamp != null)
              ...[
                const SizedBox(
                  height: 4,
                ),
                Text(
                  _formatTime(
                    timestamp!,
                  ),
                  style:
                      const TextStyle(
                    fontSize: 10,
                    color:
                        Colors.grey,
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }

  String _formatTime(
    String iso,
  ) {
    try {

      final dt =
          DateTime.parse(
        iso,
      );

      return
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';

    } catch (_) {

      return '';
    }
  }
}