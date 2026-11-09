import 'dart:convert';

import 'package:pili_aurora/build_config.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/sponsor_block_api.dart';
import 'package:pili_aurora/models/common/sponsor_block/post_segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/remote/sponsor_block/segment_item.dart';
import 'package:pili_aurora/models/remote/sponsor_block/user_info.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

/// 使用 HTTP 状态码的第三方协议，不套用 B 站 code/message/data 业务包体。
abstract final class SponsorBlock {
  static String get blockServer => Pref.blockServer;

  static Error _httpError(
    int? status, {
    Object? cause,
    StackTrace? stackTrace,
  }) => Error(
    switch (status) {
      400 => '参数错误',
      403 => '被自动审核机制拒绝',
      404 => '未找到数据',
      409 => '重复提交',
      429 => '提交太快，请稍后再试',
      500 => '服务器无法获取信息',
      _ => status == null ? '未收到有效的服务器响应' : '服务器响应异常（HTTP $status）',
    },
    code: status,
    cause: cause,
    stackTrace: stackTrace,
  );

  static bool _isRejection(int? status) =>
      status != null && status >= 400 && status < 500 && status != 408;

  static Future<LoadingState<T>> _request<T>(
    String endpoint, {
    required ApiCallKind kind,
    required T Function(dynamic body) decode,
    Map<String, dynamic>? queryParameters,
    Object? data,
  }) async {
    final server = blockServer.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(server);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return const Error('空降助手服务器地址无效，请检查设置');
    }
    final Response<dynamic> response;
    try {
      Request();
      response = await Request.dio.request<dynamic>(
        '$server/api/$endpoint',
        data: data,
        queryParameters: queryParameters,
        options: Options(
          method: kind == ApiCallKind.query ? 'GET' : 'POST',
          followRedirects: true,
          headers: kDebugMode
              ? null
              : {
                  'origin': Constants.appName,
                  'x-ext-version': BuildConfig.versionName,
                },
          // 自定义服务器不使用 B 站账号，且写入无论重试设置如何都不能重放。
          extra: {
            'account': const NoAccount(),
            'noRetry': kind == ApiCallKind.mutation,
          },
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (error, stackTrace) {
      final status = error.response?.statusCode;
      if (_isRejection(status)) {
        return _httpError(status, cause: error, stackTrace: stackTrace);
      }
      if (kind == ApiCallKind.mutation) {
        return UnknownResult(cause: error, stackTrace: stackTrace);
      }
      return Error(
        await AccountManager.dioError(error),
        code: status,
        cause: error,
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      final failure = Error.fromException(error, stackTrace);
      return kind == ApiCallKind.mutation
          ? UnknownResult(cause: error, stackTrace: stackTrace)
          : failure;
    }
    if (response.statusCode != 200) {
      final failure = _httpError(response.statusCode);
      return kind == ApiCallKind.mutation && !_isRejection(response.statusCode)
          ? UnknownResult(cause: failure)
          : failure;
    }
    try {
      return Success(decode(response.data));
    } catch (error, stackTrace) {
      final failure = Error.fromException(error, stackTrace);
      return kind == ApiCallKind.mutation
          ? UnknownResult(cause: error, stackTrace: stackTrace)
          : failure;
    }
  }

  static List<SegmentItemModel> _segments(dynamic body) =>
      (body as List).map((item) => SegmentItemModel.fromJson(item)).toList();

  static String _requiredString(dynamic body, String field) {
    if (body is Map<String, dynamic>) {
      if (body[field] case final String value when value.trim().isNotEmpty) {
        return value;
      }
    }
    throw FormatException('空降助手响应缺少有效 $field');
  }

  static Future<LoadingState<List<SegmentItemModel>>> getSkipSegments({
    required String bvid,
    required int cid,
  }) => _request(
    SponsorBlockApi.skipSegments,
    kind: ApiCallKind.query,
    decode: _segments,
    queryParameters: {'videoID': bvid, 'cid': cid},
  );

  static Future<LoadingState<void>> voteOnSponsorTime({
    required String uuid,
    int? type,
    SegmentType? category,
  }) async {
    if (uuid.trim().isEmpty || (type == null) == (category == null)) {
      return const Error('请选择有效片段及一种投票方式');
    }
    return _request<void>(
      SponsorBlockApi.voteOnSponsorTime,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'UUID': uuid,
        'type': ?type,
        'category': ?category?.name,
        'userID': Pref.blockUserID,
      },
    );
  }

  static Future<LoadingState<void>> viewedVideoSponsorTime(String uuid) async {
    if (uuid.trim().isEmpty) return const Error('片段标识无效');
    return _request<void>(
      SponsorBlockApi.viewedVideoSponsorTime,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {'UUID': uuid},
    );
  }

  static Future<LoadingState<void>> uptimeStatus() => _request<void>(
    SponsorBlockApi.uptimeStatus,
    kind: ApiCallKind.query,
    decode: (body) {
      final value = body is String ? double.tryParse(body) : null;
      if (value == null || !value.isFinite || value < 0) {
        throw const FormatException('空降助手运行状态无效');
      }
    },
  );

  static Future<LoadingState<UserInfo>> userInfo(
    List<String> query, {
    String? userId,
  }) => _request(
    SponsorBlockApi.userInfo,
    kind: ApiCallKind.query,
    decode: (body) => UserInfo.fromJson(body),
    queryParameters: {
      'userID': userId ?? Pref.blockUserID,
      'values': jsonEncode(query),
    },
  );

  static Future<LoadingState<List<SegmentItemModel>>> postSkipSegments({
    required String bvid,
    required int cid,
    required double videoDuration,
    required List<PostSegmentModel> segments,
  }) async {
    if (bvid.trim().isEmpty ||
        cid <= 0 ||
        !videoDuration.isFinite ||
        videoDuration <= 0) {
      return const Error('视频信息尚未就绪，请稍后再提交');
    }
    if (segments.isEmpty ||
        segments.any((item) {
          final start = item.segment.first;
          final end = item.segment.second;
          return !start.isFinite ||
              !end.isFinite ||
              start < 0 ||
              end < start ||
              end > videoDuration;
        })) {
      return const Error('请检查片段的开始和结束时间');
    }
    return _request(
      SponsorBlockApi.skipSegments,
      kind: ApiCallKind.mutation,
      decode: _segments,
      data: {
        'videoID': bvid,
        'cid': cid.toString(),
        'userID': Pref.blockUserID,
        'userAgent': kDebugMode
            ? Constants.userAgent
            : '${Constants.appName}/${BuildConfig.versionName}',
        'videoDuration': videoDuration,
        'segments': segments
            .map(
              (item) => {
                'segment': [item.segment.first, item.segment.second],
                'category': item.category.name,
                'actionType': item.actionType.name,
              },
            )
            .toList(),
      },
    );
  }

  static Future<LoadingState<String>> getPortVideo({
    required String bvid,
    required int cid,
  }) => _request(
    SponsorBlockApi.portVideo,
    kind: ApiCallKind.query,
    decode: (body) => _requiredString(body, 'ytbID'),
    queryParameters: {'videoID': bvid, 'cid': cid.toString()},
  );

  static Future<LoadingState<String>> postPortVideo({
    required String bvid,
    required int cid,
    required String ytbId,
    required int videoDuration,
  }) async {
    if (bvid.trim().isEmpty ||
        cid <= 0 ||
        ytbId.trim().isEmpty ||
        videoDuration <= 0) {
      return const Error('视频绑定信息不完整，请重新打开视频');
    }
    return _request(
      SponsorBlockApi.portVideo,
      kind: ApiCallKind.mutation,
      decode: (body) => _requiredString(body, 'UUID'),
      data: {
        'bvID': bvid,
        'cid': cid.toString(),
        'ytbID': ytbId,
        'userID': Pref.blockUserID,
        'biliDuration': videoDuration,
      },
    );
  }
}
