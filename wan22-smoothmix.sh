#!/bin/bash
# =============================================================================
# wan22-smoothmix.sh - Wan 2.2 image-to-video setup for RunPod, using the
# Smooth Mix I2V v2.0 models instead of the stock Wan 2.2 14B models.
#
# Use as the Smooth Mix template's SETUP_SCRIPT_URL; pair it with
# Wan22-FLF-SmoothMix-workflow. The regular template uses wan22-plus.sh.
# Replaces the AI Rebels wan22.sh
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
#   - Checks that ComfyUI loaded the nodes the workflows use, including
#     KJNodes' Color Match V2 for matching colors across stitched clips.
#   - "SETUP COMPLETE" only appears if every download and node install worked,
#     ComfyUI came back after the restart, and it really loaded the nodes.
#     Otherwise the log ends with "SETUP FINISHED WITH n PROBLEM(S)" and a list.
#
# Template variables: CIVITAI_TOKEN (needed for Civitai files), HF_TOKEN (optional).
# Progress: Container log, or  tail -f /workspace/wan22-smoothmix-setup.log
# =============================================================================

COMFY_ROOT="${COMFY_ROOT:-/workspace/runpod-slim/ComfyUI}"
STAGING="${STAGING:-/workspace/wan22-downloads}"
LOG_FILE="${LOG_FILE:-/workspace/wan22-smoothmix-setup.log}"
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
  # Provides ImageResizeKJv2, used by both workflows.
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes|"
)

# -----------------------------------------------------------------------------
# Models: "download link|models subfolder|file name (optional)"
# Hugging Face links (same files the original setup used) and Civitai links
# both work. Civitai files get their real name from Civitai unless you set a
# file name, which lets a workflow point at the file before it is downloaded.
# -----------------------------------------------------------------------------
HF=https://huggingface.co
# Finds the ComfyUI process however it was launched: python main.py,
# python -u main.py, python /path/to/main.py, and so on.
COMFY_MATCH='python[0-9.]*( [^ ]+)* ([^ ]*/)?main\.py'
FILES=(
  # Smooth Mix Wan 2.2 I2V v2.0 - the main models (largest files go first)
  "https://civitai.red/api/download/models/2513182?fileId=2460270|diffusion_models|smoothmix-wan22-i2v-v2-high.safetensors"
  "https://civitai.red/api/download/models/2513186?fileId=2460676|diffusion_models|smoothmix-wan22-i2v-v2-low.safetensors"
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
  "https://civitai.red/api/download/models/2325788?fileId=2215936|loras|wan22-ultimatedeepthroat-i2v-102epoc-high-k3nk.safetensors"
  "https://civitai.red/api/download/models/2191446?fileId=2084409|loras|wan22-ultimatedeepthroat-I2V-101epoc-low-k3nk.safetensors"
  # Wan 2.1 Lightx2v speed LoRA the Smooth Mix creator uses (3.0 high, 1.5 low)
  "$HF/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank128_bf16.safetensors|loras"
)

# =============================================================================
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
[ -w "$CONSOLE" ] || CONSOLE=/dev/null

(
  set -uo pipefail
  log() { echo "[wan22-smoothmix] $*"; }
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
    local url="$1" sub="$2" n="$3" fixed="${4:-}"
    local dir="$STAGING/$sub" attempt start rc tmp name tool auth=()
    mkdir -p "$dir"
    case "$url" in
      https://civitai.com/*|https://civitai.red/*)
        [ -n "${CIVITAI_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $CIVITAI_TOKEN") \
          || log "WARNING: CIVITAI_TOKEN not set - Civitai may refuse $url" ;;
      https://huggingface.co/*)
        [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN") ;;
    esac
    for attempt in 1 2 3; do
      start=$SECONDS; rc=0; tool=curl
      tmp="$(mktemp -d "$dir/.dl.XXXXXX")"
      log "downloading [$n] $(basename "${url%%\?*}") (attempt $attempt/3)"
      case "$url" in
        https://huggingface.co/*)
          name="$(basename "$url")"
          # Hugging Face's own downloader is faster, so try it first. It reads
          # HF_TOKEN itself. The last attempt always uses curl as a fallback.
          if [ "$attempt" -lt 3 ] && command -v hf >/dev/null 2>&1; then
            tool=hf
            local repo path
            repo="$(echo "$url" | sed -E 's#https://huggingface.co/([^/]+/[^/]+)/.*#\1#')"
            path="$(echo "$url" | sed -E 's#https://huggingface.co/[^/]+/[^/]+/resolve/[^/]+/##')"
            "${TIMEOUT[@]}" hf download "$repo" "$path" --local-dir "$tmp/hf" >"$tmp/hf.log" 2>&1 \
              && mv -f "$tmp/hf/$path" "$tmp/$name" || rc=$?
            if [ "$rc" -ne 0 ]; then
              tail -n 3 "$tmp/hf.log" 2>/dev/null | while IFS= read -r line; do log "[$n] hf: $line"; done
            fi
            rm -rf "$tmp/hf" "$tmp/hf.log"
          else
            (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -o "$name" "$url") || rc=$?
          fi ;;
        *)
          if [ -n "$fixed" ]; then
            (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -o "$fixed" "$url") || rc=$?
            name="$fixed"
          else
            (cd "$tmp" && "${TIMEOUT[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -J -O "$url") || rc=$?
            name="$(ls -1 "$tmp" 2>/dev/null | head -1)"
          fi ;;
      esac
      if [ "$rc" -eq 0 ] && [ -n "$name" ] && [ -s "$tmp/$name" ]; then
        mv -f "$tmp/$name" "$dir/$name"; rm -rf "$tmp"
        log "finished [$n] $name in $((SECONDS - start))s"
        return 0
      fi
      rm -rf "$tmp"
      case "$tool:$rc" in
        curl:22)     log "[$n] refused (HTTP error) - check the link or token (attempt $attempt)" ;;
        *:124|*:137) log "[$n] timed out (attempt $attempt)" ;;
        *)           log "[$n] failed, $tool exit $rc (attempt $attempt)" ;;
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
      IFS='|' read -r f_url f_sub f_name <<< "$e"
      fetch "$f_url" "$f_sub" "$n" "$f_name" &
    done
    wait || true
  ) &
  DOWNLOADS=$!

  # ---- 2. Meanwhile: wait for ComfyUI, then install the custom nodes ----
  log "waiting for ComfyUI to start (downloads continue meanwhile)..."
  for _ in $(seq 1 600); do curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && break; sleep 2; done
  PROBLEMS=()
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "ComfyUI is up after $((SECONDS - START))s"
  else
    log "ERROR: ComfyUI did not answer after 20 minutes - will still install nodes and models, then try to start it"
    PROBLEMS+=("ComfyUI did not start on its own")
  fi

  # Use the same Python command that started ComfyUI (keeps its virtual
  # environment, unlike resolving the binary behind it).
  COMFY_PY=""
  pid="$(pgrep -f "$COMFY_MATCH" | head -1)"
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
  log "using Python: $COMFY_PY"

  for e in "${NODES[@]}"; do
    IFS='|' read -r name url branch <<< "$e"
    dest="$COMFY_ROOT/custom_nodes/$name"
    if [ ! -d "$dest" ]; then
      log "installing node $name"
      if [ -n "$branch" ]; then git clone --quiet --branch "$branch" "$url" "$dest"
      else git clone --quiet "$url" "$dest"; fi || {
        log "WARNING: could not clone $name"
        PROBLEMS+=("node $name was not installed")
        continue
      }
    elif [ -n "$branch" ]; then
      git -C "$dest" fetch --quiet origin "$branch" \
        && git -C "$dest" checkout --quiet -B "$branch" "origin/$branch" \
        || log "WARNING: could not switch $name to $branch, keeping existing copy"
    fi
    if [ -f "$dest/requirements.txt" ]; then
      "$COMFY_PY" -m pip install -q -r "$dest/requirements.txt" \
        && log "$name requirements installed" \
        || { log "WARNING: $name requirements failed to install"; PROBLEMS+=("node $name requirements failed"); }
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
  # Keep any extra arguments from the template's args file on the restart.
  EXTRA_ARGS=()
  if [ -f "$ARGS_FILE" ]; then
    while read -r -a words; do
      case "${words[0]:-}" in ''|\#*) continue ;; esac
      for w in "${words[@]}"; do
        case " --listen 0.0.0.0 --port 8188 --enable-cors-header " in
          *" $w "*) ;;
          *) EXTRA_ARGS+=("$w") ;;
        esac
      done
    done < "$ARGS_FILE"
  fi

  log "restarting ComfyUI to load the nodes..."
  pkill -f "$COMFY_MATCH" || true
  for _ in $(seq 1 30); do pgrep -f "$COMFY_MATCH" >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -f "$COMFY_MATCH" >/dev/null 2>&1; then
    log "ComfyUI did not stop in 30s - forcing it"
    pkill -9 -f "$COMFY_MATCH" || true
    sleep 2
  fi
  # A leftover process on the port would answer the health check with the old nodes.
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "WARNING: something is still answering on port 8188 after the stop"
    PROBLEMS+=("the old ComfyUI could not be stopped, so new nodes may not be loaded")
  fi
  (cd "$COMFY_ROOT" && "$COMFY_PY" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header "${EXTRA_ARGS[@]}" \
     >> "$CONSOLE" 2>&1 &)
  UP=0
  for _ in $(seq 1 300); do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then UP=1; break; fi
    sleep 2
  done

  # ---- 5. Check the result: ComfyUI answers, and it really loaded the nodes ----
  if [ "$UP" -eq 1 ]; then
    INFO="$(curl -fsS "$HEALTH_URL/object_info" 2>/dev/null || true)"
    for node in "VHS_VideoCombine" "Power Lora Loader (rgthree)" "ImageResizeKJv2" "ColorMatchV2"; do
      case "$INFO" in
        *"\"$node\""*) log "node check OK: $node" ;;
        *) log "WARNING: ComfyUI did not load node: $node"
           PROBLEMS+=("ComfyUI did not load $node") ;;
      esac
    done
  else
    log "ERROR: ComfyUI did not come back after the restart (10 minutes)"
    PROBLEMS+=("ComfyUI did not come back after the restart")
  fi
  [ "$FAILED" -gt 0 ] && PROBLEMS+=("$FAILED download(s) failed")

  log "-------------------------------------------------------"
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    log "SETUP FINISHED WITH ${#PROBLEMS[@]} PROBLEM(S) in $((SECONDS - START))s:"
    for p in "${PROBLEMS[@]}"; do log "  - $p"; done
  else
    log "SETUP COMPLETE - WAN 2.2 READY in $((SECONDS - START))s"
  fi
  log "-------------------------------------------------------"
) 2>&1 | tee -a "$LOG_FILE" >> "$CONSOLE" &

echo "[wan22-smoothmix] setup running in the background (tail -f $LOG_FILE)"
exit 0
