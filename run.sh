#!/usr/bin/env bash
#
# Serve a model through the single tabbyAPI + litellm stack on port 8881.
#
#   ./run.sh              # qwen3.8 (default; turboderp/Qwen3.8-27B-exl3)
#   ./run.sh ornith1.5    # ultimatechris/Ornith-1.5-35B-A3B-EXL3-4bpw
#   ./run.sh qwen3.8
#
# Control verbs:
#   ./run.sh stop        # `docker compose down` the whole tabbyAPI + litellm stack
#   ./run.sh start [M]   # verify + start model M (default qwen3.8)
#   ./run.sh status      # list compose projects + running containers
#   ./run.sh logs [M]    # follow docker compose logs (both tabbyapi + litellm)
#   ./run.sh stats [S]   # live GPU monitor for the running tabbyapi container
#                        # (S = refresh seconds, default 1)
#
# The 4090 fits ONE model at a time, so this script is the only launcher:
# it verifies the model's configs + weights, stops whatever other tabbyAPI
# stack is live (after copying its litellm history DB to docker/), and
# starts the requested model on the same port. KEEP_OLD=1 ./run.sh ...
# refuses to stop the live model instead.
#
# Adding a model: drop in
#   docker/config.<model>.yml
#   docker/litellm-config.<model>.yaml
#   models/download-<model>.sh   (writes models/<dir name>)
# then ./run.sh <model>. A top-level `model_slug: <slug>` key in the
# tabbyAPI config overrides the compose project name (defaults: model
# name with dots removed).

set -euo pipefail
cd "$(dirname "$0")"

# Project name (compose slug) of the live tabbyapi stack, read off the
# container label the same way the `stop` verb does. Prints nothing when no
# stack is running; the `logs` verb treats that as "nothing to follow".
detect_project() {
    local cid
    cid="$(docker ps -q --filter label=com.docker.compose.service=tabbyapi 2>/dev/null | head -n1 || true)"
    [ -n "$cid" ] || return 0
    docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true
}

MODEL="${1:-qwen3.8}"
# --- control verbs (dispatch at the end reassigns MODEL) -------------------
case "${1:-}" in
    stop)
        echo "stopping tabbyAPI + litellm stack ..."
        while read -r cid; do
            proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true)"
            [ -n "$proj" ] || continue
            echo "  down: $proj"
            docker compose -p "$proj" -f docker/docker-compose.local.yml down --timeout 30 >/dev/null 2>&1 || true
        done < <(docker ps -q --filter label=docker.docker.compose.project >/dev/null 2>&1 && docker ps -q --filter label=com.docker.compose.service=tabbyapi 2>/dev/null)
        echo "done."
        exit 0
        ;;
    stats)
        interval="${2:-1}"
        if [[ ! $interval =~ ^([1-9][0-9]*([.][0-9]+)?|0[.][0-9]*[1-9][0-9]*)$ ]]; then
            echo "Usage: $0 stats [refresh-seconds]" >&2
            exit 2
        fi
        for command in docker nvidia-smi; do
            if ! command -v "$command" >/dev/null 2>&1; then
                echo "Required command not found: $command" >&2
                exit 1
            fi
        done
        # The right container is the tabbyapi service of the live stack.
        # Re-looked-up every frame so the monitor follows restarts and
        # model switches without being restarted.
        printf '\033[?25l'
        trap 'printf "\033[?25h\n"' EXIT
        trap 'exit 0' INT TERM
        while true; do
            GPU_CID="$(docker ps -q --filter label=com.docker.compose.service=tabbyapi 2>/dev/null | head -n1 || true)"
            printf '\033[H'
            printf 'TabbyAPI GPU monitor - %s - refresh: %ss\n\n' \
                "$(date '+%F %T')" "$interval"
            if [[ -z $GPU_CID ]]; then
                echo 'No tabbyapi container running. Start one first: ./run.sh start'
                printf '\033[J'
                sleep "$interval"
                continue
            fi
            GPU_NAME="$(docker inspect --format '{{.Name}}' "$GPU_CID" 2>/dev/null | sed 's|^/||' || true)"
            GPU_STATE="$(docker inspect --format '{{.State.Status}}' "$GPU_CID" 2>/dev/null || true)"
            printf 'Container: %s  State: %s\n\n' "${GPU_NAME:-unknown}" "${GPU_STATE:-unknown}"
            gpu_rows=$(nvidia-smi --query-gpu=uuid,index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null || true)
            if [[ -z $gpu_rows ]]; then
                echo 'nvidia-smi could not read GPU metrics.'
                exit 1
            fi
            # container_pids is just to note when the GPU lists no process
            # for the container (common across PID namespaces), not for
            # matching.
            container_pids=$(docker top "$GPU_CID" -eo pid= 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1 }' | tr '\n' ' ' || true)
            app_rows=$(docker exec "$GPU_CID" nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true)
            matching_apps=$(awk -F ', *' -v pids="$container_pids" '
                BEGIN {
                    count = split(pids, values, " ")
                    for (i = 1; i <= count; i++) {
                        if (values[i] != "") wanted[values[i]] = 1
                    }
                }
                $2 in wanted { print }
            ' <<< "$app_rows")
            relevant_uuids=$(docker exec "$GPU_CID" nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | awk '{$1=$1; print}' || true)
            printf '%-3s %-24s %7s %7s %18s %7s %17s\n' GPU NAME UTIL MEM-UTIL VRAM TEMP POWER
            awk -F ', *' -v uuids="$relevant_uuids" '
                BEGIN {
                    count = split(uuids, values, /[[:space:]]+/)
                    for (i = 1; i <= count; i++) wanted[values[i]] = 1
                }
                $1 in wanted {
                    printf "%-3s %-24.24s %6s%% %6s%% %7s / %-7s MiB %5s C %7s / %-7s W\n", $2, $3, $4, $5, $6, $7, $8, $9, $10
                }
            ' <<< "$gpu_rows"
            if [[ -n $matching_apps ]]; then
                printf '\nContainer GPU processes:\n'
                printf '%-8s %-24s %12s\n' PID PROCESS VRAM
                awk -F ', *' '{ printf "%-8s %-24.24s %9s MiB\n", $2, $3, $4 }' <<< "$matching_apps"
            else
                printf '\nPer-process GPU accounting is unavailable. GPU totals above remain valid.\n'
                echo 'This is expected when Docker and nvidia-smi use different PID namespaces.'
            fi
            printf '\033[J'
            sleep "$interval"
        done
        ;;
    logs)
        case "${2:-}" in
            [a-zA-Z]*)
                MODEL="$2"
                CFG="docker/config.${MODEL}.yml"
                if [ ! -f "$CFG" ]; then
                    echo "error: MODEL='$MODEL' has no docker/config.${MODEL}.yml (known:)" >&2
                    for c in docker/config.*.yml; do [ -f "$c" ] && echo "  $(basename "$c" .yml)" >&2; done
                    exit 1
                fi
                SLUG="$(python3 - "$CFG" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"^\s*model_slug:\s*\"?([\w.-]+)\"?\s*$", txt, re.M)
print(m.group(1) if m else "")
PY
)"
                PROJ="${SLUG:-${MODEL//./}}"
                ;;
            --*) shift;;
            *)
                # no model arg: read the project name straight off the live
                # container label (same detection as the `stop` verb).
                PROJ="$(detect_project)"
                if [ -z "$PROJ" ]; then
                    echo "logs: no model given and no tabbyapi stack running" >&2
                    exit 1
                fi
                echo "logs: no model given, detected running project '$PROJ'"
                ;;
        esac
        # compose logs finds the project's containers by their compose label,
        # so -p <project> is all that's needed; no MODEL/MODEL_SLUG env.
        echo "following logs for project $PROJ; Ctrl-C to stop"
        echo
        docker compose -p "$PROJ" -f docker/docker-compose.local.yml \
            logs --tail 200 -f "${@:3}"
        # THIS BRANCH MUST EXIT: anything below falls through into the
        # 'start' orchestration (validate -> stop others -> up -d).
        exit 0
        ;;
    status)
        echo "=== tabbyapi containers ==="
        # ps support is yes/no and actively being worked on (#17594/#17653 #15379); as a fallback try a small pipeline.
        docker ps 2>/dev/null | grep -i tabby && echo "(ps: ok)"
        ps_rc=$?
        echo "  (ps supported: $ps_rc ; =ps-ok, no ps-aware containers otherwise)|| true"
        echo "=== (fallback listing, by service label) ==="
        for cid in $(docker ps -q 2>/dev/null); do
            svc="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
            [ -n "$svc" ] || continue
            case "$svc" in tabbyapi|litellm|litellm-db)
                proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true)"
                echo "  ${proj:-?}/$svc"
                ;;
            esac
        done
        exit 0
        ;;
    start|"")
        case "${2:-}" in
            --*) ;; # option passed straight through to the launcher
            *) MODEL="${2:-qwen3.8}"; shift 2>/dev/null || true ;;
        esac
        ;;
    *)
        MODEL="$1"
        ;;
esac

CFG="docker/config.${MODEL}.yml"
LCFG="docker/litellm-config.${MODEL}.yaml"

for f in "$CFG" "$LCFG"; do
    [ -f "$f" ] || {
    echo "error: MODEL='$MODEL' is missing $f" >&2
    echo "available:" >&2
    for c in docker/config.*.yml; do [ -f "$c" ] && echo "  $(basename "$c" .yml)"; done >&2
    exit 1
}
done

# slug + checkpoint dir straight from the tabby config
# (model_slug / model_dir / model_name)
read -r SLUG CKPT < <(python3 - "$CFG" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
def grab(key):
    m = re.search(r"^\s*%s:\s*\"?([\w.\-/]+)\"?\s*$" % key, txt, re.M)
    return m.group(1) if m else ""
slug, d, name = grab("model_slug"), grab("model_dir"), grab("model_name")
print(slug, (d + "/" + name if d and name else "models"))
PY
)
SLUG="${SLUG:-${MODEL//./}}"
[ -n "$CKPT" ] || CKPT="models/$MODEL"
[ -d "$CKPT" ] || { echo "error: checkpoint dir missing: $CKPT (run models/download-${MODEL}.sh first)" >&2; exit 1; }

# --- stop any other live tabbyAPI stack (back up its litellm DB) ----------
OTHERS=""
for cid in $(docker ps -q --filter label=com.docker.compose.service=tabbyapi 2>/dev/null); do
    proj="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true)"
    [ -n "$proj" ] && [ "$proj" != "$SLUG" ] && OTHERS="$OTHERS $proj"
done
OTHERS=$(echo "$OTHERS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

if [ -n "$OTHERS" ]; then
    for OLD in $OTHERS; do
        if [ "${KEEP_OLD:-0}" = "1" ]; then
            echo "error: stack '$OLD' is live; stop it first or rerun without KEEP_OLD=1" >&2
            exit 1
        fi
        echo "switching models: stopping previous stack '$OLD' (freeing the GPU)"
        STAMP="$(date +%Y%m%d-%H%M%S)"
        OUT="docker/${STAMP}-litellm-db-${OLD}.sql"
        docker compose -p "$OLD" -f docker/docker-compose.local.yml exec -T litellm-db \
            pg_dump -U litellm -d litellm > "$OUT" 2>/dev/null \
            && echo "  litellm history saved -> $OUT" \
            || echo "  (no litellm-db to dump; continued)"
        docker compose -p "$OLD" -f docker/docker-compose.local.yml down --timeout 30 >/dev/null
    done
fi

# --- start the requested model ---------------------------------------------
MODEL="$MODEL" MODEL_SLUG="$SLUG" \
    docker compose -f docker/docker-compose.local.yml up -d --force-recreate

# --- wait until port 8881 actually answers -----------------------------------
# We poll the litellm HTTP port directly (not the compose healthcheck),
# because litellm's /health/liveliness also waits on tabbyapi finishing its
# model load, so the healthcheck flips to 'healthy' only AFTER the port has
# served requests for a while. This checks whether the endpoint is usable.
echo
echo "none" >/dev/null
WAITUP_PID=""
python3 - "$SLUG" <<'PY' &
import sys, time, urllib.request
slug = sys.argv[1]
url = "http://127.0.0.1:8881/v1/models"
deadline = time.time() + 60 * 20
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            if r.status == 200:
                sys.exit(0)
    except Exception:
        pass
    time.sleep(2)
sys.exit(1)
PY
WAITUP_PID=$!
echo "waiting for litellm to answer on http://localhost:8881 (this can exceed a minute while tabbyapi loads the EXL3 checkpoint)"
wait "$WAITUP_PID" && { echo "litellm is serving on :8881." ; } || { echo "error: litellm never answered on :8881; recent logs:" >&2; docker compose -p "$SLUG" -f docker/docker-compose.local.yml logs --tail 30 litellm >&2 || true; exit 1; }

echo
echo "============================================================"
echo " model       : $MODEL"
echo " weights     : $CKPT"
echo " endpoint    : http://localhost:8881/v1  (chat completions + /v1/responses)"
echo " litellm UI  : http://localhost:8881/ui"
echo " logs        : ./run.sh logs"
echo "============================================================"