#!/usr/bin/env bash
# =============================================================================
# fix.sh —— 修复 install.sh 生成的 HAProxy 配置在 Debian 13 (HAProxy 3.x) 上
#           被 systemd 前置检查判失败、服务起不来的问题
#
# 做四件事，全部幂等，可反复执行：
#   1) /etc/haproxy/haproxy.cfg：删掉 `nbthread <N>` 与 `option tcplog` 两处告警源
#   2) systemctl reset-failed + restart haproxy，并做存活/端口验证（失败自动回滚）
#   3) ~/.xray_port_info.json：把各端口 .haproxy.threads 夹到 CPU 核数以内
#   4) install.sh：打 8 处补丁，让后续重新生成配置时不再写回 12 线程 / tcplog
#
# 用法:
#   bash fix.sh                 # 全量修复（自动探测 install.sh 位置）
#   bash fix.sh --script /root/install.sh
#   bash fix.sh --dry-run       # 只打印计划动作，不落盘、不重启
#   bash fix.sh --restore       # 从 .pre-fix.bak 还原 cfg / state / install.sh
#   bash fix.sh --no-script     # 只修 cfg + state，不动 install.sh
#   bash fix.sh --no-restart    # 只改文件和打补丁，不重启服务
#
# 依赖: bash coreutils sed grep perl(perl-base 必备) systemctl haproxy,
#       状态文件修改需要 jq 或 python3 (二者缺一则跳过并提示)
# =============================================================================
set -Eeuo pipefail

CFG_HAPROXY=${CFG_HAPROXY:-/etc/haproxy/haproxy.cfg}
SERVICE=${SERVICE:-haproxy}
CPU=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) || CPU=1

DRY=0
RESTORE=0
PATCH_SCRIPT=1
DO_RESTART=1
TARGET_SCRIPT=""

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$OFF" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$OFF" "$*" >&2; }
dim()  { printf '%s    %s%s\n' "$DIM" "$*" "$OFF"; }
die()  { err "$*"; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
    --script)    TARGET_SCRIPT=${2:?--script 需要一个路径}; shift 2 ;;
    --script=*)  TARGET_SCRIPT=${1#*=}; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --restore)   RESTORE=1; shift ;;
    --no-script) PATCH_SCRIPT=0; shift ;;
    --no-restart) DO_RESTART=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           err "未知参数: $1"; usage; exit 2 ;;
  esac
done

run() {  # 干跑时不执行
  if (( DRY )); then dim "[dry-run] $*"; else "$@"; fi
}

# -----------------------------------------------------------------------------
# Phase 0: 前置检查
# -----------------------------------------------------------------------------
(( EUID == 0 )) || (( DRY )) || die "请用 root 运行（当前 UID=$EUID）"
command -v perl >/dev/null 2>&1 || die "缺少 perl（perl-base），无法安全打补丁"

printf '\n%s== 环境 ==%s\n' "$GRN" "$OFF"
dim "CPU 核数        : $CPU"
dim "HAProxy 配置    : $CFG_HAPROXY"
dim "systemd 服务    : $SERVICE"
dim "install.sh      : ${TARGET_SCRIPT:-（自动探测）}"
dim "模式            : $([[ $RESTORE == 1 ]] && echo 还原 || { (( DRY )) && echo 干跑 || echo 执行; })"
(( CPU == 1 )) && dim "提示            : 单核机器，nbthread 必须 <= 1"

# -----------------------------------------------------------------------------
# --restore: 还原
# -----------------------------------------------------------------------------
if (( RESTORE )); then
  printf '\n%s== 还原 ==%s\n' "$GRN" "$OFF"
  seen_restored=" "
  for pair in "$CFG_HAPROXY.pre-fix.bak:$CFG_HAPROXY" \
              "/root/.xray_port_info.json.pre-fix.bak:/root/.xray_port_info.json" \
              "$HOME/.xray_port_info.json.pre-fix.bak:$HOME/.xray_port_info.json"; do
    src=${pair%%:*}; dst=${pair#*:}
    [[ $seen_restored == *" $dst "* ]] && continue
    if [[ -f $src ]]; then
      run cp -a "$src" "$dst"; log "已还原 $dst <- $src"; seen_restored+="$dst "
    fi
  done
  s=${TARGET_SCRIPT:-/root/install.sh}
  if [[ -f "$s.pre-fix.bak" ]]; then run cp -a "$s.pre-fix.bak" "$s"; log "已还原 $s"; fi
  (( DRY )) || { systemctl reset-failed "$SERVICE" 2>/dev/null || true; systemctl restart "$SERVICE" || true; }
  log "还原完成"
  exit 0
fi

# -----------------------------------------------------------------------------
# Phase A: 修 /etc/haproxy/haproxy.cfg
# -----------------------------------------------------------------------------
printf '\n%s== A. HAProxy 配置 ==%s\n' "$GRN" "$OFF"
CFG_CHANGED=0
if [[ ! -f $CFG_HAPROXY ]]; then
  warn "未找到 $CFG_HAPROXY（脚本还没生成过配置？），跳过 A"
else
  bak="$CFG_HAPROXY.pre-fix.bak"
  if [[ -f $bak ]]; then
    dim "已存在备份 $bak（保留首次的原始件，不覆盖）"
  else
    run cp -a "$CFG_HAPROXY" "$bak"
    log "已备份 -> $bak"
  fi

  nb=$(grep -cE '^[[:space:]]*nbthread[[:space:]]' "$CFG_HAPROXY" || true); nb=${nb:-0}
  tl=$(grep -cE '^[[:space:]]*option[[:space:]]+tcplog[[:space:]]*$' "$CFG_HAPROXY" || true); tl=${tl:-0}
  dim "命中: nbthread=$nb 行, option tcplog=$tl 行"

  if (( nb + tl > 0 )); then
    run sed -i -E '/^[[:space:]]*nbthread[[:space:]]/d; /^[[:space:]]*option[[:space:]]+tcplog[[:space:]]*$/d' "$CFG_HAPROXY"
    log "已删除 $((nb + tl)) 行问题配置（nbthread 交给 HAProxy 按 CPU 自动决定）"
    CFG_CHANGED=1
  else
    log "配置已干净，无需改动"
  fi

  # 校验；不通过立即回滚
  out=$(mktemp)
  if ! command -v haproxy >/dev/null 2>&1; then
    warn "系统里没有 haproxy 命令，跳过配置校验（请自行确认）"
  elif haproxy -c -f "$CFG_HAPROXY" >"$out" 2>&1; then
    if grep -qi 'warning' "$out"; then
      warn "配置校验通过，但仍存在告警："
      grep -i 'warning' "$out" | sed 's/^/      /'
    else
      log "配置校验通过（无告警）"
    fi
  else
    err "配置校验失败，正在回滚到 $bak："
    sed 's/^/      /' "$out" >&2
    cp -a "$bak" "$CFG_HAPROXY"
    rm -f "$out"
    die "已回滚，服务未重启。请把上面输出发我。"
  fi
  rm -f "$out"
fi

# -----------------------------------------------------------------------------
# Phase B: 重启并验证
# -----------------------------------------------------------------------------
printf '\n%s== B. 重启服务 ==%s\n' "$GRN" "$OFF"
if (( ! DO_RESTART )); then
  warn "--no-restart 指定跳过 B"
elif ! command -v systemctl >/dev/null 2>&1; then
  warn "无 systemd，跳过 B（容器环境需手工 reload）"
else
  run systemctl reset-failed "$SERVICE" 2>/dev/null || true
  if (( DRY )); then
    dim "[dry-run] systemctl restart $SERVICE"
  elif systemctl restart "$SERVICE"; then
    log "systemctl restart $SERVICE 成功"
  else
    err "重启失败，最近日志："
    journalctl -xeu "$SERVICE" -n 40 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
    err "回滚命令: cp -a $CFG_HAPROXY.pre-fix.bak $CFG_HAPROXY && systemctl restart $SERVICE"
    exit 1
  fi

  if (( ! DRY )); then
    if systemctl is-active --quiet "$SERVICE"; then
      log "服务状态: active"
    else
      err "服务不是 active，请查 journalctl -xeu $SERVICE"
      exit 1
    fi
    printf '%s    %s\n' "$DIM" "监听端口:"
    ss -lntp 2>/dev/null | grep -i haproxy | sed 's/^/      /' || dim "（ss 看不到 haproxy 套接字，稍等再查）"
  fi
fi

# -----------------------------------------------------------------------------
# Phase C: 修正状态文件里的 threads
# -----------------------------------------------------------------------------
printf '\n%s== C. 状态文件 threads ==%s\n' "$GRN" "$OFF"
STATE=""
for cand in /root/.xray_port_info.json "$HOME/.xray_port_info.json"; do
  if [[ -f $cand ]]; then STATE=$cand; break; fi
done

if [[ -z $STATE ]]; then
  warn "未找到 .xray_port_info.json，跳过 C"
else
  dim "状态文件: $STATE"
  bak="$STATE.pre-fix.bak"
  [[ -f $bak ]] || { run cp -a "$STATE" "$bak"; log "已备份 -> $bak"; }

  cur=0
  if command -v jq >/dev/null 2>&1; then
    cur=$(jq -r '[(.ports[]? | select(.haproxy != null) | (.haproxy.threads // 0))] | max // 0' "$STATE" 2>/dev/null || echo 0)
  elif command -v python3 >/dev/null 2>&1; then
    cur=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
t = [((p.get("haproxy") or {}).get("threads") or 0) for p in (d.get("ports") or [])]
print(max(t) if t else 0)
' "$STATE" 2>/dev/null || echo 0)
  fi
  dim "当前最大 haproxy.threads = ${cur:-0}，将夹到 <= $CPU"

  tmp=$(mktemp)
  if command -v jq >/dev/null 2>&1; then
    if jq --argjson cpu "$CPU" '
          (.ports[]? | select(.haproxy != null) | .haproxy.threads)
            |= ([ (. // $cpu), $cpu ] | min)
        ' "$STATE" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
      run cp -a "$tmp" "$STATE"; log "threads 已按 CPU 封顶（jq）"
    else
      warn "jq 改写失败，保持原样"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if CPU="$CPU" python3 - "$STATE" "$tmp" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
cpu = int(os.environ["CPU"])
d = json.load(open(src))
ports = d.get("ports") or []
for p in ports:
    h = p.get("haproxy")
    if isinstance(h, dict):
        t = h.get("threads")
        h["threads"] = cpu if not isinstance(t, int) else max(1, min(t, cpu))
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
PY
    then
      run cp -a "$tmp" "$STATE"; log "threads 已按 CPU 封顶（python3）"
    else
      warn "python3 改写失败，保持原样"
    fi
  else
    warn "没有 jq / python3，无法自动改状态文件。请手工编辑 $STATE 把各 haproxy.threads 改成 1"
  fi
  rm -f "$tmp"
fi

# -----------------------------------------------------------------------------
# Phase D: 给 install.sh 打补丁（8 处，纯字面替换，锚点唯一）
# -----------------------------------------------------------------------------
printf '\n%s== D. install.sh 补丁 ==%s\n' "$GRN" "$OFF"

if (( ! PATCH_SCRIPT )); then
  warn "--no-script 指定跳过 D"
else
  if [[ -z $TARGET_SCRIPT ]]; then
    for cand in /root/install.sh ./install.sh /usr/local/bin/install.sh /opt/install.sh; do
      if [[ -f $cand ]]; then TARGET_SCRIPT=$(readlink -f "$cand"); break; fi
    done
  fi

  if [[ -z $TARGET_SCRIPT || ! -f $TARGET_SCRIPT ]]; then
    warn "未找到 install.sh，跳过 D。可用 --script /path/to/install.sh 指定"
  else
    dim "目标脚本: $TARGET_SCRIPT"
    grep -q 'my_abc\|max_threads\|haproxy' "$TARGET_SCRIPT" \
      || warn "该文件里没看到相关关键字，可能不是那份脚本，补丁大概率匹配不上"

    sbak="$TARGET_SCRIPT.pre-fix.bak"
    [[ -f $sbak ]] || { run cp -a "$TARGET_SCRIPT" "$sbak"; log "已备份 -> $sbak"; }
    sha_before=$(sha256sum "$TARGET_SCRIPT" | cut -d' ' -f1)

    PATCHES=$(mktemp)
    cat >"$PATCHES" <<'PATCHSET'
@@P1|update_haproxy_config: 线程上限默认值 12 -> 由 CPU 核数决定并列取 cpu_total
--OLD--
    local max_threads=12
--NEW--
    local max_threads=1 cpu_total=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
@@P2|update_haproxy_config: 读状态文件时的缺省值 12 -> 1
--OLD--
        threads=$(echo "$port_info" | jq -r '.haproxy.threads // 12')
--NEW--
        threads=$(echo "$port_info" | jq -r '.haproxy.threads // 1')
@@P3|生成的配置: nbthread 超过 CPU 核数时自动夹到 cpu_total
--OLD--
    nbthread $max_threads
--NEW--
    nbthread $(( max_threads > cpu_total ? cpu_total : max_threads ))
@@P4|生成的配置: 注释掉 option tcplog（无 log 地址时会告警）
--OLD--
    option tcplog
--NEW--
    # option tcplog  # 未配置 log 地址时 HAProxy 3.x 会告警，systemd 前置检查因此失败
@@P5|configure_socks5: threads 缺省 12 -> CPU 核数
--OLD--
    local haproxy_port haproxy_threads=12 haproxy_maxconn=400
--NEW--
    local haproxy_port haproxy_threads=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1) haproxy_maxconn=400
@@P6|configure_socks5: 沿用旧配置时同样夹到 CPU 核数
--OLD--
        haproxy_threads=$(echo "$current_haproxy" | jq -r '.threads // 12')
--NEW--
        haproxy_threads=$(echo "$current_haproxy" | jq -r --argjson cpu "$haproxy_threads" '.threads // $cpu | if . > $cpu then $cpu else . end')
@@P7|sync_config_from_xray: 入口处取一次 CPU 核数
--OLD--
    print_title "从Xray配置同步端口信息"
--NEW--
    print_title "从Xray配置同步端口信息"

    # 同步出来的 HAProxy 线程数按 CPU 核数取值
    local cpu_threads
    cpu_threads=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
--SKIP-IF--
    local cpu_threads
@@P8|sync_config_from_xray: 两处硬编码 12 线程 -> $cpu_threads
--OLD--
set_port_haproxy_config "$port" "y" "$hp_port" 12 400
--NEW--
set_port_haproxy_config "$port" "y" "$hp_port" "$cpu_threads" 400
PATCHSET

    # 解析补丁集
    NAMES=(); OLDS=(); NEWS=(); SKIPS=(); idx=-1; mode=""
    while IFS= read -r line; do
      case "$line" in
        @@*)         idx=$((idx + 1)); NAMES[idx]="${line#@@}"; OLDS[idx]=""; NEWS[idx]=""; SKIPS[idx]=""; mode=""; continue ;;
        --OLD--)     mode=old; continue ;;
        --NEW--)     mode=new; continue ;;
        --SKIP-IF--) mode=skip; continue ;;
      esac
      case "$mode" in
        old)  OLDS[idx]+="$line"$'\n' ;;
        new)  NEWS[idx]+="$line"$'\n' ;;
        skip) SKIPS[idx]+="$line"$'\n' ;;
      esac
    done <"$PATCHES"
    rm -f "$PATCHES"

    applied=0; skipped=0; missing=0
    for ((i = 0; i < ${#NAMES[@]}; i++)); do
      label=${NAMES[i]%%|*}
      desc=${NAMES[i]#*|}
      # 去掉解析时补的尾部换行：让 OLD 能匹配「行首有缩进、行尾还有内容」的行内子串
      old=${OLDS[i]%$'\n'}
      new=${NEWS[i]%$'\n'}
      skip_lit=${SKIPS[i]%$'\n'}

      # 该补丁是可叠加的（像 P7 这种前缀替换），用 SKIP-IF 字面量判断是否已打过
      if [[ -n $skip_lit ]] && grep -qF -- "$skip_lit" "$TARGET_SCRIPT"; then
        dim "$label 已是最新，跳过: $desc"
        skipped=$((skipped + 1))
        continue
      fi

      cnt=0
      if ! cnt=$(OLD="$old" perl -0777 -ne 'my $c = () = /\Q$ENV{OLD}\E/g; print $c + 0;' "$TARGET_SCRIPT" 2>/dev/null); then
        cnt=0
      fi

      if [[ ${cnt:-0} -gt 0 ]]; then
        if (( DRY )); then
          dim "[dry-run] $label $desc（命中 ${cnt} 处）"
        else
          OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$TARGET_SCRIPT"
          log "$label 已打: $desc"
        fi
        applied=$((applied + 1))
      else
        # 已经打过补丁也算 OK
        cnt2=0
        if ! cnt2=$(OLD="$new" perl -0777 -ne 'my $c = () = /\Q$ENV{OLD}\E/g; print $c + 0;' "$TARGET_SCRIPT" 2>/dev/null); then
          cnt2=0
        fi
        if [[ ${cnt2:-0} -gt 0 ]]; then
          dim "$label 已是最新，跳过: $desc"
          skipped=$((skipped + 1))
        else
          warn "$label 锚点未找到（脚本版本不同？）: $desc"
          missing=$((missing + 1))
        fi
      fi
    done

    printf '%s    小结: 新打 %d, 已存在 %d, 未匹配 %d%s\n' "$DIM" "$applied" "$skipped" "$missing" "$OFF"

    if (( ! DRY )); then
      if bash -n "$TARGET_SCRIPT" 2>/dev/null; then
        sha_after=$(sha256sum "$TARGET_SCRIPT" | cut -d' ' -f1)
        if [[ $sha_before == "$sha_after" ]]; then
          log "脚本内容未变化（可能已是加固版）"
        else
          log "语法检查通过 bash -n，sha256 ${sha_before:0:12} -> ${sha_after:0:12}"
        fi
      else
        err "打补丁后语法检查失败！正在还原 $TARGET_SCRIPT"
        bash -n "$TARGET_SCRIPT" 2>&1 | sed 's/^/      /' >&2 || true
        [[ -f $sbak ]] && cp -a "$sbak" "$TARGET_SCRIPT"
        die "已还原，未保留任何改动"
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 收尾
# -----------------------------------------------------------------------------
printf '\n%s== 完成 ==%s\n' "$GRN" "$OFF"
if (( DRY )); then
  warn "干跑结束，未做任何改动。去掉 --dry-run 真正执行。"
  exit 0
fi

echo "现在可以:"
echo "  1) 看结果      : systemctl status $SERVICE --no-pager; ss -lntp | grep haproxy"
echo "  2) 重跑脚本    : bash ${TARGET_SCRIPT:-/root/install.sh}   # 选 4->端口->5 重新生成配置"
echo "  3) 反悔        : bash $0 --restore"
echo
echo "改动清单:"
[[ -f $CFG_HAPROXY && -f $CFG_HAPROXY.pre-fix.bak ]] && echo "  $CFG_HAPROXY  ($(diff -u "$CFG_HAPROXY.pre-fix.bak" "$CFG_HAPROXY" 2>/dev/null | grep -c '^[+-][^+-]' || true) 行变化, 备份 $CFG_HAPROXY.pre-fix.bak)"
[[ -n $STATE && -f $STATE.pre-fix.bak ]] && echo "  $STATE  (备份 $STATE.pre-fix.bak)"
[[ -n $TARGET_SCRIPT && -f $TARGET_SCRIPT.pre-fix.bak ]] && echo "  $TARGET_SCRIPT  ($(diff -u "$TARGET_SCRIPT.pre-fix.bak" "$TARGET_SCRIPT" 2>/dev/null | grep -c '^[+-][^+-]' || true) 行变化, 备份 $TARGET_SCRIPT.pre-fix.bak)"
