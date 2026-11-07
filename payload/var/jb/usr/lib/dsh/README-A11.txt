dsh-iOS / iPhone X (A11) 兼容说明 —— +ios12（含 +ios2~+ios12 修订记录）
================================================

一句话结论
----------
`+ios2` 把内置 node 换成了 iPhone X 实测版 v22.12.0，JS 层已经完全正常：
`dsh --version`、`headless --dump-default-config`、五个内部模块、V8 优化编译
全部通过。但一输入 `dsh` 启动 web 仍 `bus error`。`+ios3` 修的就是这一步。


为什么 +ios2 的真 boot 会 SIGBUS
--------------------------------
dsh 进入真 boot 时会调用全局 `fetch` 拉模型列表 -> 加载 **Node 内置 undici**
-> 其 HTTP/1 解析器是 `llhttp` 的 **WebAssembly**，模块加载期就执行
`new WebAssembly.Module(...)`。

WASM 编译与 JS 优化编译是两条不同的路径。V8 默认把 WASM / 优化代码的编译
丢到**后台线程**，而 iOS 的 `pthread_jit_write_protect_np`（APRR / W^X）是
**按线程**生效的：主线程有可写权限，后台编译线程没有，一写可执行代码页
内核就发 SIGBUS。表现就是截图里的：

  - 轻量命令全 OK（不碰 WASM）
  - `dsh-doctor` 的「V8 JIT 通道畅通」也 OK（那只测 JS 循环，假绿灯）
  - web / headless 真 boot 零输出直接死，`zsh: bus error  dsh`

`--jitless` 单独用救不了：jitless 会把 WebAssembly 全局整个移除，内置
undici 在模块加载期就抛 `WebAssembly is not defined`。


+ios3 做了什么：设备端自动选档
------------------------------
不再猜哪个 flag 在你的机器上有效。首次启动 `dsh` 会跑 `smoke.js`——不联网，
但真触发「fetch -> 内置 undici -> llhttp WASM 编译 -> 一次 HTTP 往返」——
逐档试，选第一个不崩的档位，写入 `$DSH_HOME/.dsh-tier` 缓存，之后零开销。

  档位        说明
  native      无额外参数，性能最好（设备本来正常时）
  single      --single-threaded，编译收回主线程，保留 WASM 与全部功能
  balanced    + 禁并发编译 / WASM 编译单线程
  safe        + 禁并发 GC / 限优化层
  nowasm      --jitless + fetch-shim.cjs，**完全不生成可执行代码**

兜底档 `nowasm` 是原理级保险：
  - `--jitless` 让 V8 全程解释执行，不分配任何可执行内存；
  - `fetch-shim.cjs` 在 preload 阶段用 `node:http`/`node:https`（原生 C++
    llhttp，不用 WASM）接管 `fetch`/`Headers`/`Request`/`Response`/`FormData`，
    并用依赖树里自带的 `ws` 顶上 `WebSocket`；
  - 注入一个只满足模块加载的 WASM stub，让内置 undici 的模块图能建起来
    （真实请求已由 shim 接管，llhttp 永远不会被调用）。
  已在 x86 Linux 实测：`--version` 正常、web 真监听并输出带 token URL、
  headless 到 DeepSeek API 报 401（HTTPS 走通）、WASM 冒烟探针通过。

另外：真正 boot 的负载比探针重。若选定档位启动后仍被 SIGBUS/SEGV 杀死，
`dsh` 会**自动**降级到 `nowasm` 重试一次并把结果写回缓存。


dsh-doctor 的修正（截图里两个 FAIL 其实都是脚本误报）
------------------------------------------------------
  - `[FAIL] node 大小 ... 101297040 字节异常` + `[: Illegal number: ?`
    iOS 的 `stat -f %z` 被解释成「文件系统状态」输出一大段文本，混进 `?`
    才导致比较失败。文件其实是完整的 101,297,040 字节，**不用重传**。
    已改用 `wc -c`。
  - `[WARN] 无法读取 hw.memsize`
    iOS 不暴露这个 sysctl key，纯无害。已改成中性 INFO，不计数。
  - 删掉只测 JS 循环的假绿灯 JIT 判定，换成逐档 WASM 冒烟探测，
    web/headless 检测现在会捕获退出码并明确报 `SIGBUS(138)`。


怎么用
------
  dsh-doctor     # 强制重探，逐档打印 rc；全 OK 即可用
  dsh            # 首次会打印「已选定启动档位 [xxx]」，随后正常启动

手动指定 / 强制重探（写在 dsh.env 或命令行）：

  DSH_TIER=nowasm dsh        # 直接走零 JIT 档
  DSH_REPROBE=1 dsh          # 每次启动重新逐档探测
  DSH_TIER=nowasm dsh-doctor # 用指定档位跑完整自检

若 doctor 第 4 项（entitlement）失败：

  ldid -S/var/jb/usr/lib/dsh/ent.plist /var/jb/usr/lib/dsh/bin/node
  trustcache inject /var/jb/usr/lib/dsh/bin/node
  dsh-doctor

约束：A11/3GB 上 dsh 与 MC 不要同时运行；dsh.env 已把 V8 堆限到 384MB。
nowasm 档下 `dispatcher`（undici 专有 DNS pinning）选项会被忽略，web fetch
provider 的固定 IP 能力降级，其余功能不受影响。


+ios4：手机 Safari 打开工作台报 AbortSignal.any 的修复
-------------------------------------------------------
现象（+ios3 装上、doctor 全绿之后）
  终端里 `dsh` 正常起 web 并打印带 token 的 URL；但用**手机 Safari** 打开
  工作台、点「选择工作区目录」之类弹窗时，弹窗里出现红字：

    AbortSignal.any is not a function. (In
    'AbortSignal.any([token.abort.signal, callerSignal])',
    'AbortSignal.any' is undefined)

  而 iPhone 17 Pro Max 打开同一个工作台完全正常；换别人的 node / 别人的
  dsh 移植包，在这台 iPhone X 上还是一样报错。

根因：这一次不是终端，是浏览器
  括号措辞 `(In '...', '...' is undefined)` 是 JavaScriptCore(Safari/WebKit)
  独有的报错格式；后端 node 用的是 V8，V8 只会写 `TypeError: ... is not a
  function`。所以异常是**手机 Safari 里跑的 dsh 网页前端**抛出来的。

  `AbortSignal.any()` 是 Safari 17.4 / iOS 17.4 (2024-03) 才加入的 Web API。
  同一批还有 `Promise.withResolvers` / `Object.groupBy` / `Map.groupBy` /
  `Array.fromAsync`。iPhone X (A11) 硬件上限只能停在 iOS 16.7，WebKit 是
  Safari 16.6，这批 API 全部没有；iPhone 17 Pro Max (iOS 26) 全部都有。

  所以变量是**设备的 WebKit 版本**，不是 node、不是越狱、不是 deb。
  换后端包没用；iOS 上换 Chrome/Edge/Firefox 也没用 —— Apple 强制所有
  浏览器使用系统 WebKit。唯一解法是给前端补 polyfill。

  调用点在 `dsh-client-ui-workspace/lib/client.js` 等插件 client.js，是
  运行时**动态加载**的，不在 vite 的 index bundle 里，所以只 patch bundle
  不够，必须在页面入口的全局对象上补齐。

+ios4 做了什么
  - 新增 `assets/safari16-polyfill.js`：按 WHATWG / ECMAScript 规范实现
    上面 5 个 API，全部「特性检测 + 原生优先」。原生已有就一个字节都不改，
    因此 iPhone 17 / iOS 17.4+ 完全不受影响，重复加载也幂等。
  - `index.html` 的 `<head>` 内、所有 `<script type="module">` 之前插入一个
    普通 `<script src>`。普通 script 同步执行、module 默认 defer，所以垫片
    必然先于前端代码与动态 import 的插件生效。静态资源是目录遍历式 serve，
    新增文件可直接加载；主页面无 CSP，不会拦这个标签。
  - webserver 自己的 boot 脚本也用了 `Promise.withResolvers()`，但它排在
    垫片之后（实测 HTTP 渲染页：垫片 pos 36482 / module 36936 / boot 37877），
    所以不会在垫片生效前挂掉。

  验证（真实起 web 服务 + token 认证 + cookie 跟随）：
    渲染后页面含垫片引用、/assets/safari16-polyfill.js 返回 200 且内容正确、
    垫片先于 module；模拟 Safari 16（抹掉 5 个原生 API）后 5 个垫片语义、
    reason 传递、Set 迭代、幂等全部通过。

  另外顺手消掉了 nowasm 档那条无害但碍眼的
    Warning: disabling flag --expose_wasm due to conflicting flags
  （显式加 --no-expose-wasm；实测 smoke / --version / headless(401) /
   web 监听结果完全一致）。

已经装了 +ios3 的用户：不必重传 113MB deb
  把 dist/fix-safari16.sh 传到设备，在终端跑一次：

    sh fix-safari16.sh

  它直接在已安装目录补垫片并改 index.html，幂等、几秒完成，不重启 dsh、
  不重装。然后回 Safari 强制刷新页面（设置 → Safari → 清除历史记录与
  网站数据，或长按刷新键 → 无缓存刷新）即可。

  +ios4 只是把这个修复固化进包，方便以后全新安装自带。


================================================================================
+ios5：工作台弹窗报 "directoryPicker/list failed: Load failed" 的修复
================================================================================

现象（+ios4 修好 AbortSignal.any 之后）
  手机 Safari 打开工作台，「选择工作区目录」弹窗里出现红字：
      client api:
      directoryPicker/list failed:
      Load failed
  iPhone 17 Pro Max 上同一个工作台完全正常。

  注意：这次不是 Safari 版本问题，也不是 AbortSignal.any 了。
  "Load failed" 是 Safari 里 fetch() 对「连接被掐断、零响应」的标准报错，
  说明请求发到了 /var/jb 上的 dsh 后端，但后端没给任何响应就把 socket 关了。

根因（A/B 实测逐层隔离）
  dsh 前端的 directoryPicker/list 是 direct unary RPC，走
  dsh-client-connection 的 globalThis.fetch POST /api/directoryPicker/list。

    native 档（不加载 shim）      -> POST 200 正常
    nowasm 档 (+ios3/+ios4)      -> 连接被直接关闭，零响应
    仅 --require fetch-shim.cjs  -> 同样断连（与 jitless 无关）
    只注入 WASM stub / 只覆盖 fetch -> POST 200

  唯一变量：旧版 fetch-shim.cjs 在 preload 阶段顺手把原生
  Headers / Request / Response / FormData 四个全局覆盖成了半成品 Shim* 类。
  而 dsh 后端 Web 框架（dsh-api-session-controller、dsh-client-connection）
  正是用这些原生全局构造 HTTP 响应、解析 multipart 的 —— 处理 POST 时抛
  异常并被静默吞掉，连接随之断开。

  为什么「别人用正常」：只有 A11（iPhone X）因为 WASM/SIGBUS 会落到 nowasm
  档并加载这个 shim；能跑 native 档的设备（含 iPhone 17 Pro Max）根本不碰它。

+ios5 做了什么
  shim 改为「只覆盖 fetch / WebSocket」：
    - fetch 仍用 node:http / node:https 出站（不碰 llhttp WASM）
    - WebSocket 用依赖树里的 ws 包
    - WASM stub 依然保留，让内置 undici 在 --jitless 下能完成模块加载期
    - Headers / Request / Response / FormData 全部保留原生
  于是后端能正常构造响应，/api POST 恢复 200。

  实测（真实起 web 服务）：--version 正常、dump-default-config 正常、
  headless 出站 HTTPS 到 DeepSeek API 报 401（证明 fetch 出站正常）、
  /api/directoryPicker/list POST 200、WebSocket /api/remote.mux 101 握手
  并收到服务端协议帧、服务端异常 0 行、插件全激活、Safari 垫片仍注入。

已经装了 +ios3 / +ios4 的用户：不必重传 113MB deb
  把 dist/fix-api-load-failed.sh 传到设备，在终端跑一次：

    sh fix-api-load-failed.sh

  它只替换 /var/jb/usr/lib/dsh/fetch-shim.cjs 这一个 15KB 文件，
  自动备份成 .ios4.bak、做语法自检、可重复执行（幂等）。

  ！！！替换后必须重启 dsh：Ctrl+C 退出当前 dsh，再重新敲 dsh。
  shim 是 node 启动期由 --require 加载的，刷新网页不会重新加载它。

  然后回 Safari 刷新工作台，再点「选择工作区目录」即可。
  若还没修过浏览器垫片（仍报 AbortSignal.any），先跑一次 fix-safari16.sh，
  两个脚本互不冲突。

  +ios5 只是把这个修复固化进包，方便以后全新安装自带。
  dsh-doctor 新增第 13 项，会直接报「fetch-shim 是否为 +ios5 版」。


================================================================================
+ios6：发消息报 "DeepSeek Messages transport failed" 的修复
================================================================================

现象（+ios5 之后，doctor 全绿、目录能打开，但聊天发不出去）
    本轮运行失败  DeepSeek  TRANSPORT
    Messages transport failed
    已重试模型请求（5/5） · 8s
    失败原因：DeepSeek Messages transport failed

  不是网络、不是 API key、不是 WebKit。TRANSPORT 是 dsh 把「底层任意异常」
  兜底包装出来的类别，不是具体原因。

根因
  原生 Response.body 是幂等 getter（多次读取返回同一个 ReadableStream）。
  旧 shim 里 ShimResponse.body 第一次访问就置 _bodyUsed=true，第二次抛
      TypeError: Body is unusable
  而 dsh-llm-deepseek/lib/index.js 第 2259-2260 行连续读两次：
      if (response.body === null) throw new LlmError(... "EMPTY_RESPONSE");
      yield* translate(parseSse(response.body, activity), options.model);
  第二次抛的异常不是 LlmError、不是 TIMEOUT、不是 ABORTED，于是 generate()
  把它包成 "DeepSeek Messages transport failed" (TRANSPORT)。重试策略会
  重跑 5 次，每次都在同一处炸 —— 就是截图里的 5/5。

  为什么之前测不出来：沙盒里用假 key，/messages 直接返回 401，走
  !response.ok 分支的 response.text()，根本到不了这两行。只有配了有效 key、
  真正进入 SSE 流才触发。所以「headless 到 401」不等于「聊天能用」。

+ios6 做了什么
  - body getter 幂等：加 _bodyLocked，缓存同一个 ReadableStream，
    重复访问返回同一个对象（原生语义），null 也保持一致。
  - 补齐 formData()（dsh-client-connection/lib/client.node.js 的
    parseBinaryResponse 会用，委托给保留着的原生 Response 解析 multipart）
    与 bytes()（Node 22 的 Response.bytes）。
  - clone() 同步 _bodyLocked，保证克隆体的 body 也幂等。

验证
  - 决定性对照：真实 dsh headless 对本地 mock 的 DeepSeek Messages API 发消息。
      仅把 body getter 还原旧实现 -> rc=1, TRANSPORT, 连续 6 次连接被 reset
      +ios6 修复版               -> rc=0, 正常输出模型回复
  - 11 项兼容探针全通过：body 幂等 / SSE 完整链路(TextDecoderStream +
    EventSourceParserStream) / gzip SSE / json / text / formData / bytes /
    arrayBuffer / redirect:error / clone().body。
  - 原有通道无回归：--version、dump-config、headless 到 401、web 监听、
    /api/directoryPicker/list POST 200、WebSocket mux 101、Safari 垫片注入。

已经装了旧版的用户：不必重传 113MB deb
  把 dist/fix-transport.sh 传到设备，终端跑一次：

    sh fix-transport.sh

  只替换 /var/jb/usr/lib/dsh/fetch-shim.cjs 这一个约 17KB 文件，
  自动备份成 .ios5.bak、语法自检、可重复执行（幂等）。

  ！！！替换后必须重启 dsh：Ctrl+C 退出当前 dsh，再重新敲 dsh。
  shim 是 node 启动期 --require 加载的，刷新网页不会重新加载它。

  然后回 Safari 刷新工作台，重新发一条消息验证。
  dsh-doctor 新增第 14 项，会直接报「fetch-shim 是否为 +ios6 版」。
  +ios6 只是把这个修复固化进包，方便以后全新安装自带。


================================================================================
另：插件安装「退出码 127」—— 不是本包缺陷
================================================================================

现象
    插件安装失败  https://github.com/tencent-connect/dsh-qqbot (Git 仓库)
    $ pnpm add https://gith…    退出码 127    无输出
    安装位置: /var/jb/var/mobile/.dsh/profiles/web

  127 = shell 的 command not found。dsh 源码里明文写死了这个判定：
    dsh/lib/plugin-BiveYA7h.js:94
      if (result.exitCode === 127)
        process.stderr.write("dsh: pnpm was not found; install pnpm and make it
                             available on PATH.\n");
  「无输出」也印证命令压根没被执行。dsh 的插件安装就是在 profile 目录里
  spawn `pnpm add <spec>`；本包只内置 node，没有 pnpm / npm / corepack，
  包内 node_modules/.bin 里也没有。这是「前置工具缺失」，不是后端故障，
  换哪个 dsh 移植包都一样。

  而且这是 GitHub Git 仓库：即便装了 pnpm，还需要 git 命令、能访问
  github.com、以及 pnpm 的 allowBuilds 授权（源码里另有对应提示）。
  在 iPhone X rootless + nowasm(--jitless) 环境下这套工具链基本不具备。

先在终端确认到底缺什么（也可能只是 PATH 没带上）：
    which pnpm; which git; which node; echo "PATH=$PATH"
    ls /var/jb/usr/bin /var/jb/usr/local/bin 2>/dev/null | grep -E 'pnpm|git|npm|corepack'

  - 若 pnpm 其实在别的目录：把它加进 dsh.env 的 PATH，重启 dsh 即可。
  - 若确实没有：实际可行的做法是在电脑上把同一个 profile 的插件装好，
    再把 package.json + pnpm-lock.yaml + node_modules 同步到手机的
    /var/jb/var/mobile/.dsh/profiles/web；或改用市场里已打包好的插件 bundle。

================================================
+ios7：QQ Bot 插件已预装（本节覆盖上面关于「127」的旧结论）
================================================
上面「插件安装退出码 127」那节是 +ios6 时的判断：127 确实是设备端缺
pnpm（dsh 的 plugin 子命令把参数转发给 pnpm，源码 lib/plugin-BiveYA7h.js:94
写死了这条提示），但「只能自己在电脑上装好 profile 再同步」并不是唯一出路。
+ios7 让包自己把插件带上，用户不需要在手机上装任何东西。

用的插件：@tencent-connect/dsh-qqbot 0.5.5（官方 QQ 机器人插件）。
它是纯 Cordis 插件（inject = ['agents']），不改 dsh 主循环。

  1) 依赖：32 个包 / 321 个纯文本 JS·JSON 文件 / 约 1.2MB / 0 个 .node，
     已固化进 /var/jb/usr/lib/dsh/node_modules/。peer（cordis、dsh-agent、
     dsh-llm、dsh-session、schemastery、dsh-user-approval）直接复用宿主
     0.2.1-rc.5 的版本，逐个验证过 createUserMessage / BlockAssembler /
     SessionId / Schema / Context 都在，不会混进 0.1.0-rc.x 旧包。

  2) 注册：首次敲 dsh 时把一行
        - insert: { id: im-qqbot, name: '@tencent-connect/dsh-qqbot', ... }
     追加到 $DSH_HOME/cordis.patch.yml（dsh 原生 home 级用户层，对所有
     profile 生效），等价于官方 `dsh plugin --profile qqbot add` 的效果。
     凭据用 __FROM_ENV__ 占位，由插件读 QQBOT_APPID / QQBOT_SECRET。

  3) 真机专用修复（重要）：dsh 的 ESM resolver 以 profile 目录
     $DSH_HOME/profiles/<name>/ 为基准解析插件包名，而插件实体在
     /var/jb/usr/lib/dsh/node_modules —— 两者不在同一祖先链上，不处理
     必然 ERR_MODULE_NOT_FOUND。构建机上常因目录层级巧合看不出来。
     dsh 启动脚本、postinst、install-qqbot.sh 都会在
     $DSH_HOME/node_modules 建一条软链（已有真实目录时只挂插件链接，
     不覆盖），热修脚本把它当强校验项，建不起来直接报错。

  4) 凭据（任选其一）：
       a. 编辑 /var/jb/etc/dsh/qqbot.env 填 QQBOT_APPID / QQBOT_SECRET
          （q.qq.com 建机器人）—— 最稳，不依赖终端二维码渲染。
       b. 留空：启动后插件打印绑定链接，或用工作台「QQ 机器人」设置页
          让手机 QQ 扫码，凭据写入 $DSH_HOME/cordis.patch.yml，重启保留。
     DeepSeek API Key 沿用工作台原有的 LLM 配置，不用在这里填。

  5) A11 / 3GB 取舍：qqbot.patch.yml 里默认关掉 media（富媒体下载）和
     vision，避免图片消息下载大文件触发 jetsam；其余保持官方默认。
     临时不加载插件：DSH_QQBOT=0 dsh。

  6) 老设备免重传：跑一次 sh install-qqbot.sh（1.2MB，自包含 321 个文件）
     即可就地安装，然后必须 Ctrl+C 重启 dsh；--status 查状态，--remove 回滚。

  验证（x86 Linux 按 iOS 目录布局 1:1 模拟 /var/jb）：
     native 档 / nowasm 档（A11 实际档位）真实 wrapper 启动均
     0 did-not-activate、0 error；给 apply() 打探针确认真的执行。
     QQ 网关走 ws 包、扫码走 node:https、API 走 fetch-shim，均不受
     --jitless 影响。

  边界：沙盒里没有你的 QQ 机器人 AppID/Secret，也没法替你扫码，所以
  「连上 QQ 网关、收发消息」这一步要在真机上用你自己的凭据完成；这里
  保证的是插件本体在 A11 零 JIT 档确实被加载并运行，不再卡在 127。

================================================
+ios8：重启丢对话已修 / +ios9：dsh-im 已预装
================================================
+ios8（会话）：+ios2 把 zstd 降级成 gzip 却仍按 zstd 魔数读取，会话写得出
读不回。默认压缩已改为 none（明文 JSONL）。老设备跑 sh fix-session.sh：
改这一行 + 把已有 gzip 会话解成明文 + 原件移入 sessions-legacy-zstd/。
（必须移走，none 模式下 sessions/ 里残留 *.jsonl.zstd 会让 dsh 拒绝启动。）

+ios9（dsh-im 5.10.0，10 渠道 IM 机器人）：
  官方装法 dsh plugin --profile web add -w @xmanrui/dsh-im 在手机上必然
  退出码 127（缺 pnpm），且要求 Node >=22.19；本包内置 22.12.0。
  做法：插件 + 114 个运行时依赖（1275 文件 / 22.9MB / 0 个 .node）以
  私有嵌套 node_modules 固化，版本与宿主 / +ios7 QQ Bot 隔离；481 个 JS
  文件在 22.12 上语法检查全过；首次敲 dsh 自动往
  $DSH_HOME/cordis.patch.yml 追加 xmanrui-dsh-im 并建 ESM 解析链路。

  真机专用修复（重要）：A11 的 nowasm 档 = --jitless --no-expose-wasm，
  而 --jitless 会连带禁用 WebAssembly（连 node:vm 都取不到）。dsh-im 把
  WhatsApp 的 libsignal WASM glue 内联进 lib/index.js 并在模块顶层实例化，
  无 WASM 时整包 import 抛 "ge.lthashantitampering_new is not a function"，
  Cordis 只报 did-not-activate —— 网页能开但「设置 → IM机器人」入口和
  全部渠道消失。+ios9 给顶层单例加 try/catch 惰性化、给 history-sync
  的 lthash 收尾加 null 保护。native 档行为与官方包一致。
  唯一降级：WhatsApp 加密历史同步哈希（零 JIT 档返回占位值）；其余 9 个
  渠道（飞书/微信/企微/钉钉/QQ/Slack/Telegram/Discord/Matrix）完整可用。

  装法：新装包已自带；老设备跑 sh install-im.sh（7.8MB 自包含，会现场
  打补丁并顺带修 +ios8），装完必须 Ctrl+C 重启 dsh。--status 查状态，
  --remove 完整回滚。DSH_IM=0 dsh 可临时禁用。凭据在「设置 → IM机器人」
  里扫码或填，DeepSeek API Key 沿用工作台原配置。

  验证（x86 Linux 按 iOS 布局 1:1 模拟 /var/jb）：真实 wrapper 在 native
  与 nowasm 两档均 0 did-not-activate / 0 failed-import / 0 fatal；带 cookie
  握手后 index.html 的 client graph 含 @xmanrui/dsh-im/client.js，前端入口
  确实注入；热修脚本安装/幂等/回滚/重装全过。dsh-doctor 第 16、17 项自检。

  边界：沙盒里没有各平台真实凭据，也没法替你扫码，「连上网关收发消息」
  要在真机完成；这里保证插件本体、依赖树与前端入口在 A11 零 JIT 档确实
  被加载并运行。

+ios10：A11 真机最后一个 FAIL（node:sqlite builtin 未注册）
  dsh-doctor 报 "1 extraneous did not activate: xmanrui-dsh-im:
  failed to import: ERR_UNKNOWN_BUILTIN_MODULE: No such built-in module:
  node:sqlite"。@xmanrui/dsh-im 5.10.0 的 lib/index.js 顶层是静态 ESM
      import { DatabaseSync as sLe } from "node:sqlite";
  静态 import 不能 try/catch。包内 Node 22.12.0 已把 SQLite 编译进二进制
  （strings 可见 node::sqlite::DatabaseSync / sqlite3_open），但仍把
  node:sqlite 标为实验性，必须显式 --experimental-sqlite 才注册 builtin；
  22.13+ 才默认打开 —— 构建机是 22.13.1，所以 +ios9 离线 1:1 验证全绿，
  真机一跑就露出来。已用 Linux node --no-experimental-sqlite 精确复现
  同一报错与堆栈（esm/translators:356），并做 A/B 对照验证修复。
  修法（零降级）：tier.sh 集中定义 $TIER_SQLITE_ARGS，dsh / dsh-doctor /
  install-im.sh / install-qqbot.sh / fix-session.sh 所有启动行统一带
  --experimental-sqlite（另用 --disable-warning=ExperimentalWarning 压掉
  实验性提示）。dsh-im 的 SQLite 缓存完整可用，无需任何降级。
  doctor 同步修三处：
    第 9 项  不再把裸 "did not activate" 一律判 FAIL。修好 sqlite 后
             dsh-im 只是 "pending (waiting for services: connection,
             credentials)"（等待渠道凭据，正常），改成只看原因行。
    第 15 项 im-qqbot 未挂载改为幂等自愈补挂（消掉唯一那条 WARN）。
    第 18 项 新增：真跑 require('node:sqlite') + 核对启动链路开关。
  已装 +ios9 的设备免重传 125MB deb：
    sh /var/jb/usr/lib/dsh/fix-sqlite.sh    # 24KB 自包含
    dsh-doctor                             # 应 WARN=0 FAIL=0
  --status 查状态，--restore 回滚到 +ios9 三个启动文件（用户数据不动）。

+ios11：patch 属主 + 旧 pnpm 残留副本（两个「假绿灯」）
  A) /var/jb/usr/bin/dsh: 45: cannot create $DSH_HOME/cordis.patch.yml:
     Permission denied，但脚本仍打印「dsh: 已挂载 QQ Bot 插件」。原因：
     旧版热修以 root 创建过这个文件，mobile 用 >> 追加写不进去，而旧代码
     用 || true 吞掉错误、还无条件打印成功消息。修法：dsh / dsh-doctor /
     热修统一改成「同目录写临时文件 + mv 原子替换」，只要目录可写就能把
     root 属主的旧文件换成当前用户拥有的新文件；失败明确打印 [warn]。
  B) xmanrui-dsh-im: failed to import: TypeError:
     ge.lthashantitampering_new is not a function，堆栈指向
       node_modules/.pnpm/@xmanrui+dsh-im/5.10.0/node_modules/@xmanrui/dsh-im/lib/index.js
     设备上存在第二份 dsh-im（旧安装残留）。dpkg 升级只覆盖自己清单里的
     文件，不会清理它；ESM resolver 恰好加载这份没打 +ios9 零 JIT 补丁的
     副本。doctor 第 17 项只 grep 扁平那份（已打补丁）所以报 OK、汇总
     FAIL=0，用户一敲 dsh 却 1 entry did not activate。
     修法：dist/fix-ios11.sh 扫描设备上所有 @xmanrui/dsh-im/lib/index.js
     并逐份补补丁（精确替换 + 变量名反查兜底，命中数不对就拒绝改包）；
     dsh-doctor 新增第 19 项全盘扫描，缺任一份都判 FAIL；第 9 项失败正则
     补上 lthashantitampering / is not a function。
  老设备免重传 125MB deb：sh /var/jb/usr/lib/dsh/fix-ios11.sh
  --status 查状态，--restore 回滚 3 个启动文件。dist/fix-sqlite.sh 与它
  字节相同，跑任意一个都是最新修复，不会把启动文件刷回 +ios10。

+ios12：干净底座 + 修好安装插件 + 根治「无法创建新对话」(EACCES)
  1) 不再默认自带两个插件。包内完全不含 @xmanrui/dsh-im /
     @tencent-connect/dsh-qqbot；wrapper 不再写 cordis.patch.yml、不建
     软链、不改属主。改为内置 pnpm 10.28.2 纯 JS 发行版（19MB / 0 .node），
     /var/jb/usr/bin/pnpm 用包内 node 直接跑。dsh 的 plugin 子命令本来
     就把参数转发给 pnpm（bin.js:116），默认命令名就是字符串 'pnpm'，
     所以 PATH 里有它即可，不用改 dsh 源码：
       dsh plugin --profile web add <包名>
       dsh-compat                 # 装完 dsh-im 补 A11 零 JIT 补丁
     store/cache 全部落到 $DSH_HOME，不写 root 属主目录。
  2) 新建会话失败 EACCES：报错路径里的 --private-preboot-...-- 是 dsh
     把当前工作目录编码成的会话分组名 (projectKey(cwd))。整棵 sessions/
     曾被 root + .zshenv 包装器建过，mobile 写不进 session.v4.jsonl，
     gateway 建不了会话，依赖会话的插件「未运行」；纯 Cordis 的 QQ Bot
     绕开这条路所以「另一个能成功运行」。旧 doctor 只测 $DSH_HOME 顶层
     可写（postinst chmod 过），没测子目录 = 假绿灯。
     修法：dsh-home-heal.cjs 用 rename(2) 免 root 修属主 —— 只要求父
     目录可写，不需对目标有写权限、不需 chown。已用 nobody 身份对
     root:root 444 文件实测。单文件读内容后原子替换；sessions 整棵树
     改名搬到 sessions-legacy-root-<ts> 再重建，历史 *.jsonl 复制回来。
     同时整块删除 cordis.patch.yml 里旧预装的两条 - insert: 块（绝不
     逐行 grep -v），只删指向包内的 node_modules 软链。幂等，每次启动跑。
     dsh-doctor 第 20 项：真写一次 session 文件 + 扫描所有子目录可写。
  3) 此前全部修复保留：tier.sh 选档 / nowasm 零 JIT / fetch-shim 幂等
     body / Safari 16 垫片 / 会话压缩 none / --experimental-sqlite /
     全副本零 JIT 补丁扫描 / 第 9 项 pending 判定。doctor 15/17/19/21
     项重写为干净底座 + 安装链路 + 自动补齐 + 装后命令。
  老设备免重传 125MB deb：sh /var/jb/usr/lib/dsh/fix-ios12.sh
  以 mobile 跑时即使写不进 root 属主的包目录，用户数据自愈仍直接生效，
  并明确提示用 root 重跑或装新 deb 来升级 pnpm/doctor。

+ios14 真机回归修复（本版，1:1 复现环境逐字复现并验证）:
  症状 1：敲 dsh 直接崩
    dsh: fatal uncaught exception -> Error: patches: patches.yml/
        cordis.patch.yml must be a top-level YAML array of loader patch entries
      at parsePatchList (dsh-app-boot/lib/index.js:4000)
  根因：+ios12 的 cleanPatch() 把两条旧预装 - insert: 整块删掉后，文件
    只剩纯注释；js-yaml.load 返回 null，parsePatchList 的 !Array.isArray
    直接抛错。且 readProfilePatches 会读两类文件（$DSH_HOME/cordis.patch.yml
    与 profiles/*/cordis.patch.yml），+ios12 只清了前者，后者残留引用两个
    已不预装的包 -> headless boot ERR_MODULE_NOT_FOUND。更隐蔽的是 doctor
    第 15 项恰好触发这次清理并报 OK，于是「doctor 全绿、一敲 dsh 就崩」。
  修法：dsh-home-heal.cjs 改为 cleanAllPatches() —— 全量扫描两类 patch
    文件，整块删目标后强制保证顶层是合法 YAML 数组（空则写官方模板 []），
    并能修复真机上已被 +ios12 删坏的纯注释文件。严格只按 id 匹配，用户
    自己 dsh plugin add 装的块（id 不同）一律保留。幂等。
    dsh-doctor 开头先跑 heal 再检测，第 15 项改用包内 yaml 真解析所有
    patch 文件校验顶层数组。

  症状 2：dsh plugin --profile web add/list 仍报
    dsh: pnpm was not found; install pnpm and make it available on PATH. (127)
  根因：package.json 的 exports 把 CLI（lib/types/operations.js，单引号）
    与 web service（lib/index.js，双引号）分成两份构建产物，两者所有
    pnpm 调用都是 execa(options.command ?? 'pnpm', [...options.args ?? []],
    {env: environment, extendEnv: false})。真机上这个 dsh 自造的 env 里
    PATH 找不到 /var/jb/usr/bin，pnpm 的 /usr/bin/env node shebang 也不
    可靠 -> ENOENT -> 127。wrapper 里改 PATH 无效，因为 env 不继承它。
  修法：apply_pnpm_abs_patch.cjs 给两份产物各 5 处 command + 5 处 args
    注入「包内 node 绝对路径 + 纯 JS pnpm.cjs 绝对路径」直连：
      $D/bin/node $D/libexec/pnpm/bin/pnpm.cjs add <包名>
    彻底绕开 PATH / shebang。构建期与设备端热修共用同一脚本，幂等，
    精确命中校验（模式不符即中止，绝不打出未经验证的包）。
    dsh-doctor 新增第 22 项校验两份产物都已注入。

  升级：sh /var/jb/usr/lib/dsh/fix-ios14.sh（4.7MB 自包含热修，免重传
    120MB deb；--status 只看状态 / --restore 回滚启动文件）。或重装
    +ios14 的 .deb。之后 Ctrl+C 退出正在跑的 dsh，再敲 dsh 重启。
