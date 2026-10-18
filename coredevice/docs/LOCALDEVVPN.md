# VPN 回环传输

主 App 默认使用外部 VPN 将本机数据包回注，供 App 连接本机开发者服务。App 不安装、启动或停止 VPN，也不包含 Network Extension。

在手机操控设置中配置接口及对端地址，默认分别为 `10.7.1.1` 和 `10.7.0.1`，须与外部 VPN 一致。连接要求匹配的 utun 接口和新鲜 Bonjour 服务发现结果；不猜测端口、不回退其他接口。切换路线关闭旧会话和媒体，并撤销旧授权；任务、连接准备或清理期间禁止切换。

两条路线复用同一 RemotePairing 身份和 CoreDevice 后端。VPN 成功建立不等于开发者认证成功；仍需 Developer Mode、匹配 DDI 和实际服务调用。

[LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) 可用于此传输；已有兼容验证也覆盖具备本机回环功能的代理/VPN App。接口地址可能不同，按实际配置选择。建立控制连接时使用 Wi-Fi；[蜂窝限制](https://github.com/jkcoxson/LocalDevVPN/issues/31)及连接后网络切换仍是单独兼容性边界。

前台实测已获得截图、实际按钮点击和媒体释放；长期后台、完整模型任务、拖动及蜂窝切换不由这些结果证明。
