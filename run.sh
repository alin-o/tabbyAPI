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
    status)
        echo "=== compose projects ==="
        docker compose ls 2>/dev/null || true
        echo
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

echo
echo "============================================================"
echo " model       : $MODEL"
echo " weights     : $CKPT"
echo " endpoint    : http://localhost:8881/v1  (chat completions + /v1/responses)"
echo " litellm UI  : http://localhost:8881/ui"
echo " logs        : MODEL=$MODEL MODEL_SLUG=$SLUG docker compose -f docker/docker-compose.local.yml logs -f"
echo "============================================================"