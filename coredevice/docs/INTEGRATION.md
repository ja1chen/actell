# CoreDevice 传输与 App ABI

```text
Swift NativeDeveloperServices
  → Rust C ABI / 会话 runtime
  → 所选传输：USB NCM 网卡 + ESP32 受限转发 / VPN utun 接口 + 本机回注
  → iPhone RemotePairing / 认证后协商的 TCP listener
  → TLS / CDTunnel / RSD / CoreDevice
```

USB NCM 路线中，Swift 核对 `.2/24` 地址、网卡索引和类型；Rust 建连时复验并绑定接口及源地址。ESP32 只在 `.1:28767` 接收 `.2`，不回退默认路由，不提供任意地址代理。

VPN 路线绑定配置的 utun 接口和源地址，通过新鲜 Bonjour 发现连接本机服务，不使用 ESP32 转发协议。两条路线实现同一 `CoreDeviceConnector` 接口，共用后续认证和服务会话。

## USB NCM 转发协议

以下版本前缀是兼容已有客户端的字节标记，只用于协议说明。首行最多 96 字节。

| 命令 | 约束 |
| --- | --- |
| `NR1 OPEN generation index nonce` | 当前未过期 RemotePairing 候选；32 个小写十六进制字符 nonce；单会话 |
| `NR1 TUNNEL nonce port` | 仅同一会话、同一目标地址和认证后协商端口；最多第二条流 |
| `NR1 CANCEL nonce` | 撤销该会话的两条流 |
| `NL1 OPEN nonce` / `NL1 CANCEL nonce` | 独立普通 Lockdown 通道，固定目标 `.2:62078`，不能用于隧道转发 |

上游连接建立后回复对应 `OK` 行，随后透明转发。nonce 用于隔离连接，不替代手机开发者身份认证。只读诊断入口使用 `ND1` 标记；诊断发现、问候和 QueryType 成功均不授予截图或输入能力。

每条流每方向使用 2048 字节缓冲区，满时停止读取并由 TCP 窗口施加背压；双流应用缓冲合计 8192 字节，另计 lwIP 和任务栈。任一流失败、USB 换代、显式取消或整会话 60 秒无字节活动会撤销两条流。活动时钟由两条流共享，持续媒体不会因控制流空闲被单独关闭。

## ABI 所有权

[coredevice_backend.h](../swift/Sources/CCoreDeviceBackend/include/coredevice_backend.h) 使用整数句柄，不向 Swift 暴露 Rust 指针。启动参数在调用内复制；会话有独立线程/runtime；关闭幂等撤销句柄及全部任务。

最多两个进程会话；每个会话最多一个排队请求和一个未消费回复。Swift 拷走 payload 前不释放 reply credit。请求 ID 单调递增，已接受输入不重放；错误不包含原始凭据或报文。

`test_coredevice_chain.sh` 连接真实 Swift wrapper、Rust worker 和 C 转发到合成对端，覆盖问候、认证失败和取消。测试夹具仅允许回环地址，生产构建不启用该入口。此类测试不能证明成功认证或真实输入效果。
