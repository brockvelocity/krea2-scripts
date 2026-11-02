#!/bin/bash
set -euo pipefail

LOG_FILE="/workspace/krea2v2-background.log"
# If the log file can't be created (e.g. /workspace not mounted yet), fall back
# to /dev/null so tee never kills the watcher.
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

(
  set -euo pipefail

  COMFY_ROOT="/workspace/runpod-slim/ComfyUI"
  CUSTOM_NODES_DIR="$COMFY_ROOT/custom_nodes"
  RGTHREE_NODE_DIR="$CUSTOM_NODES_DIR/rgthree-comfy"
  RES4LYF_NODE_DIR="$CUSTOM_NODES_DIR/RES4LYF"
  KREA2EDIT_NODE_DIR="$CUSTOM_NODES_DIR/comfyui-krea2edit"
  LANPAINT_NODE_DIR="$CUSTOM_NODES_DIR/LanPaint"
  MODELS_DIR="$COMFY_ROOT/models"
  TMP_DIR="/workspace/hf-downloads"
  HEALTH_URL="http://127.0.0.1:8188"

  source <(curl -fsSL "https://raw.githubusercontent.com/samh-ai/AI-Rebels-config/main/registry.sh")

  # Keep Xet's aggressive internal transfer concurrency, but bound its buffers and run
  # only two model-file downloads at a time. High-performance Xet otherwise permits up
  # to 64GB of buffering per hf process, which can OOM pods with a 28GB RAM limit.
  export HF_HUB_ENABLE_HF_TRANSFER=1
  export HF_XET_HIGH_PERFORMANCE=1
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_SIZE=4gb
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_PERFILE_SIZE=2gb
  export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_LIMIT=4gb
  export HF_HUB_DOWNLOAD_TIMEOUT=60
  MAX_PARALLEL_DOWNLOADS=2

  # Belt-and-suspenders even with xet disabled: HF_HUB_DOWNLOAD_TIMEOUT only bounds the
  # HTTP read timeout, not the whole `hf download` process, so a stuck download could still
  # hang the script indefinitely otherwise. Same fix as clone_node: wrap in `timeout
  # --kill-after` (plain `timeout N` only sends SIGTERM at N and then waits for the child -
  # if the child ignores it, timeout blocks forever too; measured elsewhere in this script).
  # 3 attempts, since huggingface_hub resumes partial local-dir downloads from where they
  # left off rather than restarting, so a retry after a timeout is cheap, not a full redo.
  DOWNLOAD_TIMEOUT=600
  DOWNLOAD_KILL_GRACE=30
  if command -v timeout >/dev/null 2>&1; then
    DL_TIMEOUT_CMD="timeout --kill-after=$DOWNLOAD_KILL_GRACE $DOWNLOAD_TIMEOUT"
    DOWNLOAD_LIMIT_DESC="${DOWNLOAD_TIMEOUT}s timeout, SIGKILL at $((DOWNLOAD_TIMEOUT + DOWNLOAD_KILL_GRACE))s"
  else
    DL_TIMEOUT_CMD=""
    DOWNLOAD_LIMIT_DESC="NO TIMEOUT - 'timeout' not found on PATH"
  fi

  download_hf_file() {
    local url="$1"
    local dest_dir="$2"
    local repo repo_path filename dl_tmp attempt rc start
    repo="$(echo "$url" | sed -E 's#https://huggingface.co/([^/]+/[^/]+)/.*#\1#')"
    repo_path="$(echo "$url" | sed -E 's#https://huggingface.co/[^/]+/[^/]+/resolve/[^/]+/##')"
    filename="$(basename "$url")"
    dl_tmp="$TMP_DIR/$filename"
    mkdir -p "$dest_dir" "$dl_tmp"
    for attempt in 1 2 3; do
      echo "Downloading: $url (attempt $attempt/3, $DOWNLOAD_LIMIT_DESC)"
      start=$SECONDS
      rc=0
      $DL_TIMEOUT_CMD hf download "$repo" "$repo_path" --local-dir "$dl_tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then
        mv -f "$dl_tmp/$repo_path" "$dest_dir/$filename"
        echo "Finished: $filename in $((SECONDS - start))s (attempt $attempt/3)."
        return 0
      fi
      case "$rc" in
        124) echo "Download of $filename TIMED OUT after $((SECONDS - start))s (attempt $attempt/3)." ;;
        137) echo "Download of $filename ignored SIGTERM, SIGKILLed after $((SECONDS - start))s (attempt $attempt/3)." ;;
        *)   echo "Download of $filename FAILED, hf exit $rc after $((SECONDS - start))s (attempt $attempt/3)." ;;
      esac
    done
    echo "Download of $filename failed after 3 attempts."
    return 1
  }

  # Civitai (civitai.com / civitai.red) downloads. These need an API token, which is
  # read from the CIVITAI_TOKEN environment variable set in the RunPod template, so
  # it never appears in this public script. The token is sent as a header, not in
  # the URL, so it stays out of logs; curl drops it when following the redirect to
  # Civitai's storage server, which doesn't need it. The real filename comes from
  # the server's response (-J), so entries only need the download link.
  download_civitai_file() {
    local url="$1"
    local dest_dir="$2"
    local dl_tmp attempt rc start filename auth_args=()
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      auth_args=(-H "Authorization: Bearer $CIVITAI_TOKEN")
    else
      echo "WARNING: CIVITAI_TOKEN is not set in the template; Civitai download may be refused: $url"
    fi
    dl_tmp="$(mktemp -d "$TMP_DIR/civitai.XXXXXX")"
    mkdir -p "$dest_dir"
    for attempt in 1 2 3; do
      echo "Downloading (Civitai): $url (attempt $attempt/3, $DOWNLOAD_LIMIT_DESC)"
      start=$SECONDS
      rm -rf "${dl_tmp:?}"/*
      rc=0
      (cd "$dl_tmp" && $DL_TIMEOUT_CMD curl -fsSL --retry 2 --connect-timeout 30 \
        "${auth_args[@]}" -J -O "$url") || rc=$?
      if [ "$rc" -eq 0 ]; then
        filename="$(ls -1 "$dl_tmp" | head -1)"
        if [ -z "$filename" ]; then
          echo "Civitai download of $url produced no file (attempt $attempt/3)."
          continue
        fi
        mv -f "$dl_tmp/$filename" "$dest_dir/$filename"
        echo "Finished: $filename in $((SECONDS - start))s (attempt $attempt/3)."
        rm -rf "$dl_tmp"
        return 0
      fi
      case "$rc" in
        22)  echo "Civitai refused $url (HTTP error) - check that CIVITAI_TOKEN is set and valid (attempt $attempt/3)." ;;
        124) echo "Civitai download of $url TIMED OUT after $((SECONDS - start))s (attempt $attempt/3)." ;;
        137) echo "Civitai download of $url SIGKILLed after $((SECONDS - start))s (attempt $attempt/3)." ;;
        *)   echo "Civitai download of $url FAILED, curl exit $rc after $((SECONDS - start))s (attempt $attempt/3)." ;;
      esac
    done
    rm -rf "$dl_tmp"
    echo "Civitai download of $url failed after 3 attempts."
    return 1
  }

  # Pick the right downloader for each link.
  download_file() {
    case "$1" in
      https://huggingface.co/*) download_hf_file "$1" "$2" ;;
      https://civitai.com/*|https://civitai.red/*) download_civitai_file "$1" "$2" ;;
      *) echo "Don't know how to download $1 (only Hugging Face and Civitai links are supported)."; return 1 ;;
    esac
  }

  echo "-------------------------------------------------------"
  echo "BACKGROUND WATCHER STARTED: KREA2 V2 CONFIG"
  echo "-------------------------------------------------------"

  echo "Waiting for ComfyUI root to exist..."
  for i in $(seq 1 300); do
    if [ -d "$COMFY_ROOT" ]; then break; fi
    sleep 2
  done

  if [ ! -d "$COMFY_ROOT" ]; then
    echo "Timed out waiting for ComfyUI root: $COMFY_ROOT"
    exit 1
  fi

  # Change 4: don't wait for the ComfyUI server before downloading. Model downloads
  # only need the ComfyUI folder in place, so wait just until the ComfyUI process
  # has been launched (by then the workspace copy is done), then start downloading
  # in the background while ComfyUI finishes booting and the custom nodes install.
  echo "Waiting for the ComfyUI process to launch..."
  for i in $(seq 1 300); do
    if pgrep -f 'main\.py' >/dev/null 2>&1; then break; fi
    sleep 2
  done

  # RunPod runs ComfyUI from system python on the cuda12.8 image and from .venv-cu128
  # on older ones. Follow whichever interpreter is actually serving 8188 so node
  # requirements and the restart at the end land in the same environment.
  COMFY_PY="$(readlink -f "/proc/$(pgrep -f 'main\.py' | head -1)/exe" 2>/dev/null || true)"
  if [ ! -x "$COMFY_PY" ]; then
    COMFY_PY="$COMFY_ROOT/.venv-cu128/bin/python"
  fi
  echo "Using interpreter: $COMFY_PY"

  if ! command -v hf >/dev/null 2>&1; then
    "$COMFY_PY" -m pip install -q -U "huggingface_hub[hf_transfer]"
  fi

  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  DOWNLOAD_FAILED_MARKER="$TMP_DIR/.download-failed"

  # Limit simultaneous hf processes, not Xet's internal transfer streams. Each process
  # retains high-performance Xet behavior while its memory use is capped above.
  #
  # Customized list: removed darkBeast, krea2_turbo, krea2_identity_edit_v1_2 and
  # krea2-bloomgirls-realism; added lenovo_krea2_3000 (Danrisi/Lenovo_Krea2).
  ALL_DOWNLOAD_QUEUE=(
    "${HF_MODELS[museByStableYogi_v35Int8Extended.safetensors]}|$MODELS_DIR/diffusion_models"
    "${HF_MODELS[qwen3vl_4b_fp8_scaled.safetensors]}|$MODELS_DIR/text_encoders"
    "${HF_MODELS[realism_engine_krea2_v2.safetensors]}|$MODELS_DIR/loras"
    "${HF_MODELS[K_excessivecum.safetensors]}|$MODELS_DIR/loras"
    "${HF_MODELS[snofs_krea_v1_4.safetensors]}|$MODELS_DIR/loras"
    "${HF_MODELS[realism_engine_krea2_v3.1.safetensors]}|$MODELS_DIR/loras"
    "${HF_MODELS[RealisticSnapshotKrea2.safetensors]}|$MODELS_DIR/loras"
    "https://huggingface.co/Danrisi/Lenovo_Krea2/resolve/main/lenovo_krea2_3000.safetensors|$MODELS_DIR/loras"
    "https://civitai.red/api/download/models/3159319?fileId=3039850|$MODELS_DIR/loras"
    "https://civitai.red/api/download/models/3415772?fileId=3308666|$MODELS_DIR/loras"
    "https://civitai.red/api/download/models/3103914?fileId=2983719|$MODELS_DIR/loras"
    "https://civitai.red/api/download/models/3337902?fileId=3224455|$MODELS_DIR/loras"
    "${HF_MODELS[qwen_image_vae.safetensors]}|$MODELS_DIR/vae"
  )

  # Change 3: a rolling download pool. Instead of downloading in pairs and waiting
  # for both to finish, start the next file as soon as any running download ends,
  # so MAX_PARALLEL_DOWNLOADS slots stay busy the whole time. A failed download
  # leaves a marker file, checked once everything has finished.
  run_downloads() {
    local entry
    echo "Downloading ${#ALL_DOWNLOAD_QUEUE[@]} files (max $MAX_PARALLEL_DOWNLOADS at once)..."
    for entry in "${ALL_DOWNLOAD_QUEUE[@]}"; do
      while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL_DOWNLOADS" ]; do
        wait -n || true
      done
      ( download_file "${entry%%|*}" "${entry##*|}" || touch "$DOWNLOAD_FAILED_MARKER" ) &
    done
    wait || true
    if [ -e "$DOWNLOAD_FAILED_MARKER" ]; then
      echo "One or more model downloads failed."
      return 1
    fi
    echo "All ${#ALL_DOWNLOAD_QUEUE[@]} model downloads finished."
    return 0
  }

  run_downloads &
  DOWNLOADS_PID=$!

  echo "Waiting for ComfyUI server on 8188..."
  for i in $(seq 1 600); do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then break; fi
    sleep 2
  done

  if ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "Timed out waiting for ComfyUI server: $HEALTH_URL"
    kill "$DOWNLOADS_PID" 2>/dev/null || true
    exit 1
  fi

  echo "ComfyUI is live at $(git -C "$COMFY_ROOT" describe --tags 2>/dev/null || echo unknown)."
  echo "No core update needed (image bakes a current ComfyUI). Installing custom node(s) while models download..."

  # A pod missing a node is unusable and has to be redeployed, so fail fast and loud
  # rather than spending 20 more minutes downloading models nobody will use.
  # CLONE_TIMEOUT caps the stall: a bad host once hung a clone for 12 minutes before
  # erroring out. HTTP/1.1 avoids the HTTP/2 "curl 92 stream not closed cleanly" failure.
  #
  # Deliberately NOT a shallow clone. --depth 1 saved nothing here (RES4LYF is ~250MB
  # packed and its bulk is blobs at HEAD, not history) while forcing the server to build
  # a custom pack without reachability bitmaps - a long pre-transfer stall that GitHub
  # documents as more expensive than a full fetch, and the likely trigger for the
  # "fetch-pack: unexpected disconnect while reading sideband packet" on attempt 1.
  CLONE_TIMEOUT=1200
  CLONE_KILL_GRACE=30
  if command -v timeout >/dev/null 2>&1; then
    # --kill-after is not optional. Plain `timeout N` only sends SIGTERM at N and then
    # blocks waiting for the child; if the child does not die from SIGTERM it waits
    # forever, so it caps nothing. Measured: `timeout 3` against a SIGTERM-ignoring child
    # returned after 60s, not 3s. That is what left a res4lyf clone silent for 12+ minutes
    # past a 240s "timeout". --kill-after escalates to SIGKILL so the bound is real.
    TIMEOUT_CMD="timeout --kill-after=$CLONE_KILL_GRACE $CLONE_TIMEOUT"
    CLONE_LIMIT_DESC="${CLONE_TIMEOUT}s timeout, SIGKILL at $((CLONE_TIMEOUT + CLONE_KILL_GRACE))s"
  else
    # Never claim a timeout we are not applying - the old code printed "240s timeout"
    # even in this branch, which made an uncapped hang impossible to diagnose from the log.
    TIMEOUT_CMD=""
    CLONE_LIMIT_DESC="NO TIMEOUT - 'timeout' not found on PATH"
  fi

  die() {
    echo "======================================================="
    echo "SETUP FAILED: $1"
    echo "Nothing further will run. Redeploy the pod."
    echo "Failed after $((SECONDS / 60))m$((SECONDS % 60))s."
    echo "======================================================="
    if [ -n "${DOWNLOADS_PID:-}" ]; then pkill -P "$DOWNLOADS_PID" 2>/dev/null || true; kill "$DOWNLOADS_PID" 2>/dev/null || true; fi
    exit 1
  }

  # Trailing args (if any) are top-level directory names to exclude via a partial
  # clone + sparse-checkout, instead of a normal full clone. Use this for repos that
  # bundle large example/doc assets nothing at runtime imports - e.g. RES4LYF is
  # 216MB, of which 212MB (98%) is example_workflows/ and workflows/ screenshots;
  # neither __init__.py nor web/js references either dir. --filter=blob:none means
  # git never transfers blobs for excluded paths at all (this is not the --depth 1
  # shallow clone already ruled out above - that still forces a full custom pack on
  # GitHub's side; blob filtering shrinks the pack itself). Measured against the real
  # repo: 2.9s and 5.6MB instead of the multi-minute stall that was timing out here.
  clone_node() {
    local name="$1" url="$2" dest="$3"; shift 3
    local sparse_exclude=("$@")
    if [ -d "$dest" ]; then
      echo "$name already present, skipping clone."
      return 0
    fi
    local attempt rc start sparse_pattern p
    for attempt in 1 2; do
      if [ "${#sparse_exclude[@]}" -gt 0 ]; then
        echo "Cloning $name sparse, excluding [${sparse_exclude[*]}] (attempt $attempt/2, $CLONE_LIMIT_DESC)..."
      else
        echo "Cloning $name (attempt $attempt/2, $CLONE_LIMIT_DESC)..."
      fi
      start=$SECONDS
      rc=0
      if [ "${#sparse_exclude[@]}" -gt 0 ]; then
        sparse_pattern="/*"
        for p in "${sparse_exclude[@]}"; do sparse_pattern="$sparse_pattern
!/$p/"; done
        # Whole clone+sparse-checkout+checkout sequence runs under one timeout, same
        # "never hang forever" guarantee as the plain-clone path below.
        $TIMEOUT_CMD bash -c '
          set -e
          git -c http.version=HTTP/1.1 clone --quiet --filter=blob:none --no-checkout --sparse "$1" "$2"
          git -C "$2" sparse-checkout init --no-cone
          printf "%s\n" "$3" > "$2/.git/info/sparse-checkout"
          git -C "$2" checkout --quiet
        ' _ "$url" "$dest" "$sparse_pattern" || rc=$?
      else
        $TIMEOUT_CMD git -c http.version=HTTP/1.1 clone --quiet "$url" "$dest" || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        echo "Cloned $name in $((SECONDS - start))s ($(du -sh "$dest" 2>/dev/null | cut -f1))."
        return 0
      fi
      # Say which failure this was. The old code printed one message for every case, so a
      # timeout and a git error were indistinguishable in the log.
      case "$rc" in
        124) echo "Clone of $name TIMED OUT after $((SECONDS - start))s (attempt $attempt/2)." ;;
        137) echo "Clone of $name ignored SIGTERM, SIGKILLed after $((SECONDS - start))s (attempt $attempt/2)." ;;
        *)   echo "Clone of $name FAILED, git exit $rc after $((SECONDS - start))s (attempt $attempt/2)." ;;
      esac
      rm -rf "$dest"
    done
    die "could not clone $name after 2 attempts"
  }

  install_node_reqs() {
    local name="$1" dir="$2"
    if [ -f "$dir/requirements.txt" ]; then
      "$COMFY_PY" -m pip install -q -r "$dir/requirements.txt"
      echo "$name requirements installed."
    fi
  }

  # Newer ComfyUI 403s cross-site browser requests (Sec-Fetch-Site check),
  # which breaks access through the RunPod proxy. --enable-cors-header disables that middleware.
  ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
  if [ -f "$ARGS_FILE" ] && ! grep -q "enable-cors-header" "$ARGS_FILE"; then
    echo "--enable-cors-header" >> "$ARGS_FILE"
  fi

  # --- custom node installs ---
  clone_node "rgthree" "${CUSTOM_NODES[rgthree]}" "$RGTHREE_NODE_DIR"
  install_node_reqs "rgthree" "$RGTHREE_NODE_DIR"
  clone_node "res4lyf" "${CUSTOM_NODES[res4lyf]}" "$RES4LYF_NODE_DIR" "example_workflows" "workflows"
  install_node_reqs "res4lyf" "$RES4LYF_NODE_DIR"
  clone_node "krea2edit" "${CUSTOM_NODES[krea2edit]}" "$KREA2EDIT_NODE_DIR"
  install_node_reqs "krea2edit" "$KREA2EDIT_NODE_DIR"
  clone_node "lanpaint" "${CUSTOM_NODES[lanpaint]}" "$LANPAINT_NODE_DIR" "examples" "example_workflows" "tests"
  install_node_reqs "lanpaint" "$LANPAINT_NODE_DIR"
  # --- end custom node installs ---

  # ComfyUI 0.30.0 renamed comfy/logging.py -> comfy/internal_logging.py.
  # Flag any custom node still importing the old path so a failed import is
  # obvious in the log instead of showing up as a missing node in the UI.
  if grep -rn "comfy\.logging\|from comfy import logging" "$CUSTOM_NODES_DIR" 2>/dev/null; then
    echo "WARNING: custom node(s) above import comfy.logging, removed in ComfyUI 0.30.0."
  else
    echo "No custom node references to the removed comfy.logging module."
  fi

  echo "Custom nodes done. Waiting for model downloads to finish..."
  wait "$DOWNLOADS_PID" || die "one or more model downloads failed"

  rm -rf "$TMP_DIR"

  echo "Downloads complete. Restarting ComfyUI to load custom node(s)..."
  pkill -f "main.py" || true
  sleep 3
  cd "$COMFY_ROOT" && "$COMFY_PY" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header >> /proc/1/fd/1 2>> /proc/1/fd/2 &

  echo "Waiting for ComfyUI to come back online..."
  for i in $(seq 1 300); do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then break; fi
    sleep 2
  done

  if ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "Timed out waiting for ComfyUI to restart."
    exit 1
  fi

  echo "-------------------------------------------------------"
  echo "DOWNLOAD COMPLETE - KREA2 V2 INSTALLED"
  echo "Total elapsed: $((SECONDS / 60))m$((SECONDS % 60))s"
  echo "-------------------------------------------------------"

) 2>&1 | tee -a "$LOG_FILE" >> /proc/1/fd/1 &

echo "krea2v2.sh: background watcher started, main boot can continue"
echo "krea2v2.sh: tail -f $LOG_FILE"
exit 0
