import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Box<T> implements Box<T> {
  final stored = <dynamic, T>{};

  @override
  T? get(dynamic key, {T? defaultValue}) => stored[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, T value) async => stored[key] = value;

  @override
  Future<void> delete(dynamic key) async => stored.remove(key);

  @override
  Future<int> clear() async {
    final count = stored.length;
    stored.clear();
    return count;
  }

  @override
  Iterable<T> get values => stored.values;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Box<LoginAccount> accounts;
  late LoginAccount mainAccount;
  late LoginAccount recommendAccount;
  late ProviderContainer container;
  late MessagingSession mainSession;
  final mainUpdates = <Account>[];
  final recommendUpdates = <Account>[];

  LoginAccount login(int mid, {String csrf = 'fixture'}) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;

  void expectMainUnchanged() {
    expect(mainUpdates, [same(mainAccount)]);
    expect(container.read(mainAccountProvider), same(mainAccount));
    expect(Messaging.instance.session, same(mainSession));
    expect(mainSession.isActive, isTrue);
  }

  setUpAll(() {
    GStorage.setting = _Box<dynamic>();
    GStorage.localCache = _Box<dynamic>();
    accounts = _Box<LoginAccount>();
    Accounts.account = accounts;
    AnonymousAccount().activated = true;
  });

  setUp(() {
    accounts.stored.clear();
    for (final role in AccountType.values) {
      Accounts.accountMode[role.index] = AnonymousAccount();
    }
    mainAccount = login(100)..type.add(AccountType.main);
    recommendAccount = login(200)..type.add(AccountType.recommend);
    Accounts.accountMode[AccountType.main.index] = mainAccount;
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount;
    accounts.stored.addAll({'100': mainAccount, '200': recommendAccount});
    mainSession = Messaging.instance.session;
    mainUpdates.clear();
    recommendUpdates.clear();
    container = ProviderContainer()
      ..listen(
        mainAccountProvider,
        (_, next) => mainUpdates.add(next),
        fireImmediately: true,
      )
      ..listen(
        recommendAccountProvider,
        (_, next) => recommendUpdates.add(next),
        fireImmediately: true,
      );
  });

  tearDown(() {
    container.dispose();
    for (final role in AccountType.values) {
      Accounts.accountMode[role.index] = AnonymousAccount();
    }
    Messaging.instance.session;
  });

  test('真实推荐账号切换发布同 mid 的新凭据，不重建主账号及消息 Session', () async {
    final next = login(200, csrf: 'renewed');
    await Accounts.set(AccountType.recommend, next);
    await container.pump();

    expect(recommendUpdates, [same(recommendAccount), same(next)]);
    expect(container.read(recommendAccountProvider), same(next));
    expect(next.type, contains(AccountType.recommend));
    expectMainUnchanged();
  });

  test('仅注销推荐账号立即发布匿名身份，保持主账号及消息 Session', () async {
    await Accounts.deleteAll({recommendAccount});
    await container.pump();

    expect(recommendUpdates, [
      same(recommendAccount),
      same(AnonymousAccount()),
    ]);
    expect(container.read(recommendAccountProvider).isLogin, isFalse);
    expectMainUnchanged();
  });

  test('仅重新登录推荐账号使旧凭据失效，保持主账号及消息 Session', () async {
    final next = login(200, csrf: 'renewed');
    Accounts.replaceCredentials(next);
    await container.pump();

    expect(recommendUpdates, [same(recommendAccount), same(next)]);
    expect(container.read(recommendAccountProvider), same(next));
    expectMainUnchanged();
  });

  test('仅主账号凭据变化不重建推荐账号，消息 Session 继续随主账号替换', () async {
    final next = login(100, csrf: 'renewed');
    Accounts.replaceCredentials(next);
    await container.pump();

    expect(mainUpdates, [same(mainAccount), same(next)]);
    expect(recommendUpdates, [same(recommendAccount)]);
    expect(mainSession.isActive, isFalse);
    expect(Messaging.instance.session.account, same(next));
    expect(container.read(recommendAccountProvider), same(recommendAccount));
  });

  test('共享账号重新登录同时替换两个角色，只替换一次消息 Session', () async {
    await Accounts.set(AccountType.recommend, mainAccount);
    await container.pump();
    expectMainUnchanged();
    var messagingChanges = 0;
    void changed() => messagingChanges++;
    Messaging.instance.current.addListener(changed);
    addTearDown(() => Messaging.instance.current.removeListener(changed));

    final next = login(100, csrf: 'renewed');
    Accounts.replaceCredentials(next);
    await container.pump();

    expect(mainUpdates, [same(mainAccount), same(next)]);
    expect(recommendUpdates, [
      same(recommendAccount),
      same(mainAccount),
      same(next),
    ]);
    expect(next.type, containsAll([AccountType.main, AccountType.recommend]));
    expect(messagingChanges, 1);
  });

  test('账号刷新发布存储中的推荐凭据', () async {
    final next = login(200, csrf: 'renewed')..type.add(AccountType.recommend);
    await accounts.put('200', next);
    await Accounts.refresh();
    await container.pump();

    expect(mainUpdates, [same(mainAccount)]);
    expect(recommendUpdates, [same(recommendAccount), same(next)]);
    expect(container.read(recommendAccountProvider), same(next));
  });

  test('清空账号同时发布主账号及推荐账号的匿名身份', () async {
    await Accounts.clear();
    await container.pump();

    expect(mainUpdates, [same(mainAccount), same(AnonymousAccount())]);
    expect(recommendUpdates, [
      same(recommendAccount),
      same(AnonymousAccount()),
    ]);
    expect(mainSession.isActive, isFalse);
    expect(Messaging.instance.session.account.isLogin, isFalse);
  });

  test('最后一个订阅释放后不继续接收账号变更', () {
    container.dispose();
    Accounts.replaceCredentials(login(200, csrf: 'renewed'));

    expect(mainUpdates, [same(mainAccount)]);
    expect(recommendUpdates, [same(recommendAccount)]);
    container = ProviderContainer();
    expect(
      container.read(recommendAccountProvider),
      same(Accounts.get(AccountType.recommend)),
    );
  });
}
