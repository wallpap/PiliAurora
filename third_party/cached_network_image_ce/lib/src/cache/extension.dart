extension FnvHashExt on String {
  /// FNV-1a 64bit hash algorithm optimized for Dart Strings
  int get fnvHash {
    var hash = 0xcbf29ce484222325;

    var i = 0;
    while (i < length) {
      final codeUnit = codeUnitAt(i++);
      hash ^= codeUnit >> 8;
      hash *= 0x100000001b3;
      hash ^= codeUnit & 0xFF;
      hash *= 0x100000001b3;
    }

    return hash;
  }

  String get fnvHashStr => fnvHash.toRadixString(16);

  String get fileExtension {
    int slash = -1;
    int dot = -1;
    int qMarkNSharp = length;

    loop:
    for (int i = qMarkNSharp - 1; i >= 0; i--) {
      switch (codeUnitAt(i)) {
        case 0x2F: // '/'
          slash = i;
          break loop;
        case 0x2E: // '.'
          if (dot == -1) dot = i;
          break;
        case 0x23: // '#'
        case 0x3F: // '?'
          qMarkNSharp = i;
          if (dot > qMarkNSharp) dot = -1;
          break;
      }
    }

    if (slash != -1 && dot > slash + 1 && dot + 1 < qMarkNSharp) {
      return substring(dot, qMarkNSharp);
    }
    return '.file';
  }
}
