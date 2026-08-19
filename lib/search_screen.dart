import 'package:flutter/material.dart';

import 'data.dart';
import 'folder_screen.dart' show FolderScreen;

// ================================================================
// Search helpers — shared between GlobalSearchScreen and the
// in-folder search panel inside FolderScreen.
// ================================================================

String normalizeSearchText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<String> searchTokens(String query) {
  return normalizeSearchText(query)
      .split(' ')
      .where((e) => e.trim().isNotEmpty)
      .toSet()
      .toList();
}

bool messageMatchesQuery(String text, String query) {
  final normalizedText = normalizeSearchText(text);
  final tokens = searchTokens(query);
  if (tokens.isEmpty) return false;
  return tokens.any(normalizedText.contains);
}

String makeSearchPreview(String text, String query, {int maxWords = 10}) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '';

  final tokens = searchTokens(query);
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
    if (start > 0) result = '…$result';
    if (end < normalized.length) result = '$result…';
  } else {
    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    result = words.take(maxWords).join(' ');
    if (words.length > maxWords) result += '…';
  }

  return result;
}

// ================================================================
// Highlighted search text — bolds/underlines the matched tokens.
// Public so FolderScreen (in folder_screen.dart) can reuse it too.
// ================================================================

class HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final Color? highlightColor;

  const HighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = searchTokens(query);

    if (tokens.isEmpty || text.isEmpty) {
      return Text(text, style: style);
    }

    final escapedTokens =
        tokens.where((t) => t.isNotEmpty).map(RegExp.escape).toList();

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
// Search result model
// ================================================================

class SearchHit {
  final String folder;
  final Map<String, dynamic> message;
  final int messageIndex;
  final String preview;

  const SearchHit({
    required this.folder,
    required this.message,
    required this.messageIndex,
    required this.preview,
  });
}

// ================================================================
// Global search — across every folder (archived folders included,
// so a message is never "lost" just because its folder was archived)
// ================================================================

class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _controller = TextEditingController();

  List<SearchHit> _results = [];
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

    if (mounted) setState(() => _searching = true);

    final active = await FolderStore.listFolders(archived: false);
    final archived = await FolderStore.listFolders(archived: true);
    final folders = [...active, ...archived];

    final hits = <SearchHit>[];

    for (final folder in folders) {
      final messages = await FolderStore.readMessages(folder);

      for (int i = 0; i < messages.length; i++) {
        final message = messages[i];
        final text = message['text']?.toString() ?? '';
        if (text.isEmpty) continue;

        final folderMatches = messageMatchesQuery(text, query);
        final folderNameMatches =
            normalizeSearchText(folder).contains(normalizeSearchText(query));

        if (folderMatches || folderNameMatches) {
          hits.add(
            SearchHit(
              folder: folder,
              message: message,
              messageIndex: i,
              preview: makeSearchPreview(text, query, maxWords: 9),
            ),
          );
        }
      }
    }

    if (!mounted || _controller.text.trim() != query) return;

    setState(() {
      _results = hits;
      _searching = false;
    });
  }

  void _openResult(SearchHit hit) {
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
                fillColor: scheme.surfaceContainerHighest.withOpacity(0.55),
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
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
                        : type == 'image'
                            ? Icons.image_outlined
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
                                color: Colors.grey.shade500, fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      HighlightedText(
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