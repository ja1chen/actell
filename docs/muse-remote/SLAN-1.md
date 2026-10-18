# Simple LAN 配对共同接口 SLAN/1

2026-10-16 基线；2026-10-17 补全发现字段 host，并按用户决定在配对完成时默认开放三项权限。统一实施契约。替代此前AMBP/1 BLE及AMLP/1 QR方案。

## 体验与安全边界

手机点“添加Muse”打开120秒窗口 → Muse点“连接Actell”，用现有mDNS发现及HTTPS客户端申请 → 手机显示申请，用户点“允许” → 自动交付凭据、Muse保存并确认，之后自动重连。没有扫码、配对码、ESP HTTPS server、新BLE或额外用户确认轮次。

本版接受首次TOFU的可信局域网假设：不防同LAN主动中间人，手机允许确认的是收到的申请，不是密码学验证的实体身份。不得宣传首次配对抗MITM。后续严格固定手机DER证书pin与逐客户端HMAC，不因同名服务或新mDNS TXT自动换pin。仅在自己的可信Wi-Fi配对。

## 手机服务开关

iPhone设置提供“允许Muse连接”开关，推荐默认关闭。用户开启才启动现有LAN listener供已配对设备连接；“添加Muse”是独立按钮，只在开关已开启且listener实际运行时开放120秒新配对。仅进入添加页面不自动开服务。关闭开关立即停listener、断连接、取消所有pending申请并撤销pending_ack未完成key，保留已完成配对记录与权限；再次开启可供已配对设备重连，不自动重新开放新配对窗口。UI显示实际“已停止/正在启动/运行中/受系统限制或失败”，不能把开关开启当iOS后台常驻保证。服务关闭/撤销与hello激活共用状态锁，不能在关闭后激活未完成client。

## 角色、发现与TLS

Actell/iPhone始终是HTTPS服务端，Muse始终是客户端；复用 `_actell-muse._tcp` 和现有listener。手机仅添加窗口内广播新增TXT `pair=1`（其余TXT包括identity保持既有含义），关闭窗口删除pair；TXT只提示可申请，不是授权。一个窗口最多1个待定申请；Muse用户点连接后，只有一个合法且开放`pair=1`的候选时自动发送申请，不在ESP32显示服务名列表或要求再次选择手机；由iPhone上允许/拒绝申请完成选择与授权。发现多个开放窗口时不随机选、不逐个尝试、不同时向多端发申请，提示只在目标iPhone保留“添加Muse”窗口后重试。Bonjour实例名是服务标签，不保证等于手机设备名，也不代表身份。

Bonjour TXT 必须包含 `host`，值为现有手机证书的稳定 DNS SAN 名称，与 `claim.host` 完全一致；不重新生成证书。`host` 为≤253字节、纯ASCII小写DNS `.local` 名称，仅是TLS身份名，不要求它本身可解析。Muse使用Bonjour SRV目标对应的RFC1918地址和SRV端口建立TCP连接，使用TXT `host`作为TLS证书校验名及SNI；SRV主机名可以与证书名不同。不得把TXT host作为必需的DNS解析目标，不得用SRV主机名替代host校验证书。新配对缺少、重复或非法host时拒绝该候选；仅发现此类候选时明确提示“Actell版本不兼容，请更新手机App”，不得关闭hostname/SAN检查绕过。混合候选中仍只按合法候选计数；恰有一个时可自动发起，多个时按上述歧义规则停止。

首次配对将选定TXT host与握手取得的DER pin暂存在RAM并绑定request_id；claim.host、port及certificate_sha256必须分别等于暂存host、选定SRV端口及暂存pin，不允许领取响应替换身份。已配对后始终使用已保存host和pin；新Bonjour广播仅提供网络位置，不自动覆盖保存的host或pin。重连候选须匹配保存的host、identity指纹及端口；SRV主机名或IP变化不改变身份，重新发现同一身份的新RFC1918地址即可重连。

Muse尚未配对且用户刚点连接时，允许为唯一合法同LAN候选做一次受限TOFU：TLS握手取得叶证书，标准库检查P-256、服务器用途、有效期、DNS SAN匹配候选稳定`.local` host，并仅将这一张自签leaf作为本次候选anchor；记录SHA256(原始DER)为暂存pin。不对其它连接启用TrustAll；首次候选可接受自签这一点必须隔离在新配对分支。请求/领取均只在同一暂存pin的连接上进行，不允许中途换证书、HTTP降级、redirect或复用任意公共CA身份。mDNS identity不是pin来源；SAN host仍是TOFU的一部分，首次被欺骗风险如上。

首版沿用IPv4 LAN路径：候选和实际连接地址须RFC1918，走Wi-Fi LAN，拒绝公网/loopback/组播/IPv6/代理转发，不开穿透。动态IP通过Bonjour SRV地址重新发现，保存的TLS host与证书pin必须不变。现有Muse时间不足会启动SNTP并拒绝RPC，保持时间/证书检查；无有效时间显示“时间未同步”，不承诺离线冷启动或iOS后台常驻。

## 通用约束

两新增端点均POST，`Content-Type: application/json`，响应 `Cache-Control: no-store`；无cookie、cache、redirect、压缩或chunked body。配对请求≤512字节，领取响应≤4096字节；严格UTF-8 JSON，拒绝重复/未知键、BOM和非法类型。UUID为小写36字符；名称1..64 UTF-8字节无控制符；base64url无padding，解码再编码相同。

Muse每次新申请生成request_id(UUIDv4)与claim_token(CSPRNG32字节、base64url43字符)，在RAM保存；token只进Authorization header，不进URL/mDNS/日志。claim_token与正式secret不同。暂存手机host/port/DER pin与该request_id绑定，不允许换server继续领取。App/板卡重启丢失待定上下文时直接重新配对，不设计跨断电续接。

1个pending；Muse最多每2秒轮询，网络重试2→4→8秒，上限8秒；请求超时10秒。手机每窗口最多3次不同申请，之后提示重开窗口；无效token限速且不清除别人的pending。相同request_id/同token/同body是幂等重试；同ID不同token或body返回409，不覆盖旧申请。手机仅保存token的SHA256用于恒时校验；批准前只存RAM，不创建正式client key。

## 1. 申请 POST /v1/pair/request

Header：`Authorization: Bearer <claim_token>`。

Body恰为：
```json
{"v":1,"request_id":"11111111-1111-4111-8111-111111111111","device_name":"Desk Muse"}
```

手机窗口开启且无冲突时保存不可变request_id、token hash、原始body hash、名称；回复202：
```json
{"v":1,"request_id":"11111111-1111-4111-8111-111111111111","state":"pending","retry_after_s":2}
```

手机仅显示申请设备名称和允许/拒绝操作，不显示申请编号或额外配对说明；完成页仅显示已配对和名称。名称不是身份验证或领取凭据。相同请求重试仍只返回pending；已批准后的request重试返回state=`approved`，不在此端点交付正式secret。已完成/拒绝/过期请求返回410；新request不得复用旧ID。

## 2. 领取 POST /v1/pair/claim

仍使用同claim_token header；body恰为 `{"v":1,"request_id":"..."}`。即使轮询/重试也必须鉴权，不能凭名字或request_id领取。

未批准回复202，与pending响应同字段。手机拒绝回复403 `rejected`并清待定数据；窗口结束且仍未批准回复410 `expired`。

手机允许时，先生成新的client_id(UUIDv4)和正式secret(CSPRNG32字节)，复用现有自动TLS证书。将client key持久保存为`pending_ack`、scopes=[]，仅允许下述authenticated hello，不能普通RPC；保存成功才允许领取。响应200恰为：
```json
{"v":1,"request_id":"...","state":"approved","client_id":"...","secret":"<base64url32bytes>","host":"actell-<existing-id>.local","port":8765,"certificate_sha256":"<64 lowercase hex DER SHA256>","claim_remaining_s":300}
```

host≤253字节，纯ASCII小写DNS `.local`，port为1..65535整数。certificate_sha256必须等于Muse已暂存TLS leaf的DER hash；Muse保留握手所得公开DER/转PEM供现有客户端，不需领取另一个证书。手机证书/host若变了，当前配对失败，不能让响应重写暂存pin。claim重复始终返回同client_id/secret/host/pin，仅claim_remaining_s减少；不再生成密钥、不延长期限。手机不在响应或日志回显claim_token。

Muse验证响应后一次性持久保存host、port、DER/PEM、DER pin、client_id及正式secret，标`pending_ack`；写失败显示失败，不发送ACK，不开放任何业务。不得每次轮询写NVS。

## 3. ACK：复用现有 /v1/rpc 的 authenticated companion.hello

不新增ACK传输或密码协议。Muse保存成功后，用正式secret按现有ACTELL1 HMAC发送现有RPC envelope（v/client_id/request_id/op/params），op=`companion.hello`，params恰为 `{"device_name":"Desk Muse","protocol":1}`。HTTP时间、nonce、签名、JSON规则沿用既有实现。不要用claim_token签名。

手机验证HMAC成功、client pending_ack且领取期限未过后，原子标identityConfirmed/active，并一次性将scopes默认设为[screenshot,list_apps,control]；返回现有RPC成功result，保留既有state/scopes语义，并增加精确字段 `pairing_state:"active"`。新配对成功返回state=`authorized`及三项scopes。用户之后可分别关闭权限；全部关闭时state仍为`pending_authorization`，不代表配对失效。Muse仅在收到authenticated TLS链路上的成功result且pairing_state=active后标本端active并显示成功。

丢ACK请求/响应：Muse用同一正式client/secret重试hello，正常每次用新的RPC request_id/nonce/时间（不能重放旧nonce），手机已active时幂等回复pairing_state=active，不重复创建client。第一次ACK成功后，手机删除claim_token记录，claim返回410；正式hello仍可重试，不需要再领取。新配对激活时默认授予三项权限，之后由Actell已有权限页分别管理；已active的hello重试或重连必须保留用户调整后的权限，不能重新开启。未完成ACK的pending_ack仍为scopes=[]，不能调用业务。control不蕴含其它权限，已配对且control权限开放的Muse调用免逐次确认；仍受设备权限、有效任务、执行期限、截图时效、停止/锁屏及不重放规则约束。此策略由Actell本地决定，RPC不能请求扩大权限。

## 简单期限与失败处理

- 120秒添加窗口只控制新申请/尚未允许的请求；手机已允许的client有独立300秒领取及ACK期限，自批准时单调计时，不因轮询延长。
- 在状态锁内串行批准、ACK、撤销和到期。ACK在期限前获准进入持久active写即可完成；deadline不能把已经完成/正在提交的ACK反向撤销。到期先获锁的pending_ack先删live key，随后拒绝hello。
- 300秒无成功ACK：手机撤销未完成key和claim记录；Muse旧key被拒绝时保留本地pending记录，提示连接未被接受并暂停后台重试；不自动删除、不偷偷更换pin、不无限重试。由用户检查手机端状态后手动重连或明确移除。若手机已active但ACK响应一直丢失，Muse可保留pending提示并继续用户触发的同凭据hello；不要求复杂两阶段提交或双方同时落盘。
- 手机重启：启动时直接撤销所有未active的pending_ack，关闭添加窗口；不尝试恢复领取token。Muse重启：本地pending_ack在自动连接开启时可用已存正式凭据重试hello；成功则active，被拒则保留记录及重连入口并暂停后台重试。手机已active/Muse材料丢失的孤立记录需要用户明确处理，不按名称自动覆盖，也不自动撤销手机端记录。
- 用户取消/删除：手机按其明确取消/移除操作撤销相应key并fence在途调用；Muse的Cancel只停止当前传输并保留已保存材料，只有明确选择Forget pairing才删除本地材料。网络、认证、存储读取失败均不等同于用户删除。重配新request_id/client_id/claim_token/secret，旧ID不复活。单端短暂不一致允许失败重配，不宣称跨设备原子提交。
- 统一错误JSON恰为 `{"v":1,"error":"code"}`：400 invalid_request，401 unauthorized（含错token），403 rejected，409 conflict/busy，410 expired，429 rate_limited，503 storage_failed/time_unavailable。错误或timeout不能显示成功；不泄漏secret/QR旧材料/证书私钥。

## 最小验收与交付边界

双方按同一contract hash实现，至少验证：正常允许→持久保存→hello成功且默认三项scope（已active重连保留用户修改）；拒绝/到期；错token与同ID改body；领取重复不换secret；NVS/Keychain失败不显示成功；丢ACK可同凭据新nonce hello重试；手机重启/300秒撤销后旧key拒绝；换IP保留pin、换证书拒绝；官方Muse功能不受影响。

契约不替代真实联调；实现、构建与真机验收记录由两端工程分别维护。首次TOFU风险是用户接受的明确简化，不得悄悄扩成QR/PAKE/新BLE/ESP临时server或复杂恢复协议。
