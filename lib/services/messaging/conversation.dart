import 'dart:async';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';

final Object _conversationCacheKey = Object();

ConversationCache conversationCacheFor(MessagingSession session) =>
    session.resource(
      _conversationCacheKey,
      () => ConversationCache(
        session: session,
        adapter: const GrpcConversationAdapter(),
      ),
      (cache) => cache.dispose(),
    );

/// 按账号隔离的会话业务对象；管理消息标识、分页和远端已读水位。
final class Conversation {
  Conversation({
    required this.session,
    required this.target,
    required this.adapter,
  });

  final MessagingSession session;
  final ConversationTarget target;
  final ConversationAdapter adapter;

  final _updates = StreamController<ConversationSnapshot>.broadcast(sync: true);
  final Map<String, Message> _messagesById = {};
  final List<MessageOperation> _operations = [];
  final _initialSnapshot = ConversationSnapshot.initial();

  ConversationPhase _phase = ConversationPhase.initial;
  bool _hasOlder = true;
  int? _historyCursor;
  int _highestRenderedSequence = 0;
  int _acknowledgedSequence = 0;
  int _pendingAckSequence = 0;
  int _failedAckSequence = 0;
  String? _error;
  List<EmotionSticker> _emotions = const [];
  bool _isSending = false;
  bool _isLoadingOlder = false;
  int _generation = 0;
  int _operationCounter = 0;
  Future<void>? _refreshing;
  Future<void>? _acknowledging;
  bool _disposed = false;

  ConversationSnapshot get snapshot =>
      _messagesById.isEmpty &&
          _phase == ConversationPhase.initial &&
          !_isSending
      ? _initialSnapshot
      : ConversationSnapshot(
          phase: _phase,
          messages: _orderedMessages,
          hasOlder: _hasOlder,
          historyCursor: _historyCursor,
          highestRenderedSequence: _highestRenderedSequence,
          acknowledgedSequence: _acknowledgedSequence,
          error: _error,
          emotions: _emotions,
          operations: _operations,
          isSending: _isSending,
        );

  Stream<ConversationSnapshot> get snapshots => Stream.multi((controller) {
    controller.add(snapshot);
    final subscription = _updates.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });

  List<Message> get _orderedMessages {
    final values = _messagesById.values.toList()
      ..sort((a, b) {
        final sequenceOrder = b.sequence.compareTo(a.sequence);
        return sequenceOrder != 0
            ? sequenceOrder
            : b.messageKey.compareTo(a.messageKey);
      });
    return values;
  }

  Future<void> open() => refresh(retryFailedAcknowledgement: false);

  Future<void> refresh({
    bool retryFailedAcknowledgement = true,
    bool force = false,
  }) {
    if (_disposed || !session.isActive) return Future.value();
    if (retryFailedAcknowledgement) _failedAckSequence = 0;
    final active = _refreshing;
    if (active != null && !force) {
      return active.whenComplete(() {
        if (retryFailedAcknowledgement) _retryPendingAcknowledgement();
      });
    }
    final generation = ++_generation;
    final operation = _refresh(generation);
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
      if (retryFailedAcknowledgement) _retryPendingAcknowledgement();
    });
  }

  void _retryPendingAcknowledgement() {
    if (!_disposed && _pendingAckSequence > _acknowledgedSequence) {
      unawaited(_drainAcknowledgements());
    }
  }

  Future<void> _refresh(int generation) async {
    _error = null;
    _phase = _messagesById.isEmpty
        ? ConversationPhase.loading
        : ConversationPhase.refreshing;
    _emit();
    try {
      final result = await session.run(
        (account) => adapter.latest(account, target),
      );
      if (!_canApply(generation)) return;
      switch (result) {
        case Success<ConversationPage>(:final response):
          _merge(response.messages);
          _historyCursor = response.cursor;
          _hasOlder = response.hasOlder;
          _mergeEmotions(response.emotions);
          _phase = ConversationPhase.ready;
          _error = null;
        case Error(:final errMsg):
          _phase = _messagesById.isEmpty
              ? ConversationPhase.failed
              : ConversationPhase.ready;
          _error = errMsg;
        case Loading():
          _phase = _messagesById.isEmpty
              ? ConversationPhase.failed
              : ConversationPhase.ready;
          _error = '消息读取状态未知';
      }
    } catch (error) {
      if (!_canApply(generation)) return;
      _phase = _messagesById.isEmpty
          ? ConversationPhase.failed
          : ConversationPhase.ready;
      _error = error.toString();
    } finally {
      if (!_disposed && generation == _generation) _emit();
    }
  }

  Future<void> loadOlder() async {
    if (_disposed ||
        !session.isActive ||
        _isLoadingOlder ||
        !_hasOlder ||
        _historyCursor == null) {
      return;
    }
    final generation = _generation;
    final cursor = _historyCursor!;
    _isLoadingOlder = true;
    _phase = ConversationPhase.loadingOlder;
    _error = null;
    _emit();
    try {
      final result = await session.run(
        (account) => adapter.older(account, target, cursor),
      );
      if (!_canApply(generation)) return;
      switch (result) {
        case Success<ConversationPage>(:final response):
          _merge(response.messages);
          if (response.cursor != null &&
              (_historyCursor == null || response.cursor! < _historyCursor!)) {
            _historyCursor = response.cursor;
          }
          _hasOlder = response.hasOlder;
          _mergeEmotions(response.emotions);
          _phase = ConversationPhase.ready;
        case Error(:final errMsg):
          _phase = ConversationPhase.ready;
          _error = errMsg;
        case Loading():
          _phase = ConversationPhase.ready;
          _error = '历史消息读取状态未知';
      }
    } catch (error) {
      if (!_canApply(generation)) return;
      _phase = ConversationPhase.ready;
      _error = error.toString();
    } finally {
      _isLoadingOlder = false;
      if (!_disposed && generation == _generation) _emit();
    }
  }

  Future<OperationResult> sendText(String text) => _send(
    TextMessageContent(text),
    kind: 'text',
  );

  Future<OperationResult> sendImage(String path) => _send(
    null,
    imagePath: path,
    kind: 'image',
  );

  Future<OperationResult> sendShare(
    Map<String, Object?> content, {
    String? message,
  }) => _send(
    StructuredMessageContent(
      content['source'] is String
          ? MessageContentKind.commonShareCard
          : MessageContentKind.shareV2,
      content,
    ),
    kind: 'share',
    followUpText: message,
  );

  Future<OperationResult> _send(
    MessageContent? content, {
    String? imagePath,
    required String kind,
    String? followUpText,
  }) async {
    if (_isSending) return const OperationResult.failure('正在发送');
    if (_disposed || !session.isActive) {
      return const OperationResult.failure('账号已切换或未登录');
    }
    if (content case TextMessageContent(:final text) when text.trim().isEmpty) {
      return const OperationResult.failure('消息不能为空');
    }

    final operationId = _newOperationId();
    _isSending = true;
    _setOperation(operationId, kind, OperationStatus.sending);
    _phase = ConversationPhase.ready;
    _error = null;
    _emit();
    OperationResult result;
    try {
      MessageContent? outgoing = content;
      if (imagePath != null) {
        final uploaded = await session.run(
          (account) => adapter.uploadImage(account, imagePath),
        );
        if (uploaded case Success<UploadedMessageImage>(:final response)) {
          outgoing = ImageMessageContent(
            url: response.url,
            width: response.width.toDouble(),
            height: response.height.toDouble(),
            size: response.size,
            imageType: response.imageType,
          );
        } else {
          result = _operationResult(uploaded, operationId);
          _setOperation(operationId, kind, result.status);
          return result;
        }
      }

      if (outgoing == null) {
        result = OperationResult.failure('消息内容无效', operationId);
        _setOperation(operationId, kind, result.status);
        return result;
      }
      final sent = await session.run(
        (account) => adapter.send(account, target, outgoing!),
      );
      result = _operationResult(sent, operationId);
      final contentSent = result.isSuccess;
      if (contentSent && followUpText?.isNotEmpty == true) {
        final followUp = await session.run(
          (account) => adapter.send(
            account,
            target,
            TextMessageContent(followUpText!),
          ),
        );
        final followUpResult = _operationResult(followUp, operationId);
        result = followUpResult.isSuccess
            ? followUpResult
            : OperationResult(
                followUpResult.status,
                message:
                    '分享内容已发送，附言${followUpResult.status == OperationStatus.unknown ? '状态待确认，请核对聊天记录' : '未发送成功'}',
                operationId: operationId,
              );
      }
      _setOperation(operationId, kind, result.status);
      if (contentSent || result.status == OperationStatus.unknown) {
        // 写入后的读取必须晚于本次发送，废弃发送前的在途查询。
        unawaited(refresh(retryFailedAcknowledgement: false, force: true));
        session.notifyChanged(
          MessagingChangeKind.unread,
          talkerId: target.talkerId,
        );
      }
      return result;
    } catch (error) {
      result = OperationResult.unknown(error.toString(), operationId);
      _setOperation(operationId, kind, result.status);
      unawaited(refresh(retryFailedAcknowledgement: false, force: true));
      return result;
    } finally {
      _isSending = false;
      _emit();
    }
  }

  Future<OperationResult> recall(Message message) async {
    if (_disposed || !session.isActive) {
      return const OperationResult.failure('账号已切换或未登录');
    }
    if (message.messageKey <= 0) {
      return const OperationResult.failure('消息缺少稳定标识');
    }
    final operationId = _newOperationId();
    _setOperation(operationId, 'recall', OperationStatus.sending);
    try {
      final response = await session.run(
        (account) => adapter.recall(account, target, message.messageKey),
      );
      final result = _operationResult(response, operationId);
      _setOperation(operationId, 'recall', result.status);
      if (result.isSuccess) {
        _messagesById.updateAll(
          (_, item) => item.messageKey == message.messageKey
              ? item.copyWith(recalled: true)
              : item,
        );
        session.notifyChanged(
          MessagingChangeKind.conversation,
          talkerId: target.talkerId,
        );
        _emit();
      }
      return result;
    } catch (error) {
      final result = OperationResult.unknown(error.toString(), operationId);
      _setOperation(operationId, 'recall', result.status);
      return result;
    }
  }

  Future<OperationResult> report(
    Message message,
    int reasonType,
    String reasonDescription,
  ) async {
    if (_disposed || !session.isActive) {
      return const OperationResult.failure('账号已切换或未登录');
    }
    try {
      final response = await session.run(
        (account) => adapter.report(
          account,
          message,
          reasonType,
          reasonDescription,
        ),
      );
      return _operationResult(response, _newOperationId());
    } catch (error) {
      return OperationResult.failure(error.toString());
    }
  }

  /// 消息行完成布局后调用。ACK 水位单调递增，加载旧历史不会回退水位。
  void markRendered(Message message) {
    if (_disposed || !session.isActive || message.sequence <= 0) return;
    if (message.sequence > _highestRenderedSequence) {
      _highestRenderedSequence = message.sequence;
      _emit();
    }
    final onlyPrompt =
        _messagesById.length == 1 && message.type == 18 && message.source == 18;
    if (onlyPrompt) return;
    if (message.sequence > _pendingAckSequence) {
      _pendingAckSequence = message.sequence;
    }
    if (_pendingAckSequence > _acknowledgedSequence &&
        _pendingAckSequence > _failedAckSequence) {
      unawaited(_drainAcknowledgements());
    }
  }

  Future<OperationResult> _drainAcknowledgements() {
    final active = _acknowledging;
    if (active != null) {
      return active.then((_) => const OperationResult.success());
    }
    final task = _acknowledgePending();
    _acknowledging = task;
    return task.whenComplete(() {
      if (identical(_acknowledging, task)) _acknowledging = null;
      if (!_disposed &&
          _pendingAckSequence > _acknowledgedSequence &&
          _pendingAckSequence > _failedAckSequence) {
        unawaited(_drainAcknowledgements());
      }
    });
  }

  Future<OperationResult> _acknowledgePending() async {
    while (!_disposed &&
        session.isActive &&
        _pendingAckSequence > _acknowledgedSequence) {
      final sequence = _pendingAckSequence;
      final result = await session.run(
        (account) => adapter.acknowledge(account, target, sequence),
      );
      if (_disposed || !session.isActive) {
        return const OperationResult.failure('账号已切换');
      }
      switch (result) {
        case Success<void>():
          if (sequence > _acknowledgedSequence) {
            _acknowledgedSequence = sequence;
            _failedAckSequence = 0;
            _error = null;
            _emit();
            session.notifyChanged(
              MessagingChangeKind.conversationRead,
              talkerId: target.talkerId,
            );
          }
        case Error(:final errMsg, :final code):
          _failedAckSequence = sequence;
          _error = errMsg;
          _emit();
          return code == messagingUnknownResultCode
              ? const OperationResult.unknown('已读确认结果待确认')
              : OperationResult.failure(errMsg);
        case Loading():
          _failedAckSequence = sequence;
          return const OperationResult.unknown('已读确认结果待确认');
      }
    }
    return const OperationResult.success();
  }

  void _mergeEmotions(Iterable<EmotionSticker> incoming) {
    // 缓存同时保留多页消息；同文本映射采用最近响应的版本。
    final byText = {for (final emotion in _emotions) emotion.text: emotion};
    for (final emotion in incoming) {
      byText[emotion.text] = emotion;
    }
    _emotions = List.unmodifiable(byText.values);
  }

  void _merge(Iterable<Message> incoming) {
    final recallKeys = <int>{};
    for (final message in incoming) {
      final key = message.recallTargetKey;
      if (key != null && key > 0) recallKeys.add(key);
      if (message.recallTargetKey != null) continue;
      final old = _messagesById[message.id];
      _messagesById[message.id] = message.copyWith(
        recalled: message.recalled || old?.recalled == true,
      );
    }
    if (recallKeys.isNotEmpty) {
      _messagesById.updateAll(
        (_, message) => recallKeys.contains(message.messageKey)
            ? message.copyWith(recalled: true)
            : message,
      );
    }
  }

  OperationResult _operationResult<T>(
    LoadingState<T> result,
    String operationId,
  ) => switch (result) {
    Success<T>() => OperationResult.success(operationId: operationId),
    Error(:final errMsg, :final code) =>
      code == messagingUnknownResultCode
          ? OperationResult.unknown(errMsg, operationId)
          : OperationResult.failure(errMsg, operationId),
    Loading() => OperationResult.unknown('操作结果待确认', operationId),
  };

  String _newOperationId() =>
      '${session.key.mid}:${session.key.generation}:${target.talkerId}:${++_operationCounter}';

  void _setOperation(String id, String kind, OperationStatus status) {
    final index = _operations.indexWhere((item) => item.id == id);
    final operation = MessageOperation(id: id, kind: kind, status: status);
    if (index < 0) {
      _operations.add(operation);
      if (_operations.length > 20) _operations.removeAt(0);
    } else {
      _operations[index] = operation;
    }
    _emit();
  }

  bool _canApply(int generation) =>
      !_disposed && session.isActive && generation == _generation;

  void _emit() {
    if (!_disposed && !_updates.isClosed) _updates.add(snapshot);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_updates.close());
  }
}

/// 租约保证正在显示的会话保持存活；LRU 只淘汰无租约项，并在释放后收缩缓存。
final class ConversationCache {
  ConversationCache({
    required this.session,
    required this.adapter,
    this.maximumEntries = 8,
  });

  final MessagingSession session;
  final ConversationAdapter adapter;
  final int maximumEntries;
  final Map<ConversationTarget, _ConversationEntry> _entries = {};
  bool _disposed = false;

  ConversationLease acquire(ConversationTarget target) {
    if (_disposed) throw StateError('会话缓存已释放');
    var entry = _entries.remove(target);
    entry ??= _ConversationEntry(
      Conversation(session: session, target: target, adapter: adapter),
    );
    final acquired = entry;
    acquired.leases++;
    _entries[target] = acquired;
    _trim();
    return ConversationLease(acquired.conversation, () {
      if (acquired.leases > 0) acquired.leases--;
      _trim();
    });
  }

  void _trim() {
    while (_entries.length > maximumEntries) {
      ConversationTarget? candidate;
      for (final item in _entries.entries) {
        if (item.value.leases == 0) {
          candidate = item.key;
          break;
        }
      }
      if (candidate == null) return;
      _entries.remove(candidate)!.conversation.dispose();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.conversation.dispose();
    }
    _entries.clear();
  }
}

final class _ConversationEntry {
  _ConversationEntry(this.conversation);
  final Conversation conversation;
  int leases = 0;
}

final class ConversationLease {
  ConversationLease(this.conversation, this._release);
  final Conversation conversation;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}
