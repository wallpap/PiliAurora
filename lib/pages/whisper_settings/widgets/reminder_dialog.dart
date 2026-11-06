import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart' show IMSettingType;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/whisper_settings/controller.dart';
import 'package:pili_aurora/services/messaging/settings.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class MessageReminderButton extends ConsumerStatefulWidget {
  const MessageReminderButton({
    super.key,
    required this.type,
    required this.title,
    required this.icon,
  });

  final IMSettingType type;
  final String title;
  final Widget icon;

  @override
  ConsumerState<MessageReminderButton> createState() =>
      _MessageReminderButtonState();
}

class _MessageReminderButtonState extends ConsumerState<MessageReminderButton> {
  bool _opening = false;
  Completer<WhisperSettingsSnapshot?>? _pending;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.title,
    onPressed: _opening ? null : _open,
    icon: widget.icon,
  );

  Future<void> _open() async {
    setState(() => _opening = true);
    final provider = whisperSettingsProvider(widget.type);
    final pending = _pending = Completer<WhisperSettingsSnapshot?>();
    // 读取、选择和保存期间持有设置句柄，弹窗只接收已完成的结果。
    final subscription = ref.listenManual(provider, (_, snapshot) {
      if (snapshot.loadingState is! Loading && !pending.isCompleted) {
        pending.complete(snapshot);
      }
    }, fireImmediately: true);
    try {
      final snapshot = await pending.future;
      if (!mounted || snapshot == null) return;
      final settings = snapshot.loadingState.dataOrNull;
      if (settings == null) {
        snapshot.loadingState.toast();
        return;
      }
      final entry = settings.entries
          .where(
            (e) => e.value.hasSelect() && e.value.select.item.isNotEmpty,
          )
          .firstOrNull;
      if (entry == null) {
        const Error('暂无可用的提醒设置').toast();
        return;
      }
      final options = entry.value.select.item;
      final selected = await showDialog<int>(
        context: context,
        builder: (_) => SelectDialog<int>(
          title: snapshot.title.isEmpty ? widget.title : snapshot.title,
          value: options.indexWhere((option) => option.selected),
          values: [
            for (var i = 0; i < options.length; i++) (i, options[i].text),
          ],
        ),
      );
      if (!mounted || selected == null || options[selected].selected) return;
      final updated = entry.value.deepCopy();
      for (var i = 0; i < updated.select.item.length; i++) {
        updated.select.item[i].selected = i == selected;
      }
      final result = await ref
          .read(provider.notifier)
          .setSetting(entry.key, updated);
      if (mounted && !result.isSuccess) result.toast();
    } finally {
      subscription.close();
      _pending = null;
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    super.dispose();
  }
}
