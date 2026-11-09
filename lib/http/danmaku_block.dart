import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/user/danmaku_block.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class DanmakuFilterHttp {
  static Future<LoadingState<DanmakuBlockDataModel>> danmakuFilter({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.danmakuFilter,
      kind: ApiCallKind.query,
      decode: (body) {
        final data = body['data'] as Map<String, dynamic>;
        if (data['rule'] != null && data['rule'] is! List) {
          throw const FormatException('屏蔽规则列表格式无效');
        }
        return DanmakuBlockDataModel.fromJson(data);
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> danmakuFilterDel({
    required int ids,
    required Account account,
  }) async {
    return await Request().requestApi<void>(
      Api.danmakuFilterDel,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'ids': ids,
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account, 'noRetry': true},
      ),
    );
  }

  static Future<LoadingState<SimpleRule>> danmakuFilterAdd({
    required String filter,
    required int type,
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.danmakuFilterAdd,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final rule = SimpleRule.fromJson(body['data']);
        if (rule.id <= 0 || rule.type != type) {
          throw const FormatException('新增规则响应的 ID 或类型无效');
        }
        return rule;
      },
      data: {
        'type': type,
        'filter': filter,
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account, 'noRetry': true},
      ),
    );
  }
}
