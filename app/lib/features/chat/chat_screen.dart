import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/models.dart';
import '../calling/call_screen.dart';

/// Shared 1-to-1 encrypted conversation surface. Used by the client app
/// (its only chat) and the owner app (one per selected contact).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.pairId});

  final String pairId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _typing = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    context.read<HotlineAppState>().setTyping(widget.pairId, false);
    setState(() => _typing = false);
    context.read<HotlineAppState>().sendChat(widget.pairId, text);
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    final channel = state.channels[widget.pairId];
    final messages = state.historyOf(widget.pairId);

    return Column(
      children: [
        if (channel?.peerTyping ?? false)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 20, top: 6),
              child: Text('typing…', style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ),
        Expanded(
          child: messages.isEmpty
              ? _EmptyState()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _Bubble(message: messages[i]),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Send encrypted file',
                  icon: const Icon(Icons.attach_file_rounded),
                  onPressed: () => _pickAndSendFile(context),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.send,
                    onChanged: (t) {
                      if (!_typing && t.isNotEmpty) {
                        _typing = true;
                        context.read<HotlineAppState>().setTyping(widget.pairId, true);
                      }
                    },
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Encrypted message'),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.black),
                    onPressed: _send,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickAndSendFile(BuildContext context) async {
    // Alpha: pick from gallery/photos via the system sheet, then send the
    // file E2EE (AES-256-GCM with a random key; key rides the ratchet).
    final state = context.read<HotlineAppState>();
    final path = await showFilePickerSheet(context);
    if (path == null || !context.mounted) return;
    await state.sendFile(widget.pairId, path);
  }
}

/// Minimal alpha file picker: lets the OS decide, keeps plugin surface tiny.
Future<String?> showFilePickerSheet(BuildContext context) async {
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Send an encrypted file'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_rounded),
            title: const Text('From gallery (demo path)'),
            onTap: () => Navigator.pop(context, null),
          ),
          ListTile(
            leading: const Icon(Icons.audiotrack_rounded),
            title: const Text('Audio note (demo path)'),
            onTap: () => Navigator.pop(context, null),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          const Text('End-to-end encrypted'),
          const SizedBox(height: 4),
          Text(
            'Nobody else can read this conversation.\nNot even the relay server.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mine = message.outgoing;
    final accent = Theme.of(context).colorScheme;
    final time = DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(message.timestampMs));

    Widget content;
    if (message.kind == MessageKind.fileMeta) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(mine ? Icons.file_upload_rounded : Icons.file_download_rounded, size: 20, color: accent.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.fileName ?? 'file', overflow: TextOverflow.ellipsis),
                Text(
                  message.filePath != null
                      ? 'received — tap to open'
                      : _sizeLabel(message.fileSize),
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      content = Text(message.text ?? '');
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: message.filePath != null
            ? () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Decrypted file saved to ${message.filePath}')),
                );
              }
            : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: mine ? accent.secondary : const Color(0xFF1A2230),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle(
                style: const TextStyle(color: Colors.white, fontSize: 15),
                child: content,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: const TextStyle(fontSize: 10, color: Colors.white38)),
                  if (mine) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _statusIcon(message.status),
                      size: 12,
                      color: message.status == SendStatus.read
                          ? accent.primary
                          : message.status == SendStatus.failed
                              ? accent.error
                              : Colors.white38,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _statusIcon(SendStatus s) => switch (s) {
        SendStatus.sending => Icons.schedule_rounded,
        SendStatus.sent => Icons.done_rounded,
        SendStatus.delivered => Icons.done_all_rounded,
        SendStatus.read => Icons.done_all_rounded,
        SendStatus.failed => Icons.error_outline_rounded,
      };

  static String _sizeLabel(int? bytes) {
    if (bytes == null) return 'transferring…';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
