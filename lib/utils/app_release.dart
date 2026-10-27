class AppRelease {
  AppRelease._(this.tag, this.notes, this.assets, this._version);

  final String tag;
  final String notes;
  final List<({String name, String url})> assets;
  final _ReleaseVersion _version;

  static AppRelease? latestStable(Object? response) {
    if (response is! List) throw const FormatException('发布列表格式错误');
    AppRelease? latest;
    for (final item in response) {
      if (item is! Map || item['draft'] == true || item['prerelease'] == true) {
        continue;
      }
      final tag = item['tag_name'];
      if (tag is! String) continue;
      final version = _ReleaseVersion.parse(tag);
      if (version == null || version.prerelease.isNotEmpty) continue;
      final assets = <({String name, String url})>[];
      if (item['assets'] case final List entries) {
        for (final entry in entries) {
          if (entry is! Map ||
              (entry['state'] != null && entry['state'] != 'uploaded')) {
            continue;
          }
          final name = entry['name'];
          final url = entry['browser_download_url'];
          if (name is! String || url is! String) continue;
          final uri = Uri.tryParse(url);
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
            continue;
          }
          assets.add((name: name, url: url));
        }
      }
      final release = AppRelease._(
        tag,
        item['body'] is String ? item['body'] as String : '',
        List.unmodifiable(assets),
        version,
      );
      if (latest == null || version.compareTo(latest._version) > 0) {
        latest = release;
      }
    }
    return latest;
  }

  bool isNewerThan(String currentVersion) {
    final current = _ReleaseVersion.parse(currentVersion);
    if (current == null) throw const FormatException('无法识别当前版本');
    return _version.compareTo(current) > 0;
  }

  String? downloadUrl({
    required String platform,
    String? extension,
    List<String> supportedAbis = const [],
  }) {
    final candidates = assets.where((asset) {
      final name = asset.name.toLowerCase();
      return name.startsWith('piliaurora_') && name.contains('_${platform}_');
    });
    if (platform == 'windows') {
      for (final asset in candidates) {
        final name = asset.name.toLowerCase();
        if (RegExp(r'_x64(?:_|\.)').hasMatch(name) &&
            name.endsWith(extension == 'zip' ? '.zip' : '.exe')) {
          return asset.url;
        }
      }
    } else if (platform == 'android') {
      for (final abi in supportedAbis) {
        for (final asset in candidates) {
          if (asset.name.endsWith('_$abi.apk')) return asset.url;
        }
      }
    }
    return null;
  }
}

class _ReleaseVersion implements Comparable<_ReleaseVersion> {
  _ReleaseVersion(this.numbers, this.prerelease);

  final List<int> numbers;
  final List<String> prerelease;
  static final _pattern = RegExp(
    r'^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  static _ReleaseVersion? parse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    for (final part in prerelease) {
      if (int.tryParse(part) != null &&
          part.length > 1 &&
          part.startsWith('0')) {
        return null;
      }
    }
    return _ReleaseVersion(
      [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)],
      prerelease,
    );
  }

  @override
  int compareTo(_ReleaseVersion other) {
    for (var i = 0; i < numbers.length; i++) {
      final result = numbers[i].compareTo(other.numbers[i]);
      if (result != 0) return result;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty == other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final left = prerelease[i];
      final right = other.prerelease[i];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      final int result;
      if (leftNumber != null && rightNumber != null) {
        result = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null || rightNumber != null) {
        result = leftNumber != null ? -1 : 1;
      } else {
        result = left.compareTo(right);
      }
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}
