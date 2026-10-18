# CoreDevice 后端

这是运行在 iPhone App 内的开发者服务后端。VPN 回环和 ESP32 NCM 共用配对身份、认证、媒体及输入实现；硬件转发只是其中一种传输方式。

| 路径 | 用途 |
| --- | --- |
| `swift/` | `CoreDeviceBackend` Swift 包、接口选择、身份存储和 `CCoreDeviceBackend` C ABI 调用层 |
| `rust/` | `coredevice-backend` 静态库，承担配对验证、TLS、用户态网络、RSD、媒体与输入；含固定版本依赖和来源清单 |
| `docs/` | 使用条件、协议、来源和兼容性边界 |

主 App 默认使用 [VPN 回环](docs/LOCALDEVVPN.md)，也支持 [ESP32 固件](../devices/esp32/README.md)。先完成[系统配对](docs/PAIRING.md)并准备匹配的开发者镜像。后端只检查镜像，不下载、个性化或挂载。

## 连接方式与命名

NCM 是 [USB CDC Network Control Model](https://www.usb.org/document-library/network-control-model-devices-specification-v10-and-errata-and-adopters-agreement)，用于通过 USB 传输网络数据，不是 ESP32 专有技术，也不泛指局域网。VPN 回环通过虚拟 IP 接口回注数据包，不使用 USB NCM；具体说明见 [LocalDevVPN 的实现](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift)。

共用模块、C ABI、媒体与输入桥接使用 CoreDevice 命名；NCM 仅用于 USB 路线的接口选择、诊断和转发，VPN 用于虚拟接口及回环发现。配对身份由两条路线共享，连接和动作授权仍按会话隔离。持久化路线值与线上协议标识保持兼容。

## 构建与测试

从仓库根目录执行，Rust 工具链需支持 edition 2024，并安装 `aarch64-apple-ios` 和 `aarch64-apple-ios-sim` target。脚本从 PATH 或标准 Cargo 安装目录查找工具链，可用 `COREDEVICE_RUST_TOOLCHAIN` 指定。依赖锁定；缓存完整时设置 `COREDEVICE_CARGO_OFFLINE=1`。

```sh
bash tools/build_coredevice_rust.sh device
bash tools/build_coredevice_rust.sh simulator
bash tools/test_coredevice_rust.sh
bash tools/test_coredevice_swift.sh
bash tools/test_coredevice_chain.sh
```

主 App 的 Xcode 构建阶段自动生成对应平台的 Rust 静态库。测试包含合成身份、内存对端和回环转发，不能代替真实手机验收。

[后端职责](docs/BACKEND.md) · [转发与 ABI](docs/INTEGRATION.md) · [视频与帧完整性](docs/VIDEO-GEOMETRY.md) · [兼容性结论](docs/COMPATIBILITY.md) · [来源与复用](docs/REUSE.md)
