#!/usr/bin/env bash
# patch-gvisor-tun-fd.sh - 补丁 metacubex/gvisor 的 fdbased 端点，使 gVisor TUN 栈
# 能在鸿蒙 VpnExtension 沙箱内工作。
#
# 背景: gVisor 的 fdbased.New() 会调 isSocketFD(fd) -> unix.Fstat(fd) 来决定走
# recvmmsg(socket) 还是 readv(tun) 分发路径。鸿蒙沙箱对 VPN tun fd 拒绝 Fstat
# （EPERM），于是端点初始化失败 -> gVisor 栈起不来 -> 所有 TCP 静默丢失
# （UDP/DNS 正常，因为直接注入 gVisor）。
#
# 处理: tun fd 永远不可能是 socket，Fstat 失败时回退到非 socket（readv）路径。
# 直接改 GOMODCACHE 里的模块源码（gvisor 是普通依赖，构建时幂等应用）。
#
# 用法: patch-gvisor-tun-fd.sh [go-executable]
set -euo pipefail

GO="${1:-go}"
MARKER="OHOS: VPN tun fd is not Fstat-able"

GOMODCACHE="$("$GO" env GOMODCACHE 2>/dev/null || true)"
if [ -z "${GOMODCACHE}" ]; then
  echo "[patch-gvisor] could not resolve GOMODCACHE via '$GO'; skipping" >&2
  exit 0
fi

shopt -s nullglob
endpoints=("$GOMODCACHE"/github.com/metacubex/gvisor@*/pkg/tcpip/link/fdbased/endpoint.go)
shopt -u nullglob

if [ ${#endpoints[@]} -eq 0 ]; then
  echo "[patch-gvisor] FATAL: no metacubex/gvisor fdbased endpoint.go under ${GOMODCACHE}" >&2
  echo "[patch-gvisor] run 'go mod download github.com/metacubex/gvisor' first, then retry" >&2
  exit 1
fi

patched=0
for ep in "${endpoints[@]}"; do
  if grep -q "${MARKER}" "$ep"; then
    echo "[patch-gvisor] already patched: $ep"
    continue
  fi
  if ! grep -q 'unix.Fstat(%v,...) failed' "$ep"; then
    echo "[patch-gvisor] FATAL: unexpected fdbased content in $ep (gvisor version drifted?), Fstat error line not found" >&2
    exit 1
  fi
  chmod u+w "$ep"
  python3 - "$ep" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
old = '\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)\n'
new = '\t\treturn false, nil // ' + marker + ' (musl/SELinux); treat as non-socket\n'
if old not in src:
    raise SystemExit("[patch-gvisor] could not find Fstat return line in " + path)
with open(path, "w", encoding="utf-8") as f:
    f.write(src.replace(old, new, 1))
PY
  echo "[patch-gvisor] patched: $ep"
  patched=1
done

if [ "$patched" -eq 0 ]; then
  # 已全部 patched 时也正常退出（幂等）
  :
fi
