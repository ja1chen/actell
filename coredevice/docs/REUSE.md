# 来源与复用边界

精确引用版本见 [SOURCES.json](SOURCES.json)，实际 vendored 文件与修改标记见 [Rust 来源清单](../rust/SOURCE_MANIFEST.json)。

- Device Hub 的固定补丁版 idevice 和 PNG validator 用于 Rust 后端，保留原 MIT 许可证、作者与来源。没有集成完整 Device Hub App、TCA UI 或预编译 XCFramework。
- pymobiledevice3 用作协议 schema 与行为参考；选择性转译遵循对应 GPL 来源。运行时不依赖 Python 服务。RemotePairing、Lockdown、媒体和输入的成功条件分别验证。
- idevice_pair、rPlayHub 仅作研究参考，没有据其依赖许可证推断整个项目许可，也没有复制许可证不明的实现。
- ESP32 的有界 I/O、plist 和 QueryType 从仓库已有 C 实现提取，来源标记保留。ESP-IDF、TinyUSB、lwIP、cJSON 的许可独立适用。
- 本仓库不包含 Apple 开发者镜像或私有 framework。外部 VPN 实现未复制进仓库。

原始 `Cargo.toml.upstream` 保留；构建清单只选取当前后端所需功能，未启用功能名不构成支持声明。全部许可入口见 [THIRD_PARTY.md](../../THIRD_PARTY.md)。
