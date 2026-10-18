# ESP32 固件

ESP32-S3 通过原生 USB Device 提供 NCM 网络，承担受限服务发现和字节转发。配对身份、认证、CoreDevice 请求、媒体处理与 Agent 在 iPhone App 内运行；固件不保存长期配对私钥。

## 目录

| 路径 | 用途 |
| --- | --- |
| `firmware/` | 唯一 ESP-IDF 工程及应用入口 |
| `configs/` | 公共默认值和各构建配置 |
| `shared/usb/` | USB 描述符、NCM 网络、可选 HID 与输入协议 |
| `shared/ncm/` | 服务发现、诊断、受限转发及服务入口 |
| `shared/protocol/` | 转发诊断使用的有界 I/O、plist、Lockdown QueryType |
| `tests/` | USB、NCM 和基础协议的宿主机回归 |
| `tools/` | 构建、协议测试与产物检查 |
| `licenses/` | 第三方许可和来源清单 |

## 构建配置

三个配置复用同一工程和共享源码，不复制固件实现。

| 配置 | USB 接口 | 服务 |
| --- | --- | --- |
| `ncm`（默认） | NCM | 诊断、开发者服务转发、输入连接健康与停止协议；无物理 HID |
| `hid` | NCM + HID | 同上，增加 USB 鼠标/键盘报告；需要系统辅助触控配置 |
| `diagnostic` | NCM | 诊断与受限转发；不启动输入协议监听 |

使用已安装的 ESP-IDF 5.5.5。按需设置 `IDF_PATH`、`IDF_TOOLS_PATH`；有多个 Python 环境时显式设置 `IDF_PYTHON_ENV_PATH`。TinyUSB 依赖由 `firmware/main/idf_component.yml` 和 `firmware/dependencies.lock` 固定，首次构建需要下载组件。

以下命令从仓库根目录运行：

```sh
bash devices/esp32/tools/build.sh ncm
bash devices/esp32/tools/build.sh hid
bash devices/esp32/tools/build.sh diagnostic
```

产物分别位于 `.build/esp32-ncm/`、`.build/esp32-hid/`、`.build/esp32-diagnostic/`。根目录 `tools/build_firmware.sh` 提供相同入口。脚本只构建，不烧录；配置使用 16 MiB Flash，使用前核对目标容量与分区。

## 网络与边界

- 固件地址为 `192.168.7.1/24`，App 绑定手机 NCM 接口 `192.168.7.2/24`。不使用默认网关，不回退 Wi-Fi、蜂窝或 VPN。
- `28766` 为 [USB 输入协议](docs/USB-CONTROL.md)；`28767` 为诊断与受限开发者服务转发，协议见 [转发说明](../../coredevice/docs/INTEGRATION.md)。
- 无 DHCP 服务、IP forwarding、Wi-Fi 或蓝牙链路。诊断成功不代表已认证或可控制屏幕。
- USB 入口没有 App 身份认证。同一手机上可访问该接口的其他程序可能占用通道；真实开发者身份仍由后端认证。

## 验证

```sh
CC=clang bash devices/esp32/tools/test_protocol.sh
CC=clang bash devices/esp32/tools/test_lockdown_probe.sh
CC=clang bash devices/esp32/tools/test_usb.sh
CC=clang bash devices/esp32/tools/test_ncm.sh
bash devices/esp32/tools/with_idf.sh python devices/esp32/tools/verify_builds.py
```

最后一条命令检查三种构建的实际 ELF 描述符、接口、端点、HID 配置和链接组件。宿主机测试使用回环网络，不发送真实 USB 输入。硬件条件见 [硬件说明](docs/HARDWARE.md)，已知兼容性边界见 [CoreDevice 兼容性](../../coredevice/docs/COMPATIBILITY.md)。
