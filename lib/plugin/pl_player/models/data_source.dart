import 'package:pili_aurora/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
    Iterable<String> videoCandidates = const [],
    Iterable<String> audioCandidates = const [],
  }) : videoCandidates = _withPrimary(videoSource, videoCandidates),
       audioCandidates = audioSource == null || audioSource.isEmpty
           ? const []
           : _withPrimary(audioSource, audioCandidates);

  final List<String> videoCandidates;
  final List<String> audioCandidates;
  int _candidateIndex = 0;
  int get candidateIndex => _candidateIndex;
  int _videoCandidateIndex = 0;
  int _audioCandidateIndex = 0;

  String get currentVideoSource => videoCandidates[_videoCandidateIndex];

  String? get currentAudioSource =>
      audioCandidates.isEmpty ? null : audioCandidates[_audioCandidateIndex];

  bool advanceCandidate({bool audioOnly = false}) {
    // 错误事件未指明失败的音视频轨道，完整播放需要逐一尝试地址组合。
    if (_audioCandidateIndex + 1 < audioCandidates.length) {
      _audioCandidateIndex++;
    } else if ((!audioOnly || audioCandidates.isEmpty) &&
        _videoCandidateIndex + 1 < videoCandidates.length) {
      _videoCandidateIndex++;
      _audioCandidateIndex = 0;
    } else {
      return false;
    }
    _candidateIndex++;
    return true;
  }

  static List<String> _withPrimary(
    String primary,
    Iterable<String> candidates,
  ) {
    final result = <String>[primary];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && !result.contains(candidate)) {
        result.add(candidate);
      }
    }
    return result;
  }
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}
