// dsh-iOS shim —— 覆盖 node_modules/@deepseek-ai/node-addon-system/lib/flock.js
//
// 原实现在首次 session 持久化时加载 per-platform 原生 .node 调用 POSIX flock。
// iOS arm64 无对应产物，headless profile 会报
//   "Cannot find module '@deepseek-ai/node-addon-system-linux-x64/package.json'"。
//
// 单实例终端场景下不存在多进程争抢同一个 session 文件，锁恒成功即等价语义。
export async function tryLockExclusive(_fd) { return; }
export async function tryLockShared(_fd) { return; }
