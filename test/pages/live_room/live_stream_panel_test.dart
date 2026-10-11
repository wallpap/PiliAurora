import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/format.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/stream.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/url_info.dart';
import 'package:pili_aurora/pages/live_room/widgets/live_stream_panel.dart';

void main() {
  testWidgets('线路列表保留跨格式和编码的选择索引并标明当前线路', (tester) async {
    final streams = [
      Stream(
        protocolName: 'http_stream',
        format: [
          Format(
            formatName: 'flv',
            codec: [
              CodecItem(
                codecName: 'avc',
                currentQn: 10000,
                acceptQn: [10000],
                baseUrl: '',
                urlInfo: [
                  UrlInfo(host: '', extra: ''),
                  UrlInfo(host: '', extra: ''),
                ],
              ),
            ],
          ),
          Format(
            formatName: 'ts',
            codec: [
              CodecItem(
                codecName: 'hevc',
                currentQn: 10000,
                acceptQn: [10000],
                baseUrl: '',
                urlInfo: [UrlInfo(host: '', extra: '')],
              ),
            ],
          ),
        ],
      ),
    ];
    LiveStreamSelection? selection;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 400,
            child: LiveStreamPanel(
              streams: streams,
              current: (stream: 0, format: 0, codec: 0, url: 1),
              onSelected: (value) => selection = value,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('当前使用'), findsOneWidget);
    await tester.tap(find.text('线路 2'));
    expect(selection, isNull);
    await tester.tap(find.text('线路 3'));
    expect(selection, (stream: 0, format: 1, codec: 0, url: 0));
    await tester.tap(find.byTooltip('关闭'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有可用线路时提示刷新直播间', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveStreamPanel(
            streams: const [],
            current: (stream: 0, format: 0, codec: 0, url: 0),
            onSelected: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('暂无可用线路，请刷新直播间后重试。'), findsOneWidget);
  });
}
