#!/bin/bash
# =============================================================================
# wan22-plus.sh - the AI Rebels Wan 2.2 setup, plus your own extra models.
#
# Use it as the Wan template's SETUP_SCRIPT_URL (in place of wan22.sh):
#   1. Runs the creator's original wan22.sh exactly as before (it downloads the
#      Wan models and nodes in the background).
#   2. Downloads your extra Civitai files in the background too, into
#      ComfyUI's models folders on /workspace (kept when a pod is stopped).
#      Files already downloaded are skipped.
#
# Needs CIVITAI_TOKEN set in the template (your Civitai API key).
# Progress: Container log, or  tail -f /workspace/wan22-extras.log
# =============================================================================

ORIGINAL_SCRIPT_URL="${ORIGINAL_SCRIPT_URL:-https://raw.githubusercontent.com/samh-ai/AI-Rebels-config/main/scripts/wan22.sh}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/runpod-slim/ComfyUI}"
LOG_FILE="${LOG_FILE:-/workspace/wan22-extras.log}"
CONSOLE="${CONSOLE:-/proc/1/fd/1}"

# -----------------------------------------------------------------------------
# Your extra files: "Civitai download link|models subfolder"
# The real filename comes from Civitai when it downloads.
# -----------------------------------------------------------------------------
EXTRA_FILES=(
  "https://civitai.red/api/download/models/2714033?fileId=2599688|loras"   # high noise
  "https://civitai.red/api/download/models/2714048?fileId=2599700|loras"   # low noise
  "https://civitai.red/api/download/models/2325788?fileId=2215936|loras"   # high noise
  "https://civitai.red/api/download/models/2191446?fileId=2084409|loras"   # low noise
)

# --- 1. The creator's original setup ---------------------------------------------
echo "[wan22-plus] running the original Wan 2.2 setup from $ORIGINAL_SCRIPT_URL"
if (curl -fsSL "$ORIGINAL_SCRIPT_URL" || wget -qO- "$ORIGINAL_SCRIPT_URL") > /tmp/wan22-original.sh 2>/dev/null \
   && [ -s /tmp/wan22-original.sh ]; then
  bash /tmp/wan22-original.sh
else
  echo "[wan22-plus] WARNING: could not download the original wan22.sh - Wan models won't be set up"
fi

# --- 2. Your extra files, in the background ----------------------------------------
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
[ -w "$CONSOLE" ] || CONSOLE=/dev/null

(
  log() { echo "[wan22-plus] $*"; }

  log "waiting for ComfyUI's folder ($COMFY_ROOT)..."
  for _ in $(seq 1 300); do [ -d "$COMFY_ROOT/models" ] && break; sleep 2; done
  if [ ! -d "$COMFY_ROOT/models" ]; then
    log "WARNING: ComfyUI folder never appeared - extra files not downloaded"; exit 0
  fi

  if [ -z "${CIVITAI_TOKEN:-}" ]; then
    log "WARNING: CIVITAI_TOKEN is not set in the template - Civitai may refuse these downloads"
    AUTH=()
  else
    AUTH=(-H "Authorization: Bearer $CIVITAI_TOKEN")
  fi

  if command -v timeout >/dev/null 2>&1; then TIMEOUT=(timeout --kill-after=30 1800); else TIMEOUT=(); fi

  fetch() {
    local url="$1" dir="$COMFY_ROOT/models/$2"
    local id; id="$(echo "$url" | sed -E 's#.*/models/([0-9]+).*#\1#')"
    local marker="$dir/.civitai-$id"
    mkdir -p "$dir"
    if [ -f "$marker" ] && [ -s "$dir/$(cat "$marker")" ]; then
      log "already have $(cat "$marker") (Civitai $id)"; return 0
    fi
    local attempt tmp name rc start
    for attempt in 1 2 3; do
      start=$SECONDS; rc=0
      log "downloading Civitai $id (attempt $attempt/3)"
      tmp="$(mktemp -d "$dir/.dl.XXXXXX")"
      (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${AUTH[@]}" -J -O "$url") || rc=$?
      name="$(ls -1 "$tmp" 2>/dev/null | head -1)"
      if [ "$rc" -eq 0 ] && [ -n "$name" ] && [ -s "$tmp/$name" ]; then
        mv -f "$tmp/$name" "$dir/$name"; rm -rf "$tmp"
        echo "$name" > "$marker"
        log "finished $name (Civitai $id) in $((SECONDS - start))s"; return 0
      fi
      rm -rf "$tmp"
      if [ "$rc" -eq 22 ]; then log "Civitai refused $id - check CIVITAI_TOKEN (attempt $attempt)"
      else log "attempt $attempt failed for Civitai $id (curl exit $rc)"; fi
      sleep 5
    done
    log "WARNING: could not download Civitai $id"; return 1
  }

  failed=0
  for e in "${EXTRA_FILES[@]}"; do
    fetch "${e%%|*}" "${e##*|}" || failed=$((failed + 1))
  done
  if [ "$failed" -eq 0 ]; then
    log "EXTRAS DONE - all extra files are in place (refresh ComfyUI's LoRA lists if they're not showing yet)"
  else
    log "EXTRAS DONE with $failed failed download(s) - see WARNING lines above"
  fi
) 2>&1 | tee -a "$LOG_FILE" >> "$CONSOLE" &

echo "[wan22-plus] extra downloads started in the background (tail -f $LOG_FILE)"
exit 0
