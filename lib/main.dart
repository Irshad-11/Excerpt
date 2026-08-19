import 'package:flutter/material.dart';

import 'data.dart';
import 'home_screen.dart';
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
// Welcome / permission screen (first-run onboarding)
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