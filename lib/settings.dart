import 'dart:io';

import 'package:flutter/material.dart';

import 'data.dart';

// ================================================================
// Settings screen
// ================================================================
//
// Everything that used to live behind the shield icon (keyboard /
// overlay / notification permissions + the clipboard master switch)
// plus the new Data section (export / import with validation).
// ================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _defaultIme = false;
  bool _overlayEnabled = false;
  bool _notificationEnabled = false;
  bool _clipboardEnabled = false;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
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

  bool get _readyForToggle => _defaultIme && _overlayEnabled;

  Future<void> _toggleClipboard(bool value) async {
    if (value && !_readyForToggle) return;

    await NativeBridge.setClipboardEnabled(value);

    if (!mounted) return;
    setState(() => _clipboardEnabled = value);
  }

  // ---- Export ----

  Future<void> _exportData() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final path = await ImportExportService.exportToFile();
      await NativeBridge.shareFile(path);
      _showSnack('Export ready — choose where to save or send it.');
    } catch (e) {
      _showSnack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Import ----

  Future<void> _importData() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final path = await NativeBridge.pickImportFile();
      if (path == null) return; // user cancelled

      final content = await File(path).readAsString();
      final preview = ImportExportService.validate(content);

      if (!mounted) return;
      final confirmed = await _confirmImportDialog(preview);
      if (confirmed != true) return;

      final result = await ImportExportService.commit(preview);

      final extra = result.skippedMessages > 0
          ? ' (${result.skippedMessages} already existed and were skipped)'
          : '';

      _showSnack(
        'Imported ${result.insertedMessages} message(s) into '
        '${result.insertedFolders} new folder(s)$extra.',
      );
    } on ImportValidationException catch (e) {
      await _showErrorDialog(e.message);
    } catch (e) {
      await _showErrorDialog('Could not read that file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmImportDialog(ImportPreview preview) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Import this data?'),
          content: Text(
            'This file contains ${preview.folderCount} folder(s) and '
            '${preview.messageCount} message(s).\n\n'
            'Existing messages are kept as-is — only new ones will be added.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import'),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionHeader('Permissions'),
          const SizedBox(height: 10),
          PermissionCard(
            icon: Icons.keyboard_alt_outlined,
            title: 'Set as default keyboard',
            description:
                'Needed so Excerpt can stay active as the system input method and detect copied text.',
            granted: _defaultIme,
            onTap: NativeBridge.openImeSettings,
          ),
          const SizedBox(height: 10),
          PermissionCard(
            icon: Icons.layers_outlined,
            title: 'Display over other apps',
            description:
                "Lets Excerpt show the save popup above whatever app you're in.",
            granted: _overlayEnabled,
            onTap: NativeBridge.requestOverlayPermission,
          ),
          const SizedBox(height: 10),
          PermissionCard(
            icon: Icons.notifications_none_rounded,
            title: 'Notifications',
            description:
                'Shows a quiet status notification while Excerpt is your active keyboard.',
            granted: _notificationEnabled,
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Clipboard listening'),
              subtitle: Text(
                !_readyForToggle
                    ? 'Grant the permissions above first'
                    : _clipboardEnabled
                        ? 'ON — Excerpt is active as the system keyboard'
                        : 'OFF',
              ),
              value: _clipboardEnabled,
              onChanged: _readyForToggle ? _toggleClipboard : null,
            ),
          ),
          const SizedBox(height: 28),
          const _SectionHeader('Data'),
          const SizedBox(height: 10),
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
                  title: const Text('Export data'),
                  subtitle: const Text(
                    'Save every folder & message to a JSON file you can move to another device.',
                  ),
                  trailing: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: _busy ? null : _exportData,
                ),
                const Divider(height: 1),
                ListTile(
                  leading:
                      Icon(Icons.download_outlined, color: scheme.primary),
                  title: const Text('Import data'),
                  subtitle: const Text(
                    'Load a previously exported file. It\'s checked and previewed before anything is saved.',
                  ),
                  trailing: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: _busy ? null : _importData,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Imported data is matched by message, so importing the same file twice never creates duplicates.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.6,
        color: Colors.grey.shade600,
      ),
    );
  }
}

// ================================================================
// Reusable permission row — shared with the onboarding WelcomeScreen
// in main.dart so both places look identical.
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