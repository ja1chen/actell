# 普通 Lockdown 诊断

只读 QueryType 仅证明网络服务可达。受信任会话使用显式选定的普通 Lockdown plist，通过固定目标转发执行 StartSession 与 TLS；不依赖 mDNS，也不自动查找系统记录、发送 Pair 或回退 RemotePairing。

记录必须包含原有 HostID、SystemBUID、证书与匹配私钥，不能生成替代 BUID。后端验证响应类型、SessionID 和 SSL 要求，校验目标证书，不采用跳过证书或签名检查的配置。

取消在同一会话请求 StopSession 并关闭；断线仅能确认本地撤销，不能报告远端已经确认停止。导入身份不持久化、不写入日志，临时内存的值复制不能承诺完全擦除。

回环测试覆盖分片、错误证书、握手前拒绝就绪和拒绝后不降级。它们不能证明真实手机会接受另一控制端的既有身份，也不能证明 CoreDevice 控制可用。
