/*
 * dsh-ios-manual-install-transform.js —— +ios15
 *
 * 作用范围（硬约束）：
 *   ✔ 只在「Web UI 点击插件 → 安装插件」对话框里的【所有手动安装方式】生效。
 *   ✘ AI 帮你装（dsh-plugin-manager/lib/types/tools.js，agent tool）不经过本文件。
 *   ✘ 命令行 dsh plugin add（lib/types/operations.js）不经过本文件。
 *   调用点由 apply_plugin_install_patch.cjs 精确注入到
 *   dsh-client-ui-plugin-manager/lib/client.js 的 installBundle(spec) 之前，
 *   那份 client.js 是 Web UI 手动安装对话框专属前端模块。
 *
 * 为什么需要：iOS rootless 没有 git/npm/corepack 二进制，只有包内纯 JS pnpm。
 * 用户手动填的 GitHub 仓库地址 / git+ssh / git+https 会触发 pnpm 的 git 传输，
 * 或让 service 的 checkGithubConnection 预检去 execa("git") 而失败。
 * 这里把它们统一转换成 pnpm 的 hosted-git 简写 / tarball（pnpm 走 codeload
 * HTTP 下载，不需要本地 git），并把 iOS/浏览器不兼容插件给出明确提示+替代建议。
 *
 * 设计原则：
 *   - 绝不硬拦安装（判定可能误伤，用户/AI 也许有办法）；只提示 + 尽量转成可用形式。
 *   - 未识别的 spec 原样返回，不改变任何本来能装成功的方式。
 *   - 纯 ES2019 语法，兼容 Safari 16.6（iOS 16.7.15 / iPhone X）。
 */
(function (global) {
  'use strict';

  /* 已知在 iOS A11 / Safari 16.6 上跑不起来的形态（按 spec 名字特征判断）。
     只用于「提示 + 给替代建议」，不拦截。生态全清单见 docs/DSH-ECOSYSTEM-PLUGINS.md。 */
  var INCOMPATIBLE = [
    { re: /(electron|playwright|puppeteer|selenium|tauri)/i,
      why: '依赖桌面窗口 / 浏览器自动化，需要 macOS·Windows·Linux 桌面环境',
      tip: '改用纯 JS 的 DSH 插件；或让 AI 帮你装时自行裁剪桌面依赖' },
    { re: /(node-pty|better-sqlite3|sqlite3|sharp|canvas|node-gyp|esbuild|swc\.core|@napi-rs)/i,
      why: '依赖原生 .node addon 或需要本地编译，iOS 无法加载/编译',
      tip: '寻找提供纯 JS / WASM 替代的同类插件' },
    { re: /(docker|kubernetes|kubectl)/i,
      why: '需要 Docker / 容器运行时', tip: 'iOS 无容器运行时；改用纯 JS 实现' },
    { re: /(termux|android|macos|windows)-only/i,
      why: '平台专属插件', tip: '换用跨平台版本' }
  ];

  /* 版本号要求 Node >= 24 的已知插件（0.2.2-rc.1 生态常见）。
     本包锁死 Node 22.12.0（A11 唯一能跑的二进制），这类插件装上也起不来。 */
  var NODE24 = [
    /dsh-.*(?:next|v2|2025)/i
  ];

  function notice(spec, why, tip) {
    var msg = '[dsh-ios +ios15] 插件可能不兼容本机: ' + spec +
              '\n  原因: ' + why + '\n  建议: ' + tip +
              '\n  (仅提示，不拦截安装；AI 帮你装不会应用本转化)';
    try { if (global.console && global.console.warn) global.console.warn(msg); } catch (e) {}
    try {
      global.__dshIosInstallNotices = global.__dshIosInstallNotices || [];
      global.__dshIosInstallNotices.push({ spec: spec, why: why, tip: tip });
      if (global.dispatchEvent && typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new global.CustomEvent('dsh-ios-install-notice', {
          detail: { spec: spec, why: why, tip: tip }
        }));
      }
    } catch (e) {}
  }

  function info(from, to, why) {
    try {
      if (global.console && global.console.info) {
        global.console.info('[dsh-ios +ios15] 手动安装 spec 已转化: ' + from + '  ->  ' + to +
                            (why ? '\n  ' + why : ''));
      }
    } catch (e) {}
  }

  /* GitHub 仓库地址 → pnpm hosted-git 简写 github:owner/repo[#ref]。
     pnpm 对 github: 简写走 codeload HTTP tarball，不需要本地 git 二进制。 */
  function githubShorthand(owner, repo, ref) {
    var s = 'github:' + owner + '/' + repo.replace(/\.git$/i, '');
    if (ref) s += '#' + ref;
    return s;
  }

  /* 从匹配结果里取 ref。+ios15 修正：GitHub 分支名常含斜杠
     （release/v2、feat/ios15），旧正则的 /tree/([^/#]+) 会把整条 URL
     判成「未识别」而原样放行 —— 手动安装仍会失败。现在 #ref 优先于
     /tree/ref，并去掉 tree 路径可能带上的尾斜杠。 */
  function refFrom(m) {
    return String(m[4] || m[3] || '').replace(/\/+$/, '');
  }

  function transform(spec) {
    if (typeof spec !== 'string') return spec;
    var raw = spec.trim();
    if (raw === '' || raw.charAt(0) === '-') return spec;   // 交给后端判 invalid-spec

    var m, t;

    /* 本地路径 / file: / link: / tarball URL：原样放行。
       这些本来就能通过包内 pnpm 安装，不做任何改动。 */
    if (/^(file:|link:|\/|\.\/|\.\.\/|~)/.test(raw)) return spec;
    if (/^https?:\/\/.*\.(tgz|tar\.gz)$/i.test(raw)) return spec;

    /* ★ 所有 git 形式必须在「纯 npm 包名」判定之前处理：
       否则 `git@github.com:foo/bar.git` 会被误判成「包名@版本」而原样放行。 */
    // git@github.com:owner/repo.git  或  git+ssh://git@github.com/owner/repo.git
    m = raw.match(/^(?:git\+ssh:\/\/)?git@github\.com[:\/]([^/]+)\/([^/#]+?)(?:\.git)?(?:\/tree\/([^#]+?))?(?:#(.+))?\/?$/i);
    if (m) {
      t = githubShorthand(m[1], m[2], refFrom(m));
      info(raw, t, 'pnpm 走 codeload tarball，不需要本地 git；也绕开 service 的 git 预检');
      checkIncompatible(raw);
      return t;
    }
    // git+https://github.com/owner/repo.git  或  git://github.com/...
    m = raw.match(/^(?:git\+https?|git):\/\/github\.com\/([^/]+)\/([^/#]+?)(?:\.git)?(?:\/tree\/([^#]+?))?(?:#(.+))?\/?$/i);
    if (m) {
      t = githubShorthand(m[1], m[2], refFrom(m));
      info(raw, t, 'pnpm hosted-git 简写走 HTTP tarball');
      checkIncompatible(raw);
      return t;
    }
    // 裸 https://github.com/owner/repo[/tree/ref][.git]
    m = raw.match(/^https?:\/\/github\.com\/([^/]+)\/([^/#]+?)(?:\.git)?(?:\/tree\/([^#]+?))?(?:#(.+))?\/?$/i);
    if (m) {
      t = githubShorthand(m[1], m[2], refFrom(m));
      info(raw, t, 'GitHub 仓库地址转成 hosted-git 简写');
      checkIncompatible(raw);
      return t;
    }
    // 已经是 github: 简写：放行（pnpm 走 HTTP，无需本地 git）
    if (/^github:/i.test(raw)) { checkIncompatible(raw); return spec; }
    // 其它 git 传输（gitlab / bitbucket / 自托管 / git@非github）：给提示
    if (/^(?:git\+|git@|git:\/\/|gitlab:|bitbucket:)/i.test(raw)) {
      notice(raw, '该 git 传输形式可能需要本地 git 二进制（iOS 没有）',
             '改用已发布到 npm 的包名，或 https://codeload.github.com/... 的 tarball URL');
      checkIncompatible(raw);
      return spec;
    }

    /* 纯 npm 包名（可带版本/范围）：字符集收紧到不含 : 和 /，避免误吃 git@。 */
    if (/^(?:@[a-z0-9._~-]+\/)?[a-z0-9][a-z0-9._~-]*(?:@[a-z0-9.*^~+<>=| -]+)?$/i.test(raw)) {
      checkIncompatible(raw);
      return spec;
    }

    /* 其它 URL（自建索引 / gist 等）：原样放行并做特征提示。 */
    checkIncompatible(raw);
    return spec;
  }

  function checkIncompatible(raw) {
    for (var i = 0; i < INCOMPATIBLE.length; i++) {
      if (INCOMPATIBLE[i].re.test(raw)) {
        notice(raw, INCOMPATIBLE[i].why, INCOMPATIBLE[i].tip);
        return;
      }
    }
    for (var j = 0; j < NODE24.length; j++) {
      if (NODE24[j].test(raw)) {
        notice(raw, '该插件可能要求 Node >= 24，而本包锁死 Node 22.12.0（A11 唯一可用）',
               '寻找标注支持 Node 22 的旧版本或同类替代插件');
        return;
      }
    }
  }

  global.__dshIosTransformSpec = transform;
  global.__dshIosTransformSpecVersion = 'dsh-ios +ios15';
})(typeof window !== 'undefined' ? window : this);
