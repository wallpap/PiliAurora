# 分片音轨回退样片

两个文件均为 FFmpeg 生成的 30 秒合成素材，不含用户媒体。视频为 64×64、30FPS AV1 测试图，音频为 48kHz 双声道 AAC 静音；约 5 秒一个分片，包含全局 sidx。总大小约 145KiB。

```powershell
ffmpeg -f lavfi -i testsrc2=size=64x64:rate=30 -t 30 -an -c:v libsvtav1 -preset 11 -crf 45 -g 150 -movflags +dash+global_sidx -frag_duration 5000000 -f mp4 backward-seek-av1.m4s
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 30 -c:a aac -b:a 32k -movflags +dash+global_sidx -frag_duration 5000000 -f mp4 backward-seek-aac.m4s
```

生成环境为 FFmpeg 9.0.2、SVT-AV1 4.2.0。测试不要求重新生成或安装 FFmpeg。`../native_backward_seek.py` 从 16 秒加载后回退到 8.133 秒，检查落点、音频位置、原生解析错误与时间戳重置。20261105 libmpv 包在此输入失败，20261104 包通过。

## 直接 libavformat 最小复现

`../ffmpeg_fragment_seek.c` 只使用这个 16,756 字节的 AAC 文件：打开文件、seek 到 16 秒、立即回退到 8.133 秒，再读取 100 个包。无需 `avformat_find_stream_info`、解码器、mpv、视频、播放等待或网络。`--control` 省去首次前跳，作为同一库的通过对照。

在 Linux/WSL 的 FFmpeg 源码目录编译；`<repo>` 为本仓库绝对路径：

```sh
./configure --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network --disable-x86asm --disable-avfilter --disable-avdevice --disable-swscale --disable-swresample --enable-demuxer=mov --enable-protocol=file --enable-decoder=aac --enable-parser=aac --enable-static --disable-shared
make -j8 libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a
cc -I. -O2 -Wall -Wextra -Werror <repo>/tool/probes/playback/ffmpeg_fragment_seek.c libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a -lm -lpthread -o fragment-seek
./fragment-seek <repo>/tool/probes/playback/fixtures/backward-seek-aac.m4s
./fragment-seek <repo>/tool/probes/playback/fixtures/backward-seek-aac.m4s --control
```

源码级对照确认 FFmpeg `cac8deb2f9192705cbab4c8486d46be912dc127d` 在 `libavformat/mov.c` 的 `mov_read_trun` 中把 `index_entry_pos < sc->current_sample` 改成 `<=`，使该输入跨越尚未读取的中间分片时跳过新插入的 235 个包。错误输出为：

```text
FAIL packet=89 expected=10.026667 actual=15.040000 gap=5.013333 pos=9311
```

同一 `baa68e68b` 源码基线，分别使用该提交前后的 `mov.c`：前者通过、后者失败；只恢复样本游标的 `<` 比较通过，只撤销该提交的 `tts_index` 调整仍失败。最终无插桩版本的提交前、提交后、单行撤销各运行三轮，加上各自的 `--control` 对照共 18 次，结果一致。该单行撤销用于确认因果；项目继续固定已验收的标准包，未将实验补丁用于生产。
