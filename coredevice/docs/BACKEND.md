# 开发者服务后端

Swift 管理 App 生命周期、接口选择、身份存储和媒体解码；Rust 承担认证、TLS、用户态网络、服务发现和请求。固件仅转发字节，不运行 Rust/Python、不持有长期身份私钥。

## 会话建立

1. 读取与目标绑定的 RemotePairing 身份，按选定传输绑定接口。
2. 使用新鲜服务发现结果进行 Pair Verify，校验对端标识和签名。
3. 认证后创建 TCP listener，建立 TLS-PSK / CDTunnel，校验协商 IPv6、MTU 和 RSD 端口。
4. 在用户态网络中连接 RSD，保留控制流，核对设备标识与已认证身份一致。
5. 检查 Developer Mode 和 Personalized DDI，再按授权调用截图、媒体和输入服务。

失败不隐式新建身份、降级认证或重放输入。普通 Lockdown 身份与 RemotePairing 身份类型独立，不能互换。

## 截图与输入

生产截图路径从 DisplayService 视频获得画面，通过 HEVC 解码、内容矩形校验和 JPEG 编码返回 App。独立 CoreDevice PNG 请求保留在后端，其格式校验不等于视频路径成功。帧新鲜度与几何规则见 [视频说明](VIDEO-GEOMETRY.md)。

触控依赖活动媒体会话。归一化坐标范围为 0…65535；发送成功只证明报告写入，实际 UI 效果须独立观察。媒体、单张截图和输入分别检查权限。未知结果保留明确状态，已发送动作不自动重试；后续操作仍需独立授权。

正常媒体释放按协商的 RemoteSSRC 定向停止，并核对远端会话列表；不使用全局停止。取消或断线撤销自有传输和任务，若无法完成远端确认则保留未知结果。详见 [停止与释放](../../docs/CONTROL-SESSION-TEARDOWN.md)。

## 资源与能力边界

转发及 ABI 有队列限额和背压，不能据此宣称整个协议栈内存有界：用户态 TCP 内部通道、RemoteXPC 聚合/递归解析及完整截图回复仍需单独评估。系统暂停、锁屏、后台资格到期与断线可能中断会话。

实际兼容性与未验证项见 [COMPATIBILITY.md](COMPATIBILITY.md)。构建和测试入口见 [后端 README](../README.md)。
