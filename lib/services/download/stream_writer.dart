import 'dart:async';

/// 由目标消费者控制源流读取速度，避免慢盘写入时无限积压数据。
/// 不关闭消费者，由下载任务统一处理成功、取消和错误时的生命周期。
Future<int> writeDownloadStream(
  Stream<List<int>> source,
  StreamConsumer<List<int>> destination, {
  int initialBytes = 0,
  void Function(int received)? onProgress,
}) async {
  var received = initialBytes;
  await destination.addStream(
    source.map((chunk) {
      received += chunk.length;
      onProgress?.call(received);
      return chunk;
    }),
  );
  return received;
}
