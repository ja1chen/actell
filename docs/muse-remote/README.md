# Muse 远程工具

Muse 负责规划，Actell 通过独立远程执行环境调用手机工具。设备端在 [muse-gadget-actell-mods](https://github.com/ja1chen/muse-gadget-actell-mods) 维护。

## 连接与权限

在设置中开启 Muse Gadget 服务并选择“添加 Muse”，再在 Muse 上选择“连接 Actell”。App 使用自动创建的稳定 TLS 身份，通过局域网配对交付每设备独立凭据；收到已认证 hello 后确认完成。截图、应用列表与操控权限分别保存，用户可随时修改或移除设备。

服务保存开关选择，在解锁、前台且空闲时恢复。普通后台切换保留已建立监听和认证设备状态，未完成配对关闭；系统挂起仍可中断网络。首次安装默认关闭，不自动重开配对窗口或重放工作。

首次配对只适用于可信 Wi-Fi；TOFU 不能防御同 LAN 主动攻击。后续固定证书并使用客户端 HMAC。官方 Muse 账号和 Wi-Fi setup 凭据不参与此配对。

## 执行边界

远程调用不创建普通 Agent 会话。执行受设备权限、当前连接、后台资格、期限及互斥所有权约束。已允许的设备操作无需逐次提示，但不能绕过单次动作授权、会话隔离与未知结果不重放规则。关闭服务、撤权、锁屏和停止按现有生命周期撤销执行。

诊断不记录凭据、签名、请求正文、工具参数或截图。监听存在、HTTP 成功、配对完成、真实截图和触控分别验收。

## 开发入口

- [配对与身份](COMPANION-PAIRING.md)
- [同步协议](SLAN-1.md)
- [工具、图像及执行生命周期](REMOTE-TOOLS.md)
- [诊断](DIAGNOSTICS.md)
- [验证结论与边界](VALIDATION.md)
- [App 构建与测试](../../ios-app/README.md)

自动 TLS/Keychain 模拟器测试使用 `SIMULATOR_ADHOC_SIGN=1`；保留默认 target 的协议、权限和停止释放回归。合成对端通过不代表完整物理链路通过。

原始适配来源为 Actell `7429967c47eb0f763bb14b95d68350ef2dc27f5c`；许可证和依赖来源见 [THIRD_PARTY.md](../../THIRD_PARTY.md)。
