import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/settings.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

import 'messaging_fixtures.dart';

class ControlledSession extends MessagingSession {
  ControlledSession()
    : super(account: sessionFixture().account, key: (mid: 123, generation: 1));

  final requests = <Completer<LoadingState<void>>>[];
  final reads = <Completer<LoadingState<GetImSettingsReply>>>[];

  @override
  Future<LoadingState<T>> run<T>(
    Future<LoadingState<T>> Function(Account) request,
  ) {
    if (T == GetImSettingsReply) {
      final pending = Completer<LoadingState<GetImSettingsReply>>();
      reads.add(pending);
      return pending.future as Future<LoadingState<T>>;
    }
    final pending = Completer<LoadingState<void>>();
    requests.add(pending);
    return pending.future as Future<LoadingState<T>>;
  }
}

Setting setting(bool value) =>
    Setting(switch_1: SettingSwitch(switchOn: value));

void main() {
  WhisperSettingsHandle createHandle(ControlledSession session) {
    final handle = WhisperSettingsHandle(
      session: session,
      type: IMSettingType.SETTING_TYPE_NEED_ALL,
    );
    addTearDown(handle.dispose);
    addTearDown(session.dispose);
    handle.state.value = WhisperSettingsSnapshot(
      loadingState: Success(
        GetImSettingsReply(settings: [MapEntry(1, setting(false))]).settings,
      ),
    );
    return handle;
  }

  for (final (firstSucceeds, secondSucceeds, confirmed) in [
    (false, false, false),
    (true, false, true),
    (false, true, false),
    (true, true, false),
  ]) {
    test(
      '同键串行写入 success=$firstSucceeds/$secondSucceeds，保留最新意图并按确认结果回滚',
      () async {
        final session = ControlledSession();
        final handle = createHandle(session);
        bool selected() =>
            handle.state.value.loadingState.dataOrNull![1]!.switch_1.switchOn;
        final first = handle.setSetting(1, setting(true));
        final second = handle.setSetting(1, setting(false));
        expect(selected(), isFalse);
        expect(session.requests, hasLength(1));
        session.requests.single.complete(
          firstSucceeds ? const Success(null) : const Error('失败'),
        );
        await first;
        expect(selected(), isFalse);
        await settle();
        expect(session.requests, hasLength(2));
        session.requests.last.complete(
          secondSucceeds ? const Success(null) : const Error('失败'),
        );
        await second;
        expect(selected(), confirmed);
      },
    );
  }

  test('不同设置项可并发写入，分别确认或回滚', () async {
    final session = ControlledSession();
    final handle = createHandle(session);
    final first = handle.setSetting(1, setting(true));
    final second = handle.setSetting(2, setting(true));
    expect(session.requests, hasLength(2));
    expect(
      handle.state.value.loadingState.dataOrNull![1]!.switch_1.switchOn,
      true,
    );
    expect(
      handle.state.value.loadingState.dataOrNull![2]!.switch_1.switchOn,
      true,
    );
    session.requests[1].complete(const Error('失败'));
    session.requests[0].complete(const Success(null));
    await Future.wait([first, second]);
    expect(handle.state.value.loadingState.dataOrNull!.containsKey(2), false);
    expect(
      handle.state.value.loadingState.dataOrNull![1]!.switch_1.switchOn,
      true,
    );
  });

  test('刷新等待所有在途写入，随后读取服务器状态', () async {
    final session = ControlledSession();
    final handle = createHandle(session);
    final write = handle.setSetting(1, setting(true));
    final refresh = handle.refresh();
    expect(session.reads, isEmpty);
    expect(
      handle.state.value.loadingState.dataOrNull![1]!.switch_1.switchOn,
      true,
    );
    session.requests.single.complete(const Success(null));
    await write;
    await settle();
    expect(session.reads, hasLength(1));
    session.reads.single.complete(
      Success(GetImSettingsReply(settings: [MapEntry(1, setting(true))])),
    );
    await refresh;
    expect(
      handle.state.value.loadingState.dataOrNull![1]!.switch_1.switchOn,
      true,
    );
  });

  test('释放或账号失效后不发送排队的写入', () async {
    for (final disposeHandle in [true, false]) {
      final session = ControlledSession();
      final handle = createHandle(session);
      final first = handle.setSetting(1, setting(true));
      final second = handle.setSetting(1, setting(false));
      if (disposeHandle) {
        handle.dispose();
      } else {
        session.dispose();
      }
      session.requests.single.complete(const Success(null));
      expect((await first).isSuccess, false);
      expect((await second).isSuccess, false);
      expect(session.requests, hasLength(1));
    }
  });
}
