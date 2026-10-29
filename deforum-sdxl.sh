#!/bin/bash
set -euo pipefail

LOG_FILE="/workspace/deforum-background.log"
# If the log file can't be created (e.g. /workspace not mounted yet), fall back
# to /dev/null so tee never kills the watcher.
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

(
  set -euo pipefail

  COMFY_ROOT="/workspace/runpod-slim/ComfyUI"
  CUSTOM_NODES_DIR="$COMFY_ROOT/custom_nodes"
  VHS_NODE_DIR="$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite"
  FRAMEINTERP_NODE_DIR="$CUSTOM_NODES_DIR/ComfyUI-Frame-Interpolation"
  DEFORUM_NODE_DIR="$CUSTOM_NODES_DIR/deforum_loop"
  WORKFLOWS_DIR="$COMFY_ROOT/user/default/workflows"
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
  echo "BACKGROUND WATCHER STARTED: DEFORUM SDXL CONFIG"
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
  # Deforum SDXL setup: one model. SDXL Lightning 8-step is a complete SDXL checkpoint
  # (model + text encoders + VAE in one file), distilled to make good images in 8 steps.
  # To use a different SDXL checkpoint, add its link here (Hugging Face or Civitai).
  ALL_DOWNLOAD_QUEUE=(
    "https://huggingface.co/ByteDance/SDXL-Lightning/resolve/main/sdxl_lightning_8step.safetensors|$MODELS_DIR/checkpoints"
    # Depth Anything V2 Small (~100 MB, Apache-2.0) for the Deforum Loop node's 3D mode.
    "https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf/resolve/main/model.safetensors|$MODELS_DIR/depth_anything/Depth-Anything-V2-Small-hf"
    "https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf/resolve/main/config.json|$MODELS_DIR/depth_anything/Depth-Anything-V2-Small-hf"
    "https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf/resolve/main/preprocessor_config.json|$MODELS_DIR/depth_anything/Depth-Anything-V2-Small-hf"
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
      "$COMFY_PY" -m pip install -q -r "$dir/requirements.txt" \
        && echo "$name requirements installed." \
        || echo "WARNING: $name requirements failed to install; check this node in ComfyUI."
    elif [ -f "$dir/install.py" ]; then
      # Some node packs (e.g. Frame-Interpolation) use an install script instead.
      (cd "$dir" && "$COMFY_PY" install.py) \
        && echo "$name install script ran." \
        || echo "WARNING: $name install script failed; check this node in ComfyUI."
    fi
  }

  # Newer ComfyUI 403s cross-site browser requests (Sec-Fetch-Site check),
  # which breaks access through the RunPod proxy. --enable-cors-header disables that middleware.
  ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
  if [ -f "$ARGS_FILE" ] && ! grep -q "enable-cors-header" "$ARGS_FILE"; then
    echo "--enable-cors-header" >> "$ARGS_FILE"
  fi

  # --- custom node installs ---
  clone_node "videohelper" "${CUSTOM_NODES[videohelper]}" "$VHS_NODE_DIR"
  install_node_reqs "videohelper" "$VHS_NODE_DIR"
  clone_node "frameinterp" "${CUSTOM_NODES[frameinterp]}" "$FRAMEINTERP_NODE_DIR"
  install_node_reqs "frameinterp" "$FRAMEINTERP_NODE_DIR"

  # Deforum Loop node: written straight from this script, so there's nothing else
  # to download. Always overwritten, so editing this script updates the node.
  mkdir -p "$DEFORUM_NODE_DIR"
  cat > "$DEFORUM_NODE_DIR/__init__.py" <<'PYEOF'
"""
Deforum Loop - a single ComfyUI node that makes Deforum-style animations.

How it works (the classic Deforum recipe):
  1. Make the first frame from the prompt (or start from an image you provide).
  2. For every following frame: take the previous frame, zoom / rotate / shift it
     a little, add a touch of noise, and run it through img2img at partial
     strength so the model redraws it slightly differently.
  3. Optionally keep colors steady by matching each frame to the first one.

3D mode (like Deforum's 3D animation mode): each frame's depth is estimated with
Depth Anything V2, so the camera can move *through* the scene - near things move
faster than far things (parallax) - and turn, tilt and roll like a real camera.

Prompts can change over time with a simple schedule, one per line:
    0: a misty pine forest at dawn, cinematic
    48: a glowing crystal cave, bioluminescent
    96: a neon city at night, rain

Uses only ComfyUI's own sampling, so it works with any checkpoint ComfyUI can load
(SDXL, SDXL Lightning, SD 1.5, ...). Output is a batch of frames (IMAGE) that can go
straight into Video Combine, RIFE interpolation, an upscaler, etc.
"""

import math
import re

import torch
import torch.nn.functional as F

import comfy.model_management
import comfy.samplers
import comfy.utils
import nodes


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

_SCHEDULE_LINE = re.compile(r"^\s*(\d+)\s*:\s*(.*\S)\s*$")


def parse_prompt_schedule(text):
    """Turn the prompt box into a sorted list of (start_frame, prompt).

    Lines like "48: a crystal cave" start a new prompt at that frame. Lines
    without a frame number are added to the prompt above them, so long prompts
    can wrap. Text with no frame numbers at all is one prompt from frame 0.
    """
    entries = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = _SCHEDULE_LINE.match(line)
        if m:
            entries.append([int(m.group(1)), m.group(2)])
        elif entries:
            entries[-1][1] = entries[-1][1] + " " + line
        else:
            entries.append([0, line])
    if not entries:
        entries = [[0, ""]]
    entries.sort(key=lambda e: e[0])
    if entries[0][0] != 0:
        # Nothing scheduled for the start: use the first prompt from frame 0.
        entries[0][0] = 0
    return [(f, p) for f, p in entries]


def prompt_for_frame(schedule, frame):
    current = schedule[0][1]
    for start, prompt in schedule:
        if start <= frame:
            current = prompt
        else:
            break
    return current


def encode_text(clip, text):
    """Encode text the same way ComfyUI's CLIPTextEncode node does."""
    tokens = clip.tokenize(text)
    if hasattr(clip, "encode_from_tokens_scheduled"):
        return clip.encode_from_tokens_scheduled(tokens)
    cond, pooled = clip.encode_from_tokens(tokens, return_pooled=True)
    return [[cond, {"pooled_output": pooled}]]


def warp(image, zoom, angle_deg, tx, ty):
    """Zoom (around the center), rotate and shift an image batch [B,H,W,C].

    zoom > 1 zooms in, angle in degrees (positive = clockwise on screen),
    tx / ty in pixels (positive = content moves right / down).
    Edges revealed by zooming out, rotating or shifting are filled by mirroring.
    """
    if zoom == 1.0 and angle_deg == 0.0 and tx == 0.0 and ty == 0.0:
        return image
    x = image.movedim(-1, 1)  # [B,C,H,W]
    b, _, h, w = x.shape
    a = math.radians(angle_deg)
    c, s = math.cos(a) / zoom, math.sin(a) / zoom
    # affine_grid maps each OUTPUT pixel to the INPUT location it samples,
    # in normalized coordinates (-1..1). Aspect-ratio terms keep rotation
    # circular on non-square images.
    theta = torch.tensor(
        [[c, s * h / w, -2.0 * tx / w],
         [-s * w / h, c, -2.0 * ty / h]],
        dtype=x.dtype, device=x.device,
    ).unsqueeze(0).repeat(b, 1, 1)
    grid = F.affine_grid(theta, list(x.shape), align_corners=False)
    out = F.grid_sample(x, grid, mode="bicubic", padding_mode="reflection", align_corners=False)
    return out.clamp(0.0, 1.0).movedim(1, -1)


# ----------------------------------------------------------------------------
# 3D mode: depth estimation + 3D camera warp
# ----------------------------------------------------------------------------

DEPTH_MODEL_SUBDIR = ("depth_anything", "Depth-Anything-V2-Small-hf")
_depth_cache = {}

# The scene is treated as spanning from 1 unit away (nearest thing in frame)
# to 10 units away (farthest), so camera moves are in those units.
NEAR, FAR = 1.0, 10.0


def depth_model_dir():
    import os
    import folder_paths
    return os.path.join(folder_paths.models_dir, *DEPTH_MODEL_SUBDIR)


def load_depth_model():
    if "model" in _depth_cache:
        return _depth_cache["model"]
    import os
    path = depth_model_dir()
    if not os.path.isfile(os.path.join(path, "model.safetensors")):
        raise RuntimeError(
            f"3D mode needs the Depth Anything V2 Small model in {path} "
            "(config.json + model.safetensors). The Deforum setup script downloads it.")
    try:
        from transformers import DepthAnythingForDepthEstimation
    except ImportError as e:
        raise RuntimeError("3D mode needs a newer 'transformers' Python package "
                           "(one with Depth Anything support).") from e
    device = comfy.model_management.get_torch_device()
    dtype = torch.float16 if device.type == "cuda" else torch.float32
    model = DepthAnythingForDepthEstimation.from_pretrained(path, torch_dtype=dtype).to(device).eval()
    _depth_cache["model"] = model
    return model


def estimate_depth(image, model):
    """Distance map for an image batch [1,H,W,C] -> [1,1,H,W] in NEAR..FAR units.

    Depth Anything gives relative 'disparity' (bigger = closer). It's normalized
    per frame and turned into distance, so the closest things sit at NEAR and
    the farthest at FAR.
    """
    _, h, w, _ = image.shape
    param = next(model.parameters())
    x = image[..., :3].movedim(-1, 1).to(param.device, torch.float32)
    scale = 518.0 / min(h, w)
    sh = max(14, int(round(h * scale / 14.0)) * 14)
    sw = max(14, int(round(w * scale / 14.0)) * 14)
    x = F.interpolate(x, size=(sh, sw), mode="bicubic", align_corners=False).clamp(0, 1)
    mean = torch.tensor([0.485, 0.456, 0.406], device=x.device).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225], device=x.device).view(1, 3, 1, 1)
    x = ((x - mean) / std).to(param.dtype)
    with torch.no_grad():
        disp = model(pixel_values=x).predicted_depth
    disp = disp.reshape(1, 1, disp.shape[-2], disp.shape[-1]).float()
    disp = F.interpolate(disp, size=(h, w), mode="bilinear", align_corners=False).cpu()
    lo = torch.quantile(disp.flatten(), 0.02)
    hi = torch.quantile(disp.flatten(), 0.98)
    d = ((disp - lo) / (hi - lo).clamp_min(1e-6)).clamp(0, 1)
    # Interpolate in inverse-distance space, like a real camera's disparity.
    return 1.0 / (d * (1.0 / NEAR - 1.0 / FAR) + 1.0 / FAR)


def rotation_matrix(tilt_deg, pan_deg, roll_deg):
    """Camera rotation from per-frame tilt (about x), pan (about y), roll (about z)."""
    rx, ry, rz = (math.radians(a) for a in (tilt_deg, pan_deg, roll_deg))
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    rot_x = torch.tensor([[1, 0, 0], [0, cx, -sx], [0, sx, cx]], dtype=torch.float32)
    rot_y = torch.tensor([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]], dtype=torch.float32)
    rot_z = torch.tensor([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]], dtype=torch.float32)
    return rot_z @ rot_y @ rot_x


def warp_3d(image, depth, move_x, move_y, move_z, turn_x, turn_y, turn_z, fov):
    """Move a virtual camera through the scene and re-render the previous frame.

    Camera coordinates: x right, y down, z forward (into the scene).
    move_x + = camera moves right, move_y + = camera moves up,
    move_z + = camera moves forward. turn_x + = look up, turn_y + = turn right,
    turn_z + = picture rotates clockwise. Same method as Deforum's 3D mode:
    each pixel is placed in 3D from its depth, the camera moves, and the pixel's
    new screen position tells us where to sample the previous frame from.
    """
    x = image.movedim(-1, 1)  # [1,C,H,W]
    _, _, h, w = x.shape
    aspect = w / h
    f = 1.0 / math.tan(math.radians(fov) / 2.0)

    # Normalized screen coordinates of pixel centers (-1..1), matching grid_sample.
    u = (torch.arange(w, dtype=torch.float32) * 2 + 1) / w - 1
    v = (torch.arange(h, dtype=torch.float32) * 2 + 1) / h - 1
    vv, uu = torch.meshgrid(v, u, indexing="ij")
    z = depth[0, 0]

    # Unproject to 3D points in the old camera's space.
    pts = torch.stack([uu * aspect * z / f, vv * z / f, z], dim=-1)  # [H,W,3]

    # Express the points in the new camera's space: P' = R^T (P - t).
    # turn_z is negated so 'clockwise' matches its name (directions verified by test).
    rot = rotation_matrix(turn_x, turn_y, -turn_z)
    t = torch.tensor([move_x, -move_y, move_z], dtype=torch.float32)
    new = (pts - t) @ rot  # row-vector form of R^T (P - t)
    nz = new[..., 2].clamp_min(0.05)

    # Project back to the screen.
    u_new = f * new[..., 0] / (nz * aspect)
    v_new = f * new[..., 1] / nz

    # Backward warp: each output pixel samples where its content came from.
    grid = torch.stack([uu - (u_new - uu), vv - (v_new - vv)], dim=-1).unsqueeze(0)
    out = F.grid_sample(x.float(), grid, mode="bicubic", padding_mode="reflection", align_corners=False)
    return out.clamp(0.0, 1.0).movedim(1, -1)


def match_colors(image, reference):
    """Shift each color channel's mean/contrast to match the reference frame.

    This is a light version of Deforum's 'color coherence': it stops the slow
    drift toward over-saturated or washed-out colors that feedback loops cause.
    """
    dims = (1, 2)
    img_mean = image.mean(dim=dims, keepdim=True)
    img_std = image.std(dim=dims, keepdim=True).clamp_min(1e-5)
    ref_mean = reference.mean(dim=dims, keepdim=True)
    ref_std = reference.std(dim=dims, keepdim=True).clamp_min(1e-5)
    return ((image - img_mean) / img_std * ref_std + ref_mean).clamp(0.0, 1.0)


def as_images(decoded):
    """VAE decode can return extra dimensions for video VAEs; flatten to [B,H,W,C]."""
    if decoded.dim() == 5:
        decoded = decoded.reshape(-1, decoded.shape[-3], decoded.shape[-2], decoded.shape[-1])
    return decoded


# ----------------------------------------------------------------------------
# The node
# ----------------------------------------------------------------------------

class DeforumLoop:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "model": ("MODEL",),
                "clip": ("CLIP",),
                "vae": ("VAE",),
                "prompts": ("STRING", {
                    "multiline": True,
                    "default": "0: a misty pine forest at dawn, volumetric light, cinematic, highly detailed\n"
                               "48: an ancient overgrown temple in the forest, glowing runes, cinematic\n"
                               "96: a glowing crystal cave, bioluminescent, cinematic, highly detailed",
                    "tooltip": "One prompt per line as 'frame: prompt'. Each prompt takes over at its frame number.",
                }),
                "negative": ("STRING", {
                    "multiline": True,
                    "default": "blurry, low quality, watermark, text",
                    "tooltip": "Only has an effect when cfg is above 1.",
                }),
                "frames": ("INT", {"default": 120, "min": 1, "max": 10000,
                                   "tooltip": "Total frames to generate. At 12 fps, 120 frames = 10 seconds."}),
                "width": ("INT", {"default": 1024, "min": 64, "max": 4096, "step": 8}),
                "height": ("INT", {"default": 1024, "min": 64, "max": 4096, "step": 8}),
                "seed": ("INT", {"default": 0, "min": 0, "max": 0xffffffffffffffff, "control_after_generate": True}),
                "seed_mode": (["increment", "fixed"], {
                    "tooltip": "increment: a new seed each frame (more change, the classic look). fixed: same seed every frame (calmer)."}),
                "steps": ("INT", {"default": 8, "min": 1, "max": 100,
                                  "tooltip": "Steps for a full image. In-between frames automatically use steps x strength."}),
                "cfg": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 30.0, "step": 0.1, "round": 0.01}),
                "sampler_name": (comfy.samplers.KSampler.SAMPLERS, {"default": "euler"}),
                "scheduler": (comfy.samplers.KSampler.SCHEDULERS, {"default": "sgm_uniform"}),
                "strength": ("FLOAT", {"default": 0.5, "min": 0.05, "max": 1.0, "step": 0.01,
                                       "tooltip": "How much each frame is redrawn. Lower = smoother and more stable, higher = more morphing."}),
                "zoom": ("FLOAT", {"default": 1.02, "min": 0.5, "max": 2.0, "step": 0.001,
                                   "tooltip": "Zoom per frame. 1.0 = none, above 1 = zoom in, below 1 = zoom out."}),
                "rotation": ("FLOAT", {"default": 0.0, "min": -45.0, "max": 45.0, "step": 0.1,
                                       "tooltip": "Degrees of rotation per frame. Positive = clockwise, negative = counter-clockwise."}),
                "translate_x": ("FLOAT", {"default": 0.0, "min": -512.0, "max": 512.0, "step": 0.5,
                                          "tooltip": "Pixels to pan per frame. Positive = image moves right."}),
                "translate_y": ("FLOAT", {"default": 0.0, "min": -512.0, "max": 512.0, "step": 0.5,
                                          "tooltip": "Pixels to pan per frame. Positive = image moves down."}),
                "noise": ("FLOAT", {"default": 0.02, "min": 0.0, "max": 0.5, "step": 0.005,
                                    "tooltip": "Grain added before each redraw. Keeps detail from going smeary over time."}),
                "color_coherence": ("BOOLEAN", {"default": True,
                                                "tooltip": "Keep colors close to the first frame to stop color drift."}),
                # --- 3D mode (added last so older saved workflows still load) ---
                "animation_mode": (["2D", "3D"], {
                    "tooltip": "2D: flat zoom/rotate/pan (the settings above). "
                               "3D: estimates depth so the camera moves through the scene with parallax (the settings below)."}),
                "move_x": ("FLOAT", {"default": 0.0, "min": -1.0, "max": 1.0, "step": 0.001,
                                     "tooltip": "3D: camera moves sideways per frame. Positive = right. Nearest things are 1 unit away, the background about 10."}),
                "move_y": ("FLOAT", {"default": 0.0, "min": -1.0, "max": 1.0, "step": 0.001,
                                     "tooltip": "3D: camera moves up/down per frame. Positive = up."}),
                "move_z": ("FLOAT", {"default": 0.03, "min": -1.0, "max": 1.0, "step": 0.001,
                                     "tooltip": "3D: camera moves forward per frame. Positive = into the scene. 0.02-0.05 is a steady glide."}),
                "turn_x": ("FLOAT", {"default": 0.0, "min": -20.0, "max": 20.0, "step": 0.05,
                                     "tooltip": "3D: tilt, degrees per frame. Positive = look up."}),
                "turn_y": ("FLOAT", {"default": 0.0, "min": -20.0, "max": 20.0, "step": 0.05,
                                     "tooltip": "3D: pan, degrees per frame. Positive = turn right."}),
                "turn_z": ("FLOAT", {"default": 0.0, "min": -20.0, "max": 20.0, "step": 0.05,
                                     "tooltip": "3D: roll, degrees per frame. Positive = picture rotates clockwise."}),
                "fov": ("FLOAT", {"default": 40.0, "min": 10.0, "max": 120.0, "step": 1.0,
                                  "tooltip": "3D: camera field of view in degrees. Lower = more telephoto, less perspective."}),
            },
            "optional": {
                "init_image": ("IMAGE", {"tooltip": "Optional. Start the animation from this image instead of generating the first frame."}),
            },
        }

    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("frames",)
    FUNCTION = "animate"
    CATEGORY = "animation/deforum"
    DESCRIPTION = "Deforum-style feedback animation: zoom/rotate/pan each frame and redraw it with img2img."

    def animate(self, model, clip, vae, prompts, negative, frames, width, height, seed, seed_mode,
                steps, cfg, sampler_name, scheduler, strength, zoom, rotation, translate_x,
                translate_y, noise, color_coherence, animation_mode="2D", move_x=0.0, move_y=0.0,
                move_z=0.03, turn_x=0.0, turn_y=0.0, turn_z=0.0, fov=40.0, init_image=None):
        width -= width % 8
        height -= height % 8

        # Load the depth model up front, so a missing file fails before any work is done.
        depth_model = load_depth_model() if animation_mode == "3D" else None

        schedule = parse_prompt_schedule(prompts)
        cond_cache = {}

        def positive_for(frame):
            text = prompt_for_frame(schedule, frame)
            if text not in cond_cache:
                cond_cache[text] = encode_text(clip, text)
            return cond_cache[text]

        negative_cond = encode_text(clip, negative)

        # In-between frames only redraw part of the image, so they only need part
        # of the steps. With a distilled model like SDXL Lightning this also keeps
        # the sampler on the schedule the model was trained for.
        i2i_steps = max(1, int(round(steps * strength)))

        def frame_seed(i):
            return (seed + i) % 0x10000000000000000 if seed_mode == "increment" else seed

        def sample(latent, frame, denoise, n_steps):
            out = nodes.common_ksampler(
                model, frame_seed(frame), n_steps, cfg, sampler_name, scheduler,
                positive_for(frame), negative_cond, {"samples": latent}, denoise=denoise,
            )[0]
            return out["samples"]

        def decode(latent):
            return as_images(vae.decode(latent))[:1].float().cpu()

        def encode(image):
            return vae.encode(image[:, :, :, :3])

        # --- First frame ---
        if init_image is not None:
            first = init_image[:1, :, :, :3].float()
            if first.shape[1] != height or first.shape[2] != width:
                first = comfy.utils.common_upscale(
                    first.movedim(-1, 1), width, height, "bicubic", "center").movedim(1, -1)
            first = first.clamp(0.0, 1.0).cpu()
        else:
            empty = torch.zeros([1, 4, height // 8, width // 8])
            first = decode(sample(empty, 0, 1.0, steps))

        print(f"[Deforum Loop] frame 1/{frames}")
        out_frames = [first]
        reference = first
        prev = first
        gen = torch.Generator().manual_seed(seed)

        # --- Every following frame ---
        for i in range(1, frames):
            comfy.model_management.throw_exception_if_processing_interrupted()

            if animation_mode == "3D":
                depth = estimate_depth(prev, depth_model)
                img = warp_3d(prev, depth, move_x, move_y, move_z, turn_x, turn_y, turn_z, fov)
            else:
                img = warp(prev, zoom, rotation, translate_x, translate_y)
            if noise > 0:
                img = (img + torch.randn(img.shape, generator=gen) * noise).clamp(0.0, 1.0)

            img = decode(sample(encode(img), i, strength, i2i_steps))
            if color_coherence:
                img = match_colors(img, reference)

            out_frames.append(img)
            prev = img
            print(f"[Deforum Loop] frame {i + 1}/{frames}")

        return (torch.cat(out_frames, dim=0),)


NODE_CLASS_MAPPINGS = {"DeforumLoop": DeforumLoop}
NODE_DISPLAY_NAME_MAPPINGS = {"DeforumLoop": "Deforum Loop"}
PYEOF
  echo "Deforum Loop node installed."

  # Ready-made workflow, so it shows up in ComfyUI's Workflows sidebar.
  # Only written if missing, so your own edits to it are kept on restarts.
  mkdir -p "$WORKFLOWS_DIR"
  if [ ! -f "$WORKFLOWS_DIR/Deforum SDXL.json" ]; then
    cat > "$WORKFLOWS_DIR/Deforum SDXL.json" <<'JSONEOF'
{
  "id": "6f1d2c1e-6c0b-4a4e-9d55-d3f0a1b2c3d4",
  "revision": 0,
  "last_node_id": 5,
  "last_link_id": 5,
  "nodes": [
    {
      "id": 1,
      "type": "CheckpointLoaderSimple",
      "pos": [
        -420,
        0
      ],
      "size": [
        320,
        98
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            1
          ]
        },
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            2
          ]
        },
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            3
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "CheckpointLoaderSimple"
      },
      "widgets_values": [
        "sdxl_lightning_8step.safetensors"
      ]
    },
    {
      "id": 2,
      "type": "DeforumLoop",
      "pos": [
        -40,
        -80
      ],
      "size": [
        420,
        1000
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 1
        },
        {
          "name": "clip",
          "type": "CLIP",
          "link": 2
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 3
        },
        {
          "name": "init_image",
          "shape": 7,
          "type": "IMAGE",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "frames",
          "type": "IMAGE",
          "links": [
            4
          ]
        }
      ],
      "title": "Deforum Loop",
      "properties": {
        "Node name for S&R": "DeforumLoop"
      },
      "widgets_values": [
        "0: a misty pine forest at dawn, volumetric light, cinematic, highly detailed\n48: an ancient overgrown temple in the forest, glowing runes, cinematic\n96: a glowing crystal cave, bioluminescent, cinematic, highly detailed",
        "blurry, low quality, watermark, text",
        120,
        1024,
        1024,
        0,
        "randomize",
        "increment",
        8,
        1.0,
        "euler",
        "sgm_uniform",
        0.5,
        1.02,
        0.0,
        0.0,
        0.0,
        0.02,
        true,
        "3D",
        0.0,
        0.0,
        0.03,
        0.0,
        0.0,
        0.0,
        40.0
      ]
    },
    {
      "id": 3,
      "type": "RIFE VFI",
      "pos": [
        430,
        -80
      ],
      "size": [
        320,
        270
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [
        {
          "name": "frames",
          "type": "IMAGE",
          "link": 4
        },
        {
          "name": "optional_interpolation_states",
          "shape": 7,
          "type": "INTERPOLATION_STATES",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            5
          ]
        }
      ],
      "title": "RIFE 2x (smooths motion)",
      "properties": {
        "aux_id": "Fannovel16/ComfyUI-Frame-Interpolation",
        "cnr_id": "comfyui-frame-interpolation",
        "Node name for S&R": "RIFE VFI"
      },
      "widgets_values": [
        "rife47.pth",
        10,
        2,
        true,
        true,
        1,
        "float32",
        false,
        1
      ]
    },
    {
      "id": 4,
      "type": "VHS_VideoCombine",
      "pos": [
        800,
        -80
      ],
      "size": [
        360,
        640
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 5
        },
        {
          "name": "audio",
          "shape": 7,
          "type": "AUDIO",
          "link": null
        },
        {
          "name": "meta_batch",
          "shape": 7,
          "type": "VHS_BatchManager",
          "link": null
        },
        {
          "name": "vae",
          "shape": 7,
          "type": "VAE",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "Filenames",
          "type": "VHS_FILENAMES",
          "links": null
        }
      ],
      "properties": {
        "aux_id": "kosinkadink/ComfyUI-VideoHelperSuite",
        "Node name for S&R": "VHS_VideoCombine"
      },
      "widgets_values": {
        "frame_rate": 24,
        "loop_count": 0,
        "filename_prefix": "Deforum/deforum",
        "format": "video/h264-mp4",
        "pix_fmt": "yuv420p",
        "crf": 19,
        "save_metadata": true,
        "trim_to_audio": false,
        "pingpong": false,
        "save_output": true,
        "videopreview": {
          "hidden": false,
          "paused": false,
          "params": {}
        }
      }
    },
    {
      "id": 5,
      "type": "Note",
      "pos": [
        -420,
        160
      ],
      "size": [
        360,
        400
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [],
      "outputs": [],
      "title": "How to use",
      "properties": {},
      "widgets_values": [
        "DEFORUM SDXL - quick guide\n\n1. Write prompts in the Deforum Loop node, one per line as  frame: prompt\n   Each prompt takes over at its frame number.\n2. animation_mode:\n   3D = the camera moves THROUGH the scene (near things move faster).\n        Use move_x / move_y / move_z and turn_x / turn_y / turn_z.\n        move_z 0.02-0.05 = steady glide forward. turn_y 0.3 = slow pan right.\n   2D = flat zoom / rotation / translate_x / translate_y.\n3. strength = how much each frame changes. 0.4 calm, 0.5 classic, 0.6+ wild.\n4. Click Run. Frames are made at 12 fps, then RIFE doubles them to 24 fps.\n   120 frames = a 10-second video, saved to output/Deforum/.\n\nModel: SDXL Lightning 8-step. Keep steps 8, cfg 1, euler + sgm_uniform.\nTip: try frames = 24 first for a quick test."
      ],
      "color": "#432",
      "bgcolor": "#653"
    }
  ],
  "links": [
    [
      1,
      1,
      0,
      2,
      0,
      "MODEL"
    ],
    [
      2,
      1,
      1,
      2,
      1,
      "CLIP"
    ],
    [
      3,
      1,
      2,
      2,
      2,
      "VAE"
    ],
    [
      4,
      2,
      0,
      3,
      0,
      "IMAGE"
    ],
    [
      5,
      3,
      0,
      4,
      0,
      "IMAGE"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {
    "ds": {
      "scale": 0.8,
      "offset": [
        520,
        180
      ]
    }
  },
  "version": 0.4
}
JSONEOF
    echo "Deforum SDXL workflow added to the Workflows sidebar."
  fi
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
  echo "DOWNLOAD COMPLETE - DEFORUM SDXL INSTALLED"
  echo "Total elapsed: $((SECONDS / 60))m$((SECONDS % 60))s"
  echo "-------------------------------------------------------"

) 2>&1 | tee -a "$LOG_FILE" >> /proc/1/fd/1 &

echo "deforum-sdxl.sh: background watcher started, main boot can continue"
echo "deforum-sdxl.sh: tail -f $LOG_FILE"
exit 0
