#!/bin/bash
# =============================================================================
# wan22-plus.sh - self-contained Wan 2.2 image-to-video setup for RunPod.
#
# Use as the Wan template's SETUP_SCRIPT_URL. Replaces the AI Rebels wan22.sh
# (no longer downloads or depends on it) and adds your own extra models.
#
# Compared with the original:
#   - Downloads start the moment the pod boots, instead of waiting for
#     ComfyUI to finish starting. Files are staged on /workspace and moved
#     into ComfyUI as soon as its folder exists.
#   - At most MAX_PARALLEL downloads run at once (the original started all
#     nine together with no memory cap on Hugging Face's fast mode, which can
#     use a lot of RAM). A new download starts as soon as a slot frees up.
#   - Every download retries up to 3 times with a timeout, and failures are
#     reported clearly instead of being silently ignored.
#   - Custom node requirements are installed with ComfyUI's own Python (the
#     original used whatever "pip" came first, which may not be ComfyUI's).
#   - Your Civitai files download in the same queue.
#
# Template variables: CIVITAI_TOKEN (needed for Civitai files), HF_TOKEN (optional).
# Progress: Container log, or  tail -f /workspace/wan22-setup.log
# =============================================================================

COMFY_ROOT="${COMFY_ROOT:-/workspace/runpod-slim/ComfyUI}"
STAGING="${STAGING:-/workspace/wan22-downloads}"
LOG_FILE="${LOG_FILE:-/workspace/wan22-setup.log}"
CONSOLE="${CONSOLE:-/proc/1/fd/1}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8188}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-1800}"   # seconds per attempt

# -----------------------------------------------------------------------------
# Custom nodes: "folder name|git URL|branch (blank = default)"
# -----------------------------------------------------------------------------
NODES=(
  "ComfyUI-VideoHelperSuite|https://github.com/kosinkadink/ComfyUI-VideoHelperSuite|"
  # rgthree's default branch is stale; the creator pinned 'main'.
  "rgthree-comfy|https://github.com/rgthree/rgthree-comfy|main"
)

# -----------------------------------------------------------------------------
# Models: "download link|models subfolder"
# Hugging Face links (same files the original setup used) and Civitai links
# both work. Civitai files get their real name from Civitai.
# -----------------------------------------------------------------------------
HF=https://huggingface.co
FILES=(
  # Wan 2.2 image-to-video, the two 14B models (largest files go first)
  "$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors|diffusion_models"
  "$HF/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors|diffusion_models"
  # Text encoder and VAE
  "$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|text_encoders"
  "$HF/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors|vae"
  # LoRAs from the original setup
  "$HF/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors|loras"
  "$HF/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors|loras"
  "$HF/Kijai/WanVideo_comfy/resolve/main/LoRAs/VBVR/Wan22_I2V_VBVR_HIGH_rank_64_fp16.safetensors|loras"
  "$HF/skhaai/airebels/resolve/main/models/wan2.2_i2v_high_ulitmate_pussy_asshole.safetensors|loras"
  "$HF/skhaai/airebels/resolve/main/models/wan2.2_i2v_low_ulitmate_pussy_asshole.safetensors|loras"
  # Your extra LoRAs (Civitai)
  "https://civitai.red/api/download/models/2714033?fileId=2599688|loras"   # high noise
  "https://civitai.red/api/download/models/2714048?fileId=2599700|loras"   # low noise
  "https://civitai.red/api/download/models/2325788?fileId=2215936|loras"  #high noise
  "https://civitai.red/api/download/models/2191446?fileId=2084409|loras" #low noise
)

# =============================================================================
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
[ -w "$CONSOLE" ] || CONSOLE=/dev/null

(
  set -uo pipefail
  log() { echo "[wan22-plus] $*"; }
  START=$SECONDS
  log "-------------------------------------------------------"
  log "WAN 2.2 SETUP STARTED (${#FILES[@]} files, $MAX_PARALLEL at a time)"
  log "-------------------------------------------------------"

  # Keep Hugging Face's fast mode but cap its memory per download.
  export HF_XET_HIGH_PERFORMANCE=1
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_SIZE=4gb
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_PERFILE_SIZE=2gb
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_LIMIT=4gb
  export HF_HUB_DOWNLOAD_TIMEOUT=60

  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT=(timeout --kill-after=30 "$DOWNLOAD_TIMEOUT")
  else
    TIMEOUT=()
  fi
  rm -rf "$STAGING"; mkdir -p "$STAGING"
  FAILED_DIR="$(mktemp -d)"

  # ---- One download (Hugging Face or Civitai), up to 3 tries, into STAGING ----
  fetch() {
    local url="$1" sub="$2" n="$3"
    local dir="$STAGING/$sub" attempt start rc tmp name auth=()
    mkdir -p "$dir"
    case "$url" in
      https://civitai.com/*|https://civitai.red/*)
        [ -n "${CIVITAI_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $CIVITAI_TOKEN") \
          || log "WARNING: CIVITAI_TOKEN not set - Civitai may refuse $url" ;;
      https://huggingface.co/*)
        [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN") ;;
    esac
    for attempt in 1 2 3; do
      start=$SECONDS; rc=0
      tmp="$(mktemp -d "$dir/.dl.XXXXXX")"
      log "downloading [$n] $(basename "${url%%\?*}") (attempt $attempt/3)"
      case "$url" in
        https://huggingface.co/*)
          name="$(basename "$url")"
          if command -v hf >/dev/null 2>&1; then
            # Hugging Face's own downloader (faster). It reads HF_TOKEN itself.
            local repo path
            repo="$(echo "$url" | sed -E 's#https://huggingface.co/([^/]+/[^/]+)/.*#\1#')"
            path="$(echo "$url" | sed -E 's#https://huggingface.co/[^/]+/[^/]+/resolve/[^/]+/##')"
            "${TIMEOUT[@]}" hf download "$repo" "$path" --local-dir "$tmp/hf" >/dev/null 2>&1 \
              && mv -f "$tmp/hf/$path" "$tmp/$name" || rc=$?
            rm -rf "$tmp/hf"
          else
            (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -o "$name" "$url") || rc=$?
          fi ;;
        *)
          (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -J -O "$url") || rc=$?
          name="$(ls -1 "$tmp" 2>/dev/null | head -1)" ;;
      esac
      if [ "$rc" -eq 0 ] && [ -n "$name" ] && [ -s "$tmp/$name" ]; then
        mv -f "$tmp/$name" "$dir/$name"; rm -rf "$tmp"
        log "finished [$n] $name in $((SECONDS - start))s"
        return 0
      fi
      rm -rf "$tmp"
      case "$rc" in
        22)  log "[$n] refused (HTTP error) - check the link or token (attempt $attempt)" ;;
        124) log "[$n] timed out (attempt $attempt)" ;;
        *)   log "[$n] failed, curl exit $rc (attempt $attempt)" ;;
      esac
      sleep 5
    done
    log "WARNING: could not download [$n] $url"
    touch "$FAILED_DIR/$n"
    return 1
  }

  # ---- 1. Start downloads right away, MAX_PARALLEL at a time ----
  (
    n=0
    for e in "${FILES[@]}"; do
      while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do wait -n || true; done
      n=$((n + 1))
      fetch "${e%%|*}" "${e##*|}" "$n" &
    done
    wait || true
  ) &
  DOWNLOADS=$!

  # ---- 2. Meanwhile: wait for ComfyUI, then install the custom nodes ----
  log "waiting for ComfyUI to start (downloads continue meanwhile)..."
  for _ in $(seq 1 600); do curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && break; sleep 2; done
  if ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "ERROR: ComfyUI never started - giving up on node install and restart"
  fi

  # Use the same Python command that started ComfyUI (keeps its virtual
  # environment, unlike resolving the binary behind it).
  COMFY_PY=""
  pid="$(pgrep -f 'python[0-9.]* main\.py' | head -1)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    arg0="$(tr '\0' '\n' < "/proc/$pid/cmdline" | head -1)"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$COMFY_ROOT")"
    case "$arg0" in
      /*)  COMFY_PY="$arg0" ;;
      */*) COMFY_PY="$cwd/$arg0" ;;
      *)   COMFY_PY="$(command -v "$arg0" 2>/dev/null || true)" ;;
    esac
  fi
  [ -x "$COMFY_PY" ] || COMFY_PY="$COMFY_ROOT/.venv-cu128/bin/python"
  [ -x "$COMFY_PY" ] || COMFY_PY="$(command -v python3)"
  log "ComfyUI is up after $((SECONDS - START))s (Python: $COMFY_PY)"

  for e in "${NODES[@]}"; do
    IFS='|' read -r name url branch <<< "$e"
    dest="$COMFY_ROOT/custom_nodes/$name"
    if [ ! -d "$dest" ]; then
      log "installing node $name"
      if [ -n "$branch" ]; then git clone --quiet --branch "$branch" "$url" "$dest"
      else git clone --quiet "$url" "$dest"; fi || { log "WARNING: could not clone $name"; continue; }
    elif [ -n "$branch" ]; then
      git -C "$dest" fetch --quiet origin "$branch" \
        && git -C "$dest" checkout --quiet -B "$branch" "origin/$branch" \
        || log "WARNING: could not switch $name to $branch, keeping existing copy"
    fi
    if [ -f "$dest/requirements.txt" ]; then
      "$COMFY_PY" -m pip install -q -r "$dest/requirements.txt" \
        && log "$name requirements installed" \
        || log "WARNING: $name requirements failed to install"
    fi
  done

  # ---- 3. Wait for downloads, then move them into ComfyUI ----
  log "nodes done; waiting for downloads to finish..."
  wait "$DOWNLOADS" || true
  (cd "$STAGING" && find . -type f ! -path '*/.dl.*' -print0) | while IFS= read -r -d '' f; do
    mkdir -p "$COMFY_ROOT/models/$(dirname "$f")"
    mv -f "$STAGING/$f" "$COMFY_ROOT/models/$f"
  done
  rm -rf "$STAGING"
  FAILED=$(ls "$FAILED_DIR" | wc -l); rm -rf "$FAILED_DIR"
  log "models in place after $((SECONDS - START))s ($FAILED failed)"

  # ---- 4. Restart ComfyUI so it loads the new nodes ----
  ARGS_FILE="$(dirname "$COMFY_ROOT")/comfyui_args.txt"
  if [ -f "$ARGS_FILE" ] && ! grep -q "enable-cors-header" "$ARGS_FILE"; then
    echo "--enable-cors-header" >> "$ARGS_FILE"
  fi
  log "restarting ComfyUI to load the nodes..."
  pkill -f 'python[0-9.]* main\.py' || true
  sleep 3
  (cd "$COMFY_ROOT" && "$COMFY_PY" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header \
     >> "$CONSOLE" 2>&1 &)
  for _ in $(seq 1 300); do curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && break; sleep 2; done

  log "-------------------------------------------------------"
  if [ "$FAILED" -gt 0 ]; then
    log "SETUP DONE WITH $FAILED FAILED DOWNLOAD(S) in $((SECONDS - START))s - see WARNING lines"
  else
    log "SETUP COMPLETE - WAN 2.2 READY in $((SECONDS - START))s"
  fi
  log "-------------------------------------------------------"
) 2>&1 | tee -a "$LOG_FILE" >> "$CONSOLE" &

echo "[wan22-plus] setup running in the background (tail -f $LOG_FILE)"
exit 0
