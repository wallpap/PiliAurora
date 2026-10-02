import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pili_aurora/http/response_decoder.dart';

/// 大响应在一次后台任务中完成解压、UTF-8 和 JSON 转换。
class CompressedResponseTransformer extends BackgroundTransformer {
  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) async {
    if (options.responseType == ResponseType.stream ||
        options.responseType == ResponseType.bytes ||
        options.responseDecoder != null) {
      return super.transformResponse(options, responseBody);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in responseBody.stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final encoding = responseBody.headers['content-encoding']?.firstOrNull;
    final parseJson =
        options.responseType == ResponseType.json &&
        Transformer.isJsonMimeType(
          responseBody.headers[Headers.contentTypeHeader]?.firstOrNull,
        );
    if (ResponseBodyDecoder.shouldUseIsolate(bytes, encoding)) {
      return _decodeInBackground((
        TransferableTypedData.fromList([bytes]),
        encoding,
        parseJson,
      ));
    }
    return _decode(bytes, encoding, parseJson);
  }
}

Object? _decode(List<int> bytes, String? encoding, bool parseJson) {
  final text = utf8.decode(
    ResponseBodyDecoder.decompress(bytes, encoding),
    allowMalformed: true,
  );
  return parseJson && text.isNotEmpty ? jsonDecode(text) : text;
}

Future<Object?> _decodeInBackground(
  (TransferableTypedData, String?, bool) args,
) => Isolate.run(
  () => _decode(
    args.$1.materialize().asUint8List(),
    args.$2,
    args.$3,
  ),
);
