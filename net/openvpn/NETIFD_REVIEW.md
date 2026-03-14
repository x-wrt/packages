# OpenVPN/netifd 集成审核记录

审核日期：2026-10-26。审核基线：`80fd57a8c`，OpenVPN `2.6.19-4`。
当前实现的流程和字段契约见 [集成规格](SYSTEM_DESIGN_SPEC.md)。

下述正文保留 `80fd57a8c` 的审核证据，源码行号对应该历史基线。
后续修复与当前行为见本节状态及集成规格。P1 表示会破坏特定受支持配置的
连接、路由或进程管理，建议优先修复；P2 表示功能/契约缺口，P3 为维护项。
下述问题既包括此前就有的缺陷，也包括上游同步后仍未解决的缺陷，不能全部归因于
最新一次同步。

## 当前修复状态（2.7.7-5）

- **F01–F06：已修复并加入回归**。提交 P2P peer；route 仅按列表/兼容字符串
  生成；过滤 daemon；发布失败回滚并返回非零；固定 up-restart，处理 down、
  ipchange、WAN 依赖和地址/网关更新，独立记录路由所有权及清理重试；
  文件参数保留到原生 OpenVPN 校验，不再静默删除目录、命令、输出路径和特殊值。
- **F08：按维护者确认的设计关闭，并统一包装行为**。固定 script-security 3 是
  netifd 集成要求，用于执行托管及自定义脚本。导入/UCI 的较低值被覆盖，不再作为
  禁止自定义回调的策略，也不再导致部分 UCI 包装被跳过。
- **F10：已修复并加入回归**。单次编译按进程级 cd 展开 include，循环/深度、
  缺失引用、无效语法和目录给出结构化错误；配置和凭据在私有 staging 完成后才发布、
  启动，准备失败保留上次快照。新增 config_version 支持文件修改后完整重载。
- **F11：已修复**。无条件依赖 iproute2 的 ip，并不再使用 metric 查询过滤语法；
  新增 flock 依赖保证跨实例路由状态序列化。
- **F13：部分修复**。永久 BusyBox/jshn/netifd shell 和真实 ubus/netifd C 生命周期
  回归已纳入 tests；设备 TLS/DCO 验收仍未完成。
- **F14：已修复**。删除 teardown 状态下的冗余 link-down 通知。
- **F07/F09/F12/F15：部分待处理**。显式 ULA 路由、teardown 晚到 down
  和安全回调竞争已修复；逐路由 metric、外部网关语义、redirect 启用时的同前缀
  来源歧义及全局用户脚本返回码仍待处理。

本轮同步了晚到 down 和安全回调处理：stopping 后 down 保留用户通知，但不修改
网络状态和阶段；安全处理器持有实例共享锁，拿锁后检查 stopping 和 UUID，
避免等待 prepare 后继续执行旧代安全回调。cleanup/prepare 的独占锁等待运行中
安全处理器完成。用户处理器及其后台子进程不继承实例锁，父进程仍持锁等待
同步处理器返回。非法接口名也在安全事件入口拒绝。

redirect 过滤改为跨版本组合判断：OpenVPN 2.7 使用其导出的
`route_redirect_gateway_ipv4/ipv6`；2.6 使用 provider 添加 redirect 时设置的
`NETIFD_REDIRECT_GATEWAY` 回退标记。只有 `DEFAULTROUTE=1` 且 redirect 生效时
才过滤分拆前缀，未启用 redirect 时显式 ULA 路由仍交给 netifd。redirect 启用时，
显式配置与自动生成使用同一前缀仍无法精确区分，保留为 F07 限制。
关闭默认路由时，在配置加载前添加优先 pull-filter，屏蔽服务器推送的
redirect-gateway/redirect-private，并屏蔽导入的 redirect-private，避免 IPv6
自动分拆路由绕过 netifd 默认路由开关。普通路由与用户原有 pull-filter 保留。

兼容同步验证：2.6.19-8 消费树的 218 项检查通过，包含旧版 ubus/netifd C
状态机；2.7.7-5 消费树的新版 shell API/jshn 下 217 项隔离检查通过。
覆盖 2.7 原生 redirect 标志、2.6 managed 回退标记、显式 ULA、安全回调并发
及后台子进程锁继承，并确认关闭默认路由时不追加 redirect、原生各协议族的 0
值优先于兼容标记。优先过滤规则与显式路由保留已加入回归；另用两版源码
中的原生 pull-filter 函数核对推送屏蔽及普通 IPv6 路由/DNS 保留。两边运行脚本、
配套文件及回归代码保持一致。

本轮按维护者选定的集成优化项补充：

- WAN 更新先比较路径；无变化跳过，仅网关变化刷新端点路由，源地址/设备变化
  renew，并合并同轮重复请求。共享冲突及双栈部分失败恢复原路由和路径后回退 renew。
- `user/group/chroot` 统一屏蔽，选项名进入日志和状态；不拒绝整个导入配置。
- 通过 netifd set_data 发布回调阶段、角色、端点、MTU、错误和代次；不接管用户
  management，也不把 tunnel-up 宣称为 TLS 已连接。
- 实例锁与共享路由锁分离，慢 ubus 查询不占全局锁；UUID 拒绝旧代回调。
- 接受两条数据面内部路由例外：provider 自管的服务器端点保护路由，以及 DCO
  服务端维护的逐客户端 `iroute`/网段外地址分流路由。netifd 继续负责普通地址、
  默认路由、策略/业务路由和 DNS。
- MTU 明确遵循 network device.mtu > interface.mtu > tun_mtu，重复 up 仍保持此顺序。
  IPv6 metric 0 按内核实际值 1024 记录，避免重复 up 或清理时失配。

按维护者确认的原则，netifd 接管默认路由、metric 和路由表，原生 def1 转换为
netifd 默认路由属于集成设计，F07 不再将这一转换本身列为缺陷。F07 剩余问题是
逐路由 metric、外部网关归属，以及用户显式前缀被默认路由过滤集合误删。

审核上游工作区 `f8622c0bad` 的未提交 git diff 后，采用 auth_gen_token 旧启用开关
兼容、缺失主配置提前失败及 DNS6 接收；参考文件/目录/命令/输出路径的分类意图，
最终统一交给原生 OpenVPN 在 cd 上下文校验；本轮再屏蔽不兼容的 chroot。上游将 tls_export_cert 当作
可不存在的输出文件不符合本版本源码，它实际上是输出目录。上游本身未被修改。

## 1. 优先修复的问题

### F01 · P1 · IPv4 P2P 地址缺少对端地址

位置：`files/usr/libexec/openvpn-hotplug:281`。

`up` 只提交 local 和 netmask，未把 `ifconfig_remote` 传给
`proto_add_ipv4_address` 的第四个 `ptp` 参数。原生 OpenVPN 在 net30/p2p 模式
导出的是 `ifconfig_remote`，此时这里退回 `/32`，却没有安装到对端的连接路由。

结果：经该对端配置默认路由或其他路由可能失败；接口仍可能被报告为 up。
产品服务端的 `topology=subnet` 不受这一特定遗漏影响，但第三方服务端可使用 P2P。

证据：隔离回调确认 ptp 参数为空；独立网络命名空间里的真实 TUN 测试中，
同一地址不设置 peer 时默认路由返回 `ENETUNREACH`，设置 peer 后成功。
内核用例运行在审核宿主的 Linux 6.6，目标设备内核仍需验证。

建议：按实际 topology/环境分别提交 subnet 地址和 P2P peer，并覆盖 net30、
p2p、subnet 的地址及默认路由测试。

### F02 · P1 · UCI route 列表生成额外的无效路由

位置：`files/usr/share/openvpn/openvpn.options` 的字符串表和列表表；
`files/lib/netifd/proto/openvpn.sh:63`、`:79`、`:95`。

`route` 同时注册并处理为 string 和 array。libubox 的 `json_get_var` 读取
数组时得到内部数组标识，不是数组元素；字符串生成阶段会把该标识作为一条路由，
随后列表阶段又生成正确路由。

结果：产生额外的非法/不可解析目标。OpenVPN `init_route_list()` 中任一路由
初始化失败会使整体返回 false，而 `do_init_route_list()` 只在整体成功时导出
`route_network_N` 等变量；因此可能连正确路由也无法交给当前回调应用。

证据：使用消费树原生 jshn 与 BusyBox ash，确认配置包含内部数组标识和正常
列表项；交叉核对了 UCI blob 转换与 OpenVPN 路由环境导出的条件。

建议：统一 route 的输入模型，先检查 JSON 类型，再决定生成单值或列表；
不能对同一数组同时运行普通字符串生成逻辑。

### F03 · P1 · 导入配置允许后台化，破坏 netifd 进程管理

位置：`files/usr/share/openvpn/config.awk:154`；
`files/lib/netifd/proto/openvpn.sh:410`。

托管过滤没有排除原生 `daemon`。消费 netifd 通过直接子进程 PID 监控
OpenVPN，而 OpenVPN 原生后台化会 fork 并退出原进程。

结果：netifd 可能进入 teardown/retry，但不能继续依靠原 PID 管理后台进程，
产生重复实例、运行文件被清理或接口状态不一致。

证据：过滤用例确认该指令保留；核对 netifd 的 `netifd_start_process`、
`proto_shell_task_finish` 和 OpenVPN 的 `possibly_become_daemon`。
测试未启动后台 OpenVPN 进程。

建议：托管模式拒绝或过滤后台化指令，并明确 PID/status/运行目录的所有权。

### F04 · P1 · 网络更新失败仍返回成功，端点路由未回滚

位置：`files/usr/libexec/openvpn-hotplug:366`、`:423`。

`proto_send_update` 失败只设置 `EVENT_ERRORS`，最终仍用 `HOTPLUG_RC` 退出。
默认用户处理器成功时，OpenVPN 得到的回调结果仍是成功。
此前创建的端点主机路由也没有走 `fail_up` 回滚；其清理信息尚未成功存入 ubus。

结果：OpenVPN 继续运行，但 netifd 可能没有地址、路由和 DNS，且端点路由可能
遗留。之后的 cleanup 不一定有足够数据删除它。

证据：隔离注入更新失败，确认回调退出 0；路由 stub 记录了添加，没有回滚删除。

建议：把必要的状态发布失败纳入失败路径，回滚本次创建的路由并返回非零，
同时保留明确错误日志。通知成功后的内核路由 failed 状态还要另做验收。

### F05 · P1 · 软重连和端点切换缺少路由生命周期管理

位置：`files/lib/netifd/proto/openvpn.sh:379`、`:418`；
`files/usr/libexec/openvpn-hotplug:269`、`:362`、`:408`。

固定 `persist-tun`，renew 仅发 SIGUSR1；默认没有 `up_restart`。原生 OpenVPN
在保留设备的软重连中可以不调用 `up/down`。`ipchange` 当前也只分发用户事件。
因此传输断开、重新连接或切换 remote，并不一定重新发布网络状态或保护新端点。

即使配置了 `up_restart`，当前也没有完整处理：down 不清理；新端点添加成功后，
同一地址族只有一个清理字段，可能覆盖旧端点的删除信息；新路径查询还可能受到
已存在 VPN 默认路由影响。未调用 `proto_add_host_dependency`，也没有对 WAN
路径变化建立 netifd 依赖。

结果：旧端点保护路由残留，新端点缺少保护或错误地经隧道选路；netifd 的 up
长期保留，不能独立作为客户端已连接的证据。

证据：核对 OpenVPN `do_open_tun/do_close_tun` 的 persist/up-restart 分支；
隔离确认 down 不发布状态、不删除路由；其余跨进程时序来自源码分析，未设备复现。

建议：定义断线期间的接口状态契约，以结构化易失状态记录所有已拥有的路由，
处理端点更换、WAN 依赖和清理幂等。不能只增加 `up_restart` 就认为问题解决；
也不能直接在 down 通知 link-down 而不考虑 netifd 会据此 teardown 当前进程。

### F06 · P1 · 文件检查错误地丢弃目录及特殊值

位置：`files/lib/netifd/proto/openvpn.sh:83`；
`files/usr/share/openvpn/openvpn.options` 的文件参数表。

大多数文件类字段统一要求 `-f`，但 `capath/client_config_dir/chroot/
tls_export_cert/tmp_dir` 是目录，`dh` 还允许原生特殊值 `none`。

结果：合法的目录和特殊值被静默省略；CCD、CA 目录、无 DH 参数配置等失效。

证据：隔离生成测试确认目录值和 `dh=none` 全部没有写入配置。
当前产品服务端已通过原生 adapter 放入 `dh none` 和 CCD 目录，规避了这部分问题；
不能据此认为通用 UCI provider 已支持它们。

建议：分别处理普通文件、目录、允许特殊值的字段及命令字符串，缺失输入应给出
字段级错误，不能统一静默跳过。

## 2. 其他功能与契约问题

### F07 · P2 · 路由转换丢失部分原生语义

位置：`files/usr/libexec/openvpn-hotplug:224`、`:298`、`:303`、`:339`。

- 没有读取 `route_metric_N/route_ipv6_metric_N`，原生逐路由优先级丢失。
- 所有协议路由关联 TUN/TAP；原生 `net_gateway` 等外部网关路由没有还原为
  对外部接口的路由，可能不可达或与原始分流意图不同。
- redirect 启用时仍用固定前缀集合识别默认路由，显式配置与自动生成使用相同
  前缀时无法精确区分。
- 原生 `def1` 被转换为 `/0`；它与 WAN、策略路由和 metric 的关系需要单独约定。

证据：隔离确认未启用 redirect 时显式 `fc00::/7` 会保留，启用 redirect 后
同前缀来源仍不可区分；逐路由 metric 未传递。外部网关及完整选路影响为源码
确认的语义缺口，需在目标网络验证。

建议：保留明确的 route 元数据和出口归属，区分自动 redirect 与用户显式路由，
覆盖普通路由、外部网关路由、DCO metric 及策略路由。

### F08 · P2 · script_security 与原生同名选项语义不一致

位置：`files/lib/netifd/proto/openvpn.sh:301`、`:334`、`:372`。

最终命令行固定 `script-security 3`。较低的 UCI 值只影响部分包装生成，
导入生命周期回调仍会被收集，原生安全回调也不因此整体禁止。

结果：不能把 UCI 的这个字段当作禁止用户脚本执行的可靠策略。

建议：明确托管回调所需的内部级别，另行定义并贯彻用户脚本许可策略；对不支持的
原生安全级别应拒绝或清晰说明限制。此项为静态审核，未执行认证绕过用例。

### F09 · P2 · 全局用户脚本的失败不传播

位置：`files/etc/hotplug.d/openvpn/01-user:6`、`:55`。

`/etc/openvpn.user` 的退出结果没有保留，随后选择/执行用户命令的逻辑会覆盖它。
安全分发器聚合的是整个 `01-user` 的结果，无法恢复其中被忽略的结果。

结果：该全局脚本不能被用作可靠的认证拒绝或失败门禁；扩展点之间的返回码契约
与外层“保留安全失败”的契约不一致。

建议：决定全局脚本是否仅通知。若允许它参与决策，必须传播失败并规定与后续
命令及 deferred 的组合方式；通知接口则应明确不承载安全决策。

### F10 · P2 · 配置导入与失败处理尚不完整

位置：`files/lib/netifd/proto/openvpn.sh:209`、`:221`、`:323`、`:354`、`:364`；
`files/usr/share/openvpn/config.awk:68`。

include 复制固定使用初始 `cd_dir`，没有按原生 `cd` 指令维护工作目录。
循环命中时仅跳过复制，未把循环明确转为输入错误；路径也没有统一规范化。
声明的主配置不存在时，没有立即失败，可能继续尝试用剩余 UCI 参数启动。
部分目录创建、配置和凭据写入也没有检查返回值。

结果：合法的切换目录配置可能导入失败；无效或部分写入的配置不能稳定地在 setup
阶段给出可识别错误。

证据：隔离确认 `cd` 后的合法相对 include 无法被复制；缺失主配置仍调用运行入口。
循环和 I/O 错误覆盖范围来自源码检查。

建议：约定完整支持或明确拒绝目录切换与循环；对必要输入和写入统一检查，使用
`proto_notify_error/proto_setup_failed` 提供结构化错误，并清理失败生成物。

### F11 · P2 · 运行依赖没有完整体现在包契约中

位置：`Makefile:39`；`files/usr/libexec/openvpn-hotplug:176`、`:205`、`:217`。

回调无条件使用 `ip`，且 metric 存在时用 `ip route show ... metric ...`。
包仅在 OpenVPN 的 IPROUTE2 编译开关打开时依赖 `ip`。
BusyBox 1.33.2 的 route list 参数不支持同样的 metric 过滤语法。

结果：精简固件可能缺少所需工具，或把查询语法失败当作不存在路由；添加遇到
已有路由后再次查询仍失败，最终拒绝上线。

当前审核目标选择了 `ip-full`，因此该目标的现有构建满足此需求。
这是包可移植性问题，不是当前目标已证明缺包。

建议：声明脚本真正需要的 ip 能力，或提供 BusyBox 兼容的查询与匹配实现。

### F12 · P2 · 默认安装调试 ucode 样例

位置：`Makefile:118`；`files/usr/share/openvpn/auth-user-pass-verify.uc:5`。

安装了多份只打印参数/完整环境的 `.uc` 样例，没有默认调用，也没有对应的
ucode 运行依赖。认证样例没有实现认证判定。

结果：被误选为生产回调时可能暴露认证环境或被误当作已实现的校验器。
该风险属于可选误用路径，不是默认回调链正在泄露信息的证据。

建议：移到明确的开发示例目录或不随生产包安装；示例不输出完整敏感环境，
明确标注其执行依赖及非生产用途。

### F13 · P2 · 缺少可持续运行的集成回归

位置：`test.sh`。

包内现有测试只检查 `openvpn --version` 的加密后端字符串，没有覆盖
netifd 配置转换、up/down、状态发布、路由所有权或迁移。
此前 106 项同步验证和本次隔离用例属于会话验证，并未作为永久回归纳入仓库。

建议：修复时加入可复用的 BusyBox/jshn/UCI 测试入口，覆盖 netifd 通知边界；
再增加真实 netifd/ubus、目标内核和 TLS/DCO 的集成测试。

## 3. 维护项

- **F14 · P3**：teardown 最后的 `proto_send_update` 会被消费 netifd 的 teardown
  状态拒绝。最终下线由 netifd 状态机完成；应删除冗余通知或明确处理这一状态，
  避免把脚本末尾返回值当作清理成功证明。
- **F15 · P3**：未安装的 `openvpn.uc` 与 shell 实现已分叉；示例配置仍使用
  `disabled` 等旧启停表达。它们不影响默认安装入口，但会误导维护和后续迁移。
- **迁移边界**：候选文件校验和原子替换已有实现，但没有与其他 network 写入方
  协调锁；network 替换和旧包归档是两步操作，掉电一致性未验证。
  当前没有据此确认已发生数据丢失，需在升级验收中覆盖并发修改及中断。

## 4. 已排除的误判

- `peerdns=0` 的效果由 netifd 核心应用，不能因回调仍收集 DNS 就判定无效。
- 新建 TUN/TAP 的 `up` 前已有路由环境初始化，不是所有路由都必须等到
  `route-up` 才能获取。
- 同端点重复 up 不会仅因未重新提交清理字段就丢失所有权：当前 netifd 的
  `interface_add_data` 合并字段。问题在跨端点覆盖和清理信息不可用的路径。
- 没有单独 procd init 不等于没有进程管理；这里由 netifd 监控 `proto_task`。
- `tls-crypt-v2-verify` 保留原生执行是必要安排，不应为了统一分发而强行包装。
- 迁移脚本的 `eval` 消费原生 UCI 规范化导出，不能等同于直接执行原始 UCI 文件。
- 普通 UCI 字段没有统一“最后覆盖导入文件”的契约；必须按生成顺序和原生
  指令语义判断。

## 5. 验证证据

本次交叉审核了 shell provider、AWK、hotplug、迁移、包安装、消费 netifd 的
shell/C 状态机、原生 OpenVPN 2.6.19，以及当前手动客户端和产品服务端的字段。

原始审核的行为验证（80fd57a8c）：

- BusyBox 1.33.2 ash/awk、消费树原生 jshn、隔离命令 stub：
  **19 项断言，确认 11 个行为观察**，对应配置序列化、目录参数、include、
  前台管理过滤、地址、路由、通知失败和 down/缺失配置处理。
- 独立网络命名空间真实 TUN：同一 P2P local `/32`，无 peer 时经对端添加
  默认路由返回 `-101/ENETUNREACH`，补充 peer 后返回 0。
- 未执行真实远端连接、认证绕过、设备部署、全固件构建或目标设备内核测试。
  本次没有运行后台 OpenVPN 进程，也没有修改宿主网络配置。

前轮修复验证（2.6.19-5）：

- 永久隔离回归启用 native 模式，**100 项检查通过**：真实 BusyBox ash/awk/flock、
  jshn/netifd shell API，包含发布失败、双栈回滚、共享路由所有权回滚、并发及清理重试。
- 消费树同版本原生 ubusd/netifd（dummy 系统后端）：确认 P2P peer、路由和 DNS
  进入 C 状态；普通 down 撤回状态并保留原 PID；renew 发 SIGUSR1；WAN 下线
  teardown 终止进程并清路由，恢复后启动新进程。OpenVPN/ip 是替身，未建立 VPN 会话。
- ShellCheck、shell 语法和 git diff 空白检查通过。
- 消费 OpenWrt 树执行 `make package/openvpn/compile V=s`，生成
  `openvpn-openssl_2.6.19-5_aarch64_cortex-a53.ipk`；核对安装脚本及依赖。
- 当前客户端/服务端消费字段已做源码兼容性核对；实际业务、TLS/DCO、多 WAN
  选路和目标设备内核仍需设备验收。

本轮集成优化验证（2.6.19-6）：

- 永久隔离回归 **190 项检查通过**，新增嵌套 cd/include、过滤 user/group/chroot、私有 staging、结构化失败、
  MTU 顺序、状态、旧代回调、WAN 路径比较、共享/双栈刷新回滚及重复 renew 合并。
- 真实 ubus/netifd C 回归额外验证 set_data 状态、MTU 来源和 config_version reload
  替换进程及 UUID，以及 WAN 更新触发 renew 的锁交接。系统后端仍为 dummy，OpenVPN/ip 为替身。
- BusyBox 语法、Python AST、ShellCheck（排除动态 API/外部环境的预期诊断）及
  git diff 空白检查通过。消费树 `make package/openvpn/compile V=s` 成功，生成
  `openvpn-openssl_2.6.19-6_aarch64_cortex-a53.ipk`，核对五个关键支持文件的字节、权限和包依赖。

仍待处理的是 F07 的路由转换语义、完整 fwmark/策略选路，以及 F09 的全局事件返回码。
F12/F15 属于生产安装与维护整理。TLS/DCO、动态 device MTU 来源及目标多 WAN
行为需要设备验收；本文不将隔离命令边界模拟等同于这些验收。
