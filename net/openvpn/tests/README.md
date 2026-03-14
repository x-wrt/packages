# OpenVPN/netifd 回归

在 Linux 构建主机上运行，需要 Python 3、bubblewrap、可用的非特权 user/network
namespace，以及与目标版本一致的原生 BusyBox。BusyBox 至少启用 ash、
`ASH_BASH_COMPAT`、awk、flock、grep、mktemp、date 和常见文件工具。OpenWrt 消费树应已有
netifd/libubox 解包源码及可执行的 `staging_dir/host/bin/jshn`。

```sh
python3 net/openvpn/tests/netifd.py \
  --openwrt /path/to/openwrt \
  --busybox /path/to/native/busybox
```

测试调用真实 provider、回调、AWK、netifd shell API 和 jshn；替换边界上的
`ip`、`ubus` 和 OpenVPN 进程，验证 UCI/JSON 转换、P2P/subnet 地址、配置过滤、
目录和特殊参数、状态发布失败、IPv4/IPv6 端点路由所有权、重连、IP 变化、
WAN 依赖、清理失败重试及 teardown；新增嵌套 cd/include、参数屏蔽、私有 staging、
结构化失败、旧代回调隔离、MTU 顺序、状态、WAN 路径比较、双栈/共享刷新恢复及
renew 合并。所有写入发生在临时目录和隔离命名空间。
晚到回调用例覆盖 stopping 后 down 的阶段保留、安全处理器与 cleanup 的锁交接，
以及安全回调等待 prepare 独占锁后重新检查 UUID。路由兼容用例确认
未启用 redirect 时显式 ULA 会保留；2.7 原生标志和 2.6 managed 回退标记均能
过滤 redirect 分拆前缀；各协议族的原生 0 值覆盖兼容标记。关闭默认路由时
provider 不追加 redirect 或兼容标记，重连回调保留。优先 pull-filter
屏蔽服务器推送的 redirect-gateway/redirect-private，覆盖导入的 accept 规则，
并确认导入的 redirect-private 被屏蔽、显式 IPv6 业务路由仍保留。安全处理器启动的后台
子进程不得继承实例锁。

文件参数用例检查目录、输出路径、命令和 `dh none` 等值被完整保留，实际有效性
交给 OpenVPN 在其工作目录中验证；测试不会把无效路径静默删除。
不支持的 user/group/chroot 会在编译快照时屏蔽，单独的选项序列化测试仍保留这些输入。

可选的真实 ubus/netifd C 状态机回归：

```sh
python3 net/openvpn/tests/netifd.py \
  --openwrt /path/to/openwrt \
  --busybox /path/to/native/busybox \
  --native-dir /path/to/native-builds
```

`native-builds` 需要下列原生 Linux 构建产物，版本与消费树一致：

- `ubus/ubusd`、`ubus/ubus`、`ubus/libubus.so`。
- `uci/uci`、`uci/libuci.so`。
- `netifd/netifd`，使用 `-DDUMMY_MODE=ON` 编译，保留真实 IPC 和 C 状态机，
  用 dummy 系统后端避免实际修改网络。

可用 CMake 在消费树解包源码之外分别构建 ubus、UCI 和 netifd，禁用可选 Lua
及 ubus examples。头文件及链接路径使用原生 host libubox/json-c 和上述 ubus/UCI
源码、构建目录；不要链接目标架构库。测试会将消费树 `staging_dir/host/lib` 及
这两个原生库目录加入隔离环境的 `LD_LIBRARY_PATH`。

该模式将 ubus stub 换成真实守护进程，验证 P2P 地址/路由/DNS 进入 netifd、普通
down 撤回网络状态而保留子进程、renew 的 SIGUSR1、WAN 下线触发 teardown、
WAN 恢复后重新启动，并验证 set_data 状态、netifd MTU 优先和 config_version 变更
reload 后替换进程及 UUID。OpenVPN 进程和 ip 命令仍为边界替身，回调由测试触发。

本轮在 BusyBox 1.33.2、libubox `2021-05-16-b14c4688`、ubus
`2021-06-30-4fc532c8`、UCI `2021-04-14-4b3db117` 和 netifd
`2021-10-30-8f82742c` 上验证，当前 native 模式共 218 项检查通过。
运行结束会打印检查数及 native 状态机验证结果。
实际 VPN 会话、目标设备内核、TLS/DCO、物理 WAN 断开/恢复和多 WAN 切换仍需
设备验收。

兼容同步验证（2026-10-26）：OpenVPN 2.6.19-8 消费树通过上述 218 项检查，
包编译通过，IPK 版本及 19 个安装配套文件的内容、权限核对通过。
OpenVPN 2.7.7-5 消费树使用 netifd
`2026.09.11~06d06c86`、libubox `2026.07.21~e7608b69` 的 shell API/jshn，
配合 BusyBox 1.33.2，217 项隔离检查通过。当前没有新版 netifd 的 native
测试环境，不能将旧版 native 验证视为新版 C 状态机验收。
2.7.7 消费树的 filogic 配置对应的 aarch64 GCC 14.4.0 staging 缺少 `libgcc_s.so.*`，
完整包编译仍受该工具链前置条件阻塞；安装宏此前已在临时目录核对内容及权限。
redirect 判定优先使用 2.7 原生标志，并以 provider 标记兼容 2.6；显式配置与
自动 redirect 使用相同前缀且 redirect 启用时，当前仍不能精确区分路由来源。
