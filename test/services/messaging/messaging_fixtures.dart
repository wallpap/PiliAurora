import 'dart:async';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

MessagingSession sessionFixture() => MessagingSession(
  account: LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'test-fixture'}),
    null,
    null,
  ),
  key: (mid: 123, generation: 1),
);

Message message(int sequence) => Message(
  id: '$sequence',
  messageKey: sequence,
  sequence: sequence,
  senderId: 456,
  timestamp: 1,
  type: 1,
  source: 1,
  content: TextMessageContent('$sequence'),
);
ConversationPage page(
  List<int> ids, {
  bool hasOlder = true,
  Iterable<EmotionSticker> emotions = const [],
}) => ConversationPage(
  messages: ids.map(message),
  hasOlder: hasOlder,
  cursor: ids.last,
  emotions: emotions,
);
Future<void> settle() => Future<void>.delayed(Duration.zero);

class FakeConversationAdapter implements ConversationAdapter {
  final sent = <({Account account, MessageContent content})>[];
  final latestRequests = <Completer<LoadingState<ConversationPage>>>[];
  final olderRequests = <Completer<LoadingState<ConversationPage>>>[];
  final acknowledgements = <int>[];
  Future<LoadingState<void>> Function()? sendRequest;
  LoadingState<void> ackResult = const Success(null);
  Future<LoadingState<void>> Function()? acknowledgeRequest;
  @override
  Future<LoadingState<ConversationPage>> latest(
    Account account,
    ConversationTarget target,
  ) {
    final request = Completer<LoadingState<ConversationPage>>();
    latestRequests.add(request);
    return request.future;
  }

  @override
  Future<LoadingState<ConversationPage>> older(
    Account account,
    ConversationTarget target,
    int cursor,
  ) {
    final request = Completer<LoadingState<ConversationPage>>();
    olderRequests.add(request);
    return request.future;
  }

  @override
  Future<LoadingState<void>> send(
    Account account,
    ConversationTarget target,
    MessageContent content,
  ) async {
    sent.add((account: account, content: content));
    return await sendRequest?.call() ?? const Success(null);
  }

  @override
  Future<LoadingState<void>> acknowledge(
    Account account,
    ConversationTarget target,
    int sequence,
  ) async {
    acknowledgements.add(sequence);
    return await acknowledgeRequest?.call() ?? ackResult;
  }

  @override
  Future<LoadingState<void>> recall(
    Account account,
    ConversationTarget target,
    int messageKey,
  ) async => const Success(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
