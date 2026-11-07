import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/user/danmaku_block.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class DanmakuFilterHttp {
  static Future<LoadingState<DanmakuBlockDataModel>> danmakuFilter({
    Account? account,
  }) async {
    final res = await Request().get(
      Api.danmakuFilter,
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
    if (res.data['code'] == 0) {
      return Success(DanmakuBlockDataModel.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> danmakuFilterDel({
    required int ids,
    Account? account,
  }) async {
    account ??= Accounts.main;
    final res = await Request().post(
      Api.danmakuFilterDel,
      data: {
        'ids': ids,
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account, 'noRetry': true},
      ),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<SimpleRule>> danmakuFilterAdd({
    required String filter,
    required int type,
    Account? account,
  }) async {
    account ??= Accounts.main;
    final res = await Request().post(
      Api.danmakuFilterAdd,
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
    if (res.data['code'] == 0) {
      return Success(SimpleRule.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }
}
