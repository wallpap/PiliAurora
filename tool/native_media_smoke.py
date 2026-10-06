"""使用现有 libmpv 验证直载媒体的参数解析；不访问网络或安装依赖。"""

import argparse
import ctypes as c
import json
from pathlib import Path
import time
import wave


class Event(c.Structure):
    _fields_ = [
        ("event_id", c.c_int),
        ("error", c.c_int),
        ("reply_userdata", c.c_uint64),
        ("data", c.c_void_p),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument('--video', required=True, type=Path)
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    workspace = Path(__file__).resolve().parent.parent
    output = workspace / "build" / "native-playback-smoke"
    output.mkdir(parents=True, exist_ok=True)
    video = args.video.resolve(strict=True)
    audio = output / "generated-音频,;100%片段.wav"
    # 生成无账号数据的外部音轨，覆盖 Windows 路径与 UTF-8 转义。
    with wave.open(str(audio), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b"\0\0" * 8000 * 3)

    mpv = c.CDLL(str(library))
    mpv.mpv_create.restype = c.c_void_p
    mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    mpv.mpv_initialize.argtypes = [c.c_void_p]
    mpv.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    mpv.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    mpv.mpv_wait_event.restype = c.POINTER(Event)
    mpv.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_get_property_string.restype = c.c_void_p
    mpv.mpv_free.argtypes = [c.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError("mpv_create failed")

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    def property_value(name):
        pointer = mpv.mpv_get_property_string(handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode("utf-8")
        finally:
            mpv.mpv_free(pointer)

    def command(*values):
        argv = (c.c_char_p * (len(values) + 1))(
            *(value.encode("utf-8") for value in values), None
        )
        require(mpv.mpv_command(handle, argv) >= 0, f"{values[0]} failed")

    def load(uri, options=""):
        # 清空上一轮事件，避免误把旧 file-loaded 作为新媒体加载完成。
        while mpv.mpv_wait_event(handle, 0).contents.event_id:
            pass
        command("loadfile", str(uri), "replace", "-1", options)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            event = mpv.mpv_wait_event(handle, 0.1).contents
            if event.event_id == 7:  # MPV_EVENT_END_FILE
                end = c.cast(event.data, c.POINTER(c.c_int))
                if end[0] == 4:  # MPV_END_FILE_REASON_ERROR
                    raise RuntimeError(f"media load failed: mpv error {end[1]}")
            if event.event_id == 8:  # MPV_EVENT_FILE_LOADED
                return json.loads(property_value("track-list"))
        raise RuntimeError("file-loaded timeout")

    try:
        for key, value in {
            "config": "no", "vo": "null", "ao": "null", "hwdec": "no",
            "pause": "yes", "terminal": "no",
        }.items():
            require(mpv.mpv_set_option_string(handle, key.encode(), value.encode())
                    >= 0, f"option {key} failed")
        require(mpv.mpv_initialize(handle) >= 0, "mpv_initialize failed")
        options = f"audio-files-append=%{len(str(audio).encode('utf-8'))}%{audio}"
        tracks = load(video, options)
        require(any(t["type"] == "video" for t in tracks), "video missing")
        external = [t for t in tracks if t.get("external")]
        require(len(external) == 1 and external[0]["external-filename"] == str(audio)
                and external[0]["selected"], "external audio not selected")
        require(property_value("path") == str(video), "main URL was wrapped")
        # 与应用刷新路径一致，重用 file-local extras 并恢复起始时间。
        tracks = load(video, f"start=1.000,{options}")
        require(any(t.get("external") and t.get("selected") for t in tracks),
                "reload lost external audio")
        require(float(property_value("time-pos") or 0) >= 0.9,
                "reload did not restore position")
        tracks = load(video)
        require(not any(t.get("external") for t in tracks),
                "external audio leaked into next media")
        tracks = load(audio)
        require(all(t["type"] == "audio" for t in tracks),
                "audio-only unexpectedly opened video")
        print(json.dumps({
            "mpv": property_value("mpv-version"),
            "unicode_delimiter_audio_loaded": True,
            "reload_preserves_audio_and_start": True,
            "next_media_clears_external_audio": True,
            "audio_only": True,
        }))
    finally:
        mpv.mpv_terminate_destroy(handle)


if __name__ == "__main__":
    main()