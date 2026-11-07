import 'package:hive_ce/hive.dart';

/// 页面与状态测试共用的内存存储；未实现的操作直接报错。
class MemoryBox<T> implements Box<T> {
  MemoryBox([Map<dynamic, T>? initial]) : data = Map.of(initial ?? {});

  final Map<dynamic, T> data;

  @override
  T? get(dynamic key, {T? defaultValue}) => data[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async => data[key] = value;
  @override
  Future<void> putAll(Map<dynamic, T> entries) async => data.addAll(entries);
  @override
  Future<void> delete(dynamic key) async => data.remove(key);
  @override
  Future<int> clear() async {
    final count = data.length;
    data.clear();
    return count;
  }

  @override
  Iterable<T> get values => data.values;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
