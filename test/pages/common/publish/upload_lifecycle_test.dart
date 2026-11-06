import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/dynamics/result.dart' show FilePicModel;
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Composer extends CommonRichTextPubPage {
  const _Composer({super.key}) : super(autofocus: false);
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends CommonRichTextPubPageState<_Composer> {
  final upload = Completer<Map<String, dynamic>>();
  CancelToken? token;
  int submissions = 0;
  @override
  Future<Map<String, dynamic>> uploadPicture(
    FilePicModel image,
    CancelToken cancelToken,
  ) {
    token = cancelToken;
    return upload.future;
  }

  @override
  Future<void> onCustomPublish({List? pictures}) async {
    submissions++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox(
      'upload-lifecycle',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() async {
    await GStorage.setting.close();
  });
  testWidgets('关闭编辑器取消上传并阻止后续发布', (tester) async {
    final key = GlobalKey<_ComposerState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: FlutterSmartDialog.init(),
        home: _Composer(key: key),
      ),
    );
    final state = key.currentState!;
    state.imageList.add(FilePicModel(path: 'synthetic'));
    final operation = state.onPublish();
    await tester.pump();
    expect(state.token, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(state.token!.isCancelled, isTrue);
    state.upload.complete({'img_src': 'synthetic'});
    await tester.pumpAndSettle();
    await operation;
    expect(state.submissions, 0);
  });
}
