# Findings

## LordVCAM 参考行为
- 公开仓库显示其客户端连接 `wss://<host>:8765`，USB 模式仍复用 TCP/WebSocket。
- 二进制视频头部为 20 字节：`type, seqnum, flags, width, height`，均为 little-endian；负载为 H.264/H.265 NAL 数据。
- 二进制音频头部至少包含 `type, sampleRate, channels`，负载为 float32 PCM。
- 典型注入点是 `mediaserverd` 的 `BWNodeOutput copyNextSampleBuffer`，另有 App delegate 级别的回退 hook。
- 视频接收端使用 VideoToolbox `VTDecompressionSession`，音频通过 ring buffer 提供给麦克风管线。

## 设计决定
- 本项目先实现 H.264，不先实现 H.265；H.264 在 Windows FFmpeg 和 iOS VideoToolbox 上兼容性最高。
- 保留 LordVCAM 的 20 字节小端头部，便于互操作；消息类型使用 ASCII 四字节常量 `fram`/`audi`。
- WebSocket 使用明文 `ws://`，默认只监听局域网；可在后续版本加入 TLS/认证。设备和电脑应处于可信网络。
- iOS 接收端断流时必须返回原始摄像头帧，避免直播 App 黑屏或崩溃。

## USB 说明
USB 不是 iOS tweak 自己“看到”的串口。电脑端需要 `usbmuxd`/`pymobiledevice3`/`iproxy` 一类端口转发工具，把电脑发送器端口映射到设备侧 `127.0.0.1:8765`；协议层不区分 LAN 和 USB。
