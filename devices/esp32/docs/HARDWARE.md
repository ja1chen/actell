# USB 硬件条件

当前固件面向 ESP32-S3 原生 USB Device：iPhone 是 USB Host，ESP32 是 USB Device。GPIO19 为 D−，GPIO20 为 D+。板载 USB 转 UART 的调试口不能代替原生 USB 数据口。

使用前核对板级原理图、Flash 容量、数据线及 USB-C 角色和供电设计。固件默认 16 MiB Flash、USB bus-powered 描述符；软件配置与描述符不能证明板级供电或信号完整性。

已得到的通用结论：

- CC 电阻和供电控制决定 USB-C 初始角色。启用软件 Host 或由调试口供电，不会自动改变 CC 角色。
- OTG 焊盘可能只旁路电源二极管；不能根据名称认定其控制数据角色。空载电压、亮灯或烧录成功不能证明限流、防倒灌及负载供电满足要求。
- 双电源同时接入前须核对回灌路径；当前 Device 拓扑可由手机单独供电，仍需按具体板卡确认。
- 原生 USB OTG 与 USB Serial/JTAG 共用内部 PHY，固件使用原生 USB 后需为调试保留独立串口路径。
- 成功枚举只证明 USB 链路；NCM 网络、开发者认证、截图、触控与停止释放须分别验证。

参考：[Espressif USB-C 硬件指南](https://docs.espressif.com/projects/esp-iot-solution/zh_CN/latest/usb/usb_overview/usb_typec_hardware_guide.html)、[USB PHY 配置](https://docs.espressif.com/projects/esp-usb/en/latest/esp32s3/usb_device.html#external-phy-configuration)。
