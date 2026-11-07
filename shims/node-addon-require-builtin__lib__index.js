"use strict";
// dsh-iOS shim —— 覆盖 node_modules/node-addon-require-builtin/lib/index.js
//
// 原实现通过 node-addon-native-custom-loader 加载一个 per-platform 原生 .node，
// 用来 require() Node 的私有内部模块（internal/modules/*）。iOS arm64 没有对应
// 的预编译产物，dsh-app-boot 会在 host preparation 阶段直接抛错。
//
// Node 自带的 --expose-internals 可以让普通 createRequire() 直接加载这些内部模块，
// 因此这里用纯 JS 等价实现三个导出函数。启动脚本 /var/jb/usr/bin/dsh 已带该参数。
//
// 已在 Node 22.19.0 上实测：web 与 headless 两个 profile 均完整 boot 成功。
const { createRequire } = require("node:module");
const _req = createRequire(__filename);

function requireBuiltin(moduleId) {
    return _req(moduleId);
}

function isAllowedInternalId(moduleId) {
    return typeof moduleId === "string" &&
        (moduleId.startsWith("internal/") || moduleId.startsWith("node:internal/"));
}

function getBindingInfo() {
    return Object.freeze({
        mode: "expose-internals",
        product: "dsh-ios-shim",
        backend: "js",
        abi: String(process.versions.modules),
        bindingPath: __filename,
        bindingSource: "shim",
        localBindingPath: "",
        optionalPackageName: "",
        optionalBinaryRelativePath: "",
        platformPackageSuffix: ""
    });
}

const api = { requireBuiltin, isAllowedInternalId, getBindingInfo };
module.exports = Object.assign(api, { __esModule: true, default: api });
