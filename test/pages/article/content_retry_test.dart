import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/dynamics/result.dart' show FilePicModel;
import 'package:pili_aurora/models/remote/fav/fav_detail/media.dart';
import 'package:pili_aurora/pages/article/controller.dart';
import 'package:pili_aurora/pages/fav_detail/controller.dart';
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    await stream?.drain<void>();
    final reply = Completer<ResponseBody>();
    pending.add(reply);
    return reply.future;
  }

  void reply(int index, Object data) => pending[index].complete(
    ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    ),
  );
  @override
  void close({bool force = false}) {}
}

class _Composer extends CommonRichTextPubPage {
  const _Composer({super.key}) : super(autofocus: false);
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends CommonRichTextPubPageState<_Composer> {
  int submissions = 0;
  @override
  Future<void> onCustomPublish({List? pictures}) async {
    submissions++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  late File syntheticImage;
  setUpAll(() async {
    GStorage.setting = await Hive.openBox(
      'audit3-settings',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox('audit3-video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox(
      'audit3-cache',
      bytes: Uint8List(0),
    );
    await GStorage.localCache.put(LocalCacheKey.mixinKey, 'synthetic');
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    syntheticImage = File(
      '${Directory.current.path}/build/implicit-state-audit/synthetic-upload.bin',
    );
    await syntheticImage.writeAsBytes([1, 2, 3]);
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  Future<void> mount(WidgetTester tester, [Widget? child]) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      home: child ?? const SizedBox(),
    ),
  );

  testWidgets('AUDIT3: article content failure can be retried', (tester) async {
    await mount(tester);
    final controller = ArticleController()
      ..type = 'opus'
      ..id = '1';
    addTearDown(controller.onClose);
    controller.init();
    await flush(tester);
    expect(adapter.pending, hasLength(1));
    adapter.reply(0, {'code': -1, 'message': 'synthetic temporary error'});
    await flush(tester);
    expect(controller.loadingState.value, isA<Error>());
    final retry = controller.onReload();
    await flush(tester);
    final count = adapter.pending.length;
    if (count > 1) {
      adapter.reply(1, {'code': -1, 'message': 'synthetic'});
      await flush(tester);
    }
    await retry;
    expect(count, 2);
  });
}
