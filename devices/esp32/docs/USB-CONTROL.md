# USB 输入协议


本地 USB 输入连接在任务之间复用。停止任务释放 HID，TCP 继续承担心跳和下一轮任务。线上 greeting 中的版本标记保持兼容，不作为功能名称。

协议不认证身份、不验签、不加密，没有跨连接的密码学防重放。能访问 USB 网络的其他程序也能发送命令。App 不读取 USB 密钥，设备不访问 NVS。模型 API key 与 USB 链路无关。

## 连接与格式

服务端仅绑定 `192.168.7.1:28766`。App 按本地 `192.168.7.2/24` 查找唯一符合链路条件的接口，并通过 `requiredInterface` 和 `requiredLocalEndpoint` 绑定；不回退到无线或无绑定连接。接口索引、地址与链路类型必须同时满足条件。

ASCII、LF 结尾，接收缓冲上限 256 字节、命令正文上限 128 字节。参数是无前导零的非负十进制整数，大小写与空格精确匹配。

```text
S -> C: PA3 READY 1
C -> S: 1 PING
S -> C: 1 executed
```

`READY 0` 为 NCM-only，`READY 1` 表示固件包含 HID。App 等待 greeting 最多 3 秒，再明确 PING 验证双向收发。能力自报不证明身份或实际输入效果。

| 命令 | 条件 | 回执 |
| --- | --- | --- |
| `id PING` | TCP 已连接 | `id executed` |
| `id TAP generation x y` | 当前输入代号、HID 就绪、750 ms 内有 PING、无另一输入/释放 | `id received` → `id executed`，或 `id cancelled` |
| `id DRAG generation x y tx ty duration` | 同上，duration 为 100…2000 ms | 同上 |
| `id STOP generation` | 当前输入代号、无另一释放 | HID 释放完成后 `id executed`；保留 TCP |

`id` 和 `generation` 为 1…4294967295；坐标为 0…65535，基于已旋转到显示方向的图像。图片 ID 不传给固件，也不是模型动作参数。USB 普通动作由用户开始任务时授权；固件无法验证屏幕内容或人工授权。

## 输入代号与停止

每条新 TCP 连接的输入代号从 1 开始。App 为每轮任务取得一个连接内的输入会话；停止后旧会话不可用于新任务。该代号只由 App/固件管理，不暴露给模型，也不具有图片过期语义。

首个有效 `STOP generation` 立即撤销该代号，将固件代号递增并开始释放鼠标、键盘；固定其命令 ID 和 500 ms 释放期限。App 等 STOP 的 executed 后才使用下一代号。代号溢出关闭连接，不回绕。

释放期间继续读取 TCP：PING 正常回复，新的输入或 STOP 返回 cancelled（包括猜测下一代号的命令），不能重启释放或覆盖首个 STOP。相同 ID/参数的待完成 STOP 不提前回复 received；释放后重复该 STOP 只返回已缓存 executed，不再次递增代号。

若 STOP 中断了正在执行的输入，确认 HID 已释放后，先返回该输入的 cancelled，再返回 STOP 的 executed。中断的动作可能已经部分执行，cancelled **不代表从未产生输入**。没有启动的旧代号/忙碌/缺心跳/无 HID 命令则直接 cancelled。

```text
C -> S: 2 DRAG 1 100 200 300 400 1000
S -> C: 2 received
C -> S: 3 STOP 1
S -> C: 2 cancelled
S -> C: 3 executed
C -> S: 4 PING
S -> C: 4 executed
C -> S: 5 TAP 2 100 200
S -> C: 5 received
S -> C: 5 executed
```

## 回执、取消与幂等

- received 只表示接受了输入；executed 表示最终释放报告的 USB transfer completion 已到达。不能据此证明 iOS 界面已改变，Agent 仍需取得 ACK 后到达的新帧。
- 输入可以直接 cancelled，或 received 后 cancelled；不能先 executed 后 received。STOP 只有最终 executed/cancelled，PING 只有 executed。
- 命令 ID 在整条 TCP 连接内递增，不随任务结束复位。32 条缓存跨任务保留，相同 ID/参数返回已有阶段；同 ID 不同参数、已逐出 ID、尚未完成回执将被覆盖等情况关闭连接。generation 也参与参数比较。
- App 不自动重发输入。单条请求取消仅结束调用方等待，保留其回执槽以消费迟到 ACK；输入取消还会触发本轮 STOP。缺失 ACK 的真实超时仍关闭连接，避免将结果未知误报为成功。
- STOP 占用预留请求槽，重复停止共享一次释放任务；旧任务的清理回调不能停止下一代输入。

## 连接关闭边界

任务结束/取消、采集丢失、锁屏等 App 事件撤销任务输入并释放 HID，成功后保留 TCP。只有用户明确断开或真实通信/协议/释放故障关闭连接。App 单独持有每 200 ms 一次的 PING 循环，任务桥只检查健康，不重复发送心跳。

固件仍在 USB 总线失效/换代、socket EOF/错误、非法行或命令、回执冲突/缓存失效、100 ms 发送期限耗尽、60 秒未收到新命令时关闭。活动输入期间 PING 超过 750 ms 或动作超过 2500 ms，也释放并关闭；STOP 释放超过 500 ms 不返回成功。App 普通命令 ACK 等待 1 秒、DRAG 3 秒；无法确认 STOP 时关闭 TCP 并提示核对设备。

不支持自动重连、旧动作恢复、多客户端控制、发现或任意二进制 payload。本机 TCP 回归直接编译生产解析、socket 状态机和幂等代码，仅替换平台/USB 层；它不等于真实 USB 总线与 iPhone 控制验证。
