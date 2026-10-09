#!/usr/bin/env python3
"""Exercise the exact production Dart setSize method with a fake method channel."""
from pathlib import Path
import subprocess

HEADER=r"""
import 'dart:async';
class FakeChannel {
  final calls=<Map<String,String>>[];
  final replies=<Completer<void>>[];
  Future<void> invokeMethod<T>(String method,Map<String,String> arguments) {
    calls.add(arguments);final reply=Completer<void>();replies.add(reply);return reply.future;
  }
}
class FakePlayer {int get handle=>1;}
class FixtureController {
  final player=FakePlayer();
  int? width=640,height=360;
  bool _sizeReady=true;
  Future<void>? _pendingSize;
  int _sizeRevision=0;
  final _channel=FakeChannel();
"""
MAIN=r"""
}
Future<void> main() async {
  final c=FixtureController();
  final first=c.setSize(width:960,height:540);
  c._channel.replies.last.completeError(StateError('simulated render failure after native resize'));
  try {await first;} catch (_) {}
  final recovery=c.setSize(width:640,height:360);
  if(c._channel.calls.length!=2) {
    print('FAIL old-size recovery was incorrectly skipped by a restored cache');
    return Future.error(StateError('Recovery did not reach native rendering'));
  }
  c._channel.replies.last.complete();await recovery;
  print('PASS old-size recovery reaches native rendering after failed resize');
  final pending=c.setSize(width:1280,height:720);
  final repeated=c.setSize(width:1280,height:720);
  if(!identical(pending,repeated)) throw StateError('Same pending size was acknowledged prematurely');
  c._channel.replies.last.complete();await pending;
  print('PASS repeated size awaits the same first-frame acknowledgement');
}
"""

def main():
    root=Path(__file__).resolve().parents[2]
    source=(root/'third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart').read_text(encoding='utf-8')
    start=source.index('  Future<void>? setSize(')
    opening=source.index('}) {',start)+3
    end=opening+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    build=root/'build/windows-playback-diagnosis'
    fixture=build/'resize_ack_probe.dart'
    fixture.write_text(HEADER+source[start:end]+MAIN,encoding='utf-8')
    raise SystemExit(subprocess.run(['dart.bat',str(fixture)],shell=True).returncode)

if __name__=='__main__':main()
