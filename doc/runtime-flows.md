# 运行流程图

## 应用启动

`main.dart` 调用 `bootstrapApplication()`。Windows 的 Cookie 同步会读取 WebView 环境，因此该环境要先于 `Request.setCookie()` 初始化。

```mermaid
sequenceDiagram
    participant OS as Android / Windows
    participant Boot as app/bootstrap.dart
    participant Local as 路径与本地存储
    participant Platform as 平台初始化
    participant Net as Request / Cookie
    participant App as Catcher2 / PiliAuroraApp

    OS->>Boot: main() → bootstrapApplication()
    Boot->>Boot: 初始化 Flutter binding 与 MediaKit
    Boot->>Local: 初始化应用支持目录
    Boot->>Local: 初始化 GStorage
    alt GStorage 初始化失败
        Local-->>Boot: 抛出错误
        Boot->>Boot: 记录错误并退出
    else 初始化成功
        Boot->>Boot: 设置 UI 缩放并初始化日志
        par 准备本地资源
            Boot->>Local: 下载目录
        and 准备其他本地资源
            Boot->>Local: 临时目录、缓存、字体
        end
        Boot->>Boot: lazy 注册 AccountService、DownloadService
        Boot->>Net: 安装全局 HTTP overrides
        Boot->>Platform: 初始化平台服务
        Note over Platform: Windows 创建 WebView 环境；Android 准备方向与服务定位
        Boot->>Net: 创建 Request、同步 Cookie 与历史状态
        Boot->>Platform: 初始化系统 UI 或桌面窗口
        Boot->>Boot: 按设置读取动态颜色
        Boot->>App: 安装异常处理并创建根 Widget
    end
    App->>App: 创建主题、GetMaterialApp 与路由表
```

`GStorage` 初始化失败时，应用记录错误后退出。下载路径、临时目录、缓存和字体并行准备，`AccountService` 与 `DownloadService` 通过 `lazyPut` 延迟创建。实现见 [`bootstrap.dart`](../lib/app/bootstrap.dart)、[`platform_setup.dart`](../lib/app/platform_setup.dart) 和 [`app.dart`](../lib/app/app.dart)。

## HTTP 请求

业务 API 使用 `Request` 创建的 Dio 客户端。HTTP/2 开启时配置 HTTP/1.1 fallback；重试、诊断和压缩响应转换由请求层处理。

```mermaid
sequenceDiagram
    participant Caller as 页面 / Service
    participant Api as 业务 API 模块
    participant Dio as Request / Dio
    participant Int as Retry / 诊断拦截器
    participant Adapter as HTTP/2 或 HTTP/1.1 adapter
    participant Remote as Bilibili / 第三方服务

    Caller->>Api: 请求业务数据
    Api->>Dio: get / post / download
    Dio->>Int: 请求与响应经过拦截器
    Int->>Adapter: 发送请求
    Adapter->>Remote: HTTP 请求
    Remote-->>Adapter: HTTP 响应
    Adapter-->>Int: 响应或传输错误
    Int-->>Dio: 诊断、必要的传输重试
    Dio-->>Api: 转换后的响应
    Api-->>Caller: Success / Failure 或下载结果
```

`Request.get()` 和 `Request.post()` 会把 `DioException` 转成含错误消息的 `Response`，调用层仍需检查业务响应。重试条件见 [`retry_interceptor.dart`](../lib/http/retry_interceptor.dart)。

`_CustomHttpOverrides` 在调试模式或 `Pref.badCertificateCallback` 开启时接受无效证书，此时 TLS 证书校验会降低。

## 播放器切源与网络恢复

### 切源时序

`setDataSource()` 将加载任务交给 `PlaybackLoadQueue`。队列按序执行，并用代次使旧任务停止后续副作用。已发出的原生操作不会被队列中断；操作返回后会检查代次并丢弃旧结果。

```mermaid
sequenceDiagram
    participant Page as 视频页 / 直播页
    participant C as PlPlayerController
    participant Q as PlaybackLoadQueue
    participant P as media_kit Player
    participant Native as mpv / 平台输出

    Page->>C: setDataSource(source, autoplay, seekTo)
    C->>Q: run(operation)
    Q->>Q: 分配新代次并串行等待
    Q->>C: 执行 operation(isCurrent)
    C->>C: 暂停旧播放、更新媒体元数据
    alt 首次创建播放器
        C->>P: Player.create()
        C->>Native: 创建 VideoController 与输出
        Native-->>C: 输出初始化完成
    end
    C->>C: 检查代次与页面生命周期
    C->>P: 设置解码选项并构造媒体源
    C->>Native: open(media, play: false)
    Native-->>C: open 完成
    C->>C: 再次检查代次，更新时长、位置与 loaded 状态
    alt autoplay 且请求仍有效
        C->>P: 应用倍速 / 画面适配并开始播放
    else 已过期或不自动播放
        C->>C: 不启动旧请求的后续副作用
    end
```

只有当前代次的加载失败会更新错误状态并写入诊断。实现见 [`controller.dart`](../lib/plugin/pl_player/controller.dart) 和 [`playback_load_queue.dart`](../lib/plugin/pl_player/utils/playback_load_queue.dart)。

### 网络错误恢复

```mermaid
flowchart TD
    Error[收到播放器网络错误]
    Local{本地文件源?}
    Live{直播源?}
    Throttle[按错误类型限频]
    Wait[等待 3 秒]
    Current{播放器仍存活且媒体源未变化?}
    NeedBuffer{是否要求等缓冲耗尽?}
    Exhausted{可播放缓冲已耗尽?}
    Defer{仍在消耗缓冲且仍处于 buffering?}
    Retry[重载媒体，按设置尝试下一个 CDN]
    Stop[结束本轮恢复]

    Error --> Local
    Local -->|是| Stop
    Local -->|否| Live
    Live -->|是：跳过缓冲耗尽检查| Wait
    Live -->|否| Throttle --> Wait
    Wait --> Current
    Current -->|否| Stop
    Current -->|是| NeedBuffer
    NeedBuffer -->|否| Retry
    NeedBuffer -->|是| Exhausted
    Exhausted -->|是| Retry
    Exhausted -->|否| Defer
    Defer -->|是：重新安排检查| Wait
    Defer -->|否| Stop
```

只有可恢复的网络错误才进入该链；HTTP 403 不按 CDN 故障重试。`playback_network_recovery.dart` 识别错误，`PlPlayerController` 管理限频、缓冲检查和媒体重载。GPU、MediaCodec 与 Surface 恢复需在目标设备验证。

## 下载

### 任务时序

下载记录由 `DownloadRepository` 持久化，`DownloadService` 维护待下载队列和当前任务，`DownloadManager` 负责单路媒体流。DASH 视频与音频可并发传输；任务只有在所需媒体流都完成后才标记完成。恢复时根据已有文件长度发送 Range 请求；暂停会保留已写入字节，删除则由服务移除对应目录。

```mermaid
sequenceDiagram
    participant UI as 下载页 / 视频页
    participant S as DownloadService
    participant R as DownloadRepository
    participant RPC as DmGrpc
    participant API as DownloadHttp / VideoHttp
    participant V as 视频 DownloadManager
    participant A as 音频 DownloadManager
    participant Disk as 下载目录

    UI->>S: 创建 UGC / PGC 下载项
    S->>R: 创建目录并保存 entry.json
    S->>S: 加入待下载队列，选择当前任务
    S->>RPC: 获取弹幕分段
    RPC-->>S: 返回分段数据
    S->>Disk: 写入弹幕文件
    S->>API: 获取播放地址与媒体信息
    API-->>S: Type1 分段或 DASH 视频 / 音频
    S->>R: 保存 index.json
    par 写入媒体文件
        S->>V: 使用 Range 请求恢复或开始视频
        V->>Disk: 流式写入并回报进度
    and
        S->>A: DASH 存在音轨时并发下载
        A->>Disk: 流式写入音频
    end
    V-->>S: 完成 / 暂停 / 错误
    A-->>S: 完成 / 暂停 / 错误
    alt 所需媒体流全部完成
        S->>R: 保存完成记录
        S->>S: 移出队列并启动下一项
    else 暂停或传输错误
        S->>R: 保存可恢复的进度和状态
    end
```

### 任务状态

```mermaid
flowchart TD
    Request[创建下载请求]
    Duplicate{CID 已在完成列表或队列?}
    Skip[忽略重复请求]
    Persist[创建目录并保存记录]
    Queue[加入待下载队列]
    Active[成为当前下载项]
    Danmaku[下载弹幕并写入文件]
    Url[请求播放地址]
    Address{播放地址获取成功?}
    Index[保存媒体索引]
    Transfer[传输视频；DASH 时并发传输音频]
    Result[收到媒体流结果回调]
    Error{本次传输失败或暂停?}
    Both{所需媒体流均已完成?}
    Other{是否还有必要的媒体流运行中?}
    Wait[等待下一路媒体流结果]
    Complete[保存完成状态并启动下一项]
    Failed[进入失败 / 暂停状态；由当前阶段处理]
    Cancel{取消方式}
    Keep[保留已写入字节并保存暂停状态]
    Remove[删除任务时移除目录]

    Request --> Duplicate
    Duplicate -->|是| Skip
    Duplicate -->|否| Persist --> Queue --> Active --> Danmaku
    Danmaku -->|成功| Url --> Address
    Address -->|否| Failed
    Address -->|是| Index --> Transfer --> Result --> Error
    Danmaku -->|失败| Failed
    Error -->|是| Failed
    Error -->|否| Both
    Both -->|是| Complete
    Both -->|否| Other
    Other -->|是| Wait --> Result
    Other -->|否| Failed
    Transfer -.-> Cancel
    Cancel -->|暂停| Keep
    Cancel -->|删除| Remove
```

实现与测试：[`download_service.dart`](../lib/services/download/download_service.dart)、[`download_repository.dart`](../lib/services/download/download_repository.dart)、[`download_manager.dart`](../lib/services/download/download_manager.dart)；`test/services/download/`。

## 直播消息与弹幕

视频播放和聊天使用独立连接。页面从 `LiveHttp` 获取播放地址；聊天另取连接信息，再由 WebSocket 接收弹幕和互动消息。

```mermaid
sequenceDiagram
    participant Page as LiveRoomController
    participant API as LiveHttp
    participant WS as LiveMessageStream
    participant Socket as WebSocket 服务端
    participant Decoder as LivePacketDecoder isolate
    participant UI as 聊天缓冲与弹幕渲染

    Page->>API: 获取直播间信息与播放地址
    API-->>Page: 播放流
    Page->>Page: setDataSource(isLive: true)
    Page->>API: 首次启动聊天时获取 token 与 host 列表
    API-->>Page: 连接信息
    Page->>WS: 创建消息流并注册监听器
    WS->>Socket: 依次尝试 WebSocket host
    Socket-->>WS: 连接就绪
    WS->>Socket: 发送认证包 operation 7
    Socket-->>WS: 认证响应 operation 8
    WS->>WS: 启动周期心跳 operation 2
    loop 每个 WebSocket 数据帧
        Socket-->>WS: 二进制数据
        WS->>Decoder: TransferableTypedData
        Decoder->>Decoder: 拆包、解压嵌套包并解析 JSON
        Decoder-->>WS: 保序的消息列表
        WS->>Page: 调用业务监听器
        Page->>UI: 更新缓冲、未读数、弹幕或互动消息
    end
    Page->>WS: 页面关闭
    WS->>Decoder: 关闭 worker 并结束在途任务
    WS->>Socket: 取消订阅并关闭连接
```

每条连接复用一个解析 worker。关闭或 worker 异常会结束在途任务；损坏的数据包会被跳过。实现见 [`live.dart`](../lib/services/live_stream/live.dart)、[`live_packet_decoder.dart`](../lib/services/live_stream/live_packet_decoder.dart) 和 [`live_packet.dart`](../lib/services/live_stream/live_packet.dart)，测试位于 `test/services/live_stream/`。
