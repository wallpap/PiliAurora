import 'package:pili_aurora/app/bootstrap.dart';
import 'package:pili_aurora/pages/setting/decoder_test_process.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.firstOrNull == decoderTestWorkerArgument) {
    await runDecoderTestWorker();
  } else {
    // 启动结果由装配层交付：主窗口显示错误页，播放子进程以失败码结束。
    await bootstrapApplication(arguments);
  }
}
