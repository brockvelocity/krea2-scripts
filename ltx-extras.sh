#!/usr/bin/env bash
# =============================================================================
# ltx-extras.sh - runs BEFORE the LTX template's own setup (/app/startup_unix.sh)
#
# What it does:
#   1. Downloads the models the Sulphur image-to-video workflows need, several
#      at a time, plus your extra Civitai models.
#   2. Keeps the big files on the /workspace volume (if the pod has one) and
#      links them into ComfyUI, so a STOPPED-then-restarted pod doesn't
#      download them again. (Stopping a pod wipes the container disk, where
#      the template normally puts models; the volume survives.)
#   3. Creates empty placeholder files for big files your workflows never use.
#      The template's setup skips any file that already exists, so it skips these.
#   4. Copies the Sulphur image-to-video workflows into ComfyUI's Workflows
#      sidebar, switched to the spatial upscaler v1.1 (v1.0 was removed from
#      Hugging Face).
#
# The template's setup runs right after this and finds everything in place.
# If any download here fails, the template's own setup still tries the
# official files it knows about, so the pod should still start.
#
# RunPod start command:
#   bash -c "(curl -fsSL <RAW_LINK> || wget -qO- <RAW_LINK>) > /tmp/ltx-extras.sh; bash /tmp/ltx-extras.sh; exec /app/startup_unix.sh"
#
# Environment variables (set in the RunPod template):
#   CIVITAI_TOKEN  - your Civitai API key (needed for the Civitai downloads)
#   HF_TOKEN       - optional Hugging Face token
# =============================================================================
set -uo pipefail

APP_MODELS="${APP_MODELS:-/app/ComfyUI/models}"
APP_WORKFLOWS="${APP_WORKFLOWS:-/app/ComfyUI/user/default/workflows/Sulphur_workflows}"
WORKFLOW_SOURCE="${WORKFLOW_SOURCE:-/app/nsfw_workflows_template}"
VOLUME="${VOLUME:-/workspace}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-1800}"   # seconds per attempt (big files)

# -----------------------------------------------------------------------------
# Hugging Face files: "repo|path in repo|ComfyUI models subfolder"
# Folder names match what the template's setup and the workflows expect.
# -----------------------------------------------------------------------------
HF_FILES=(
  "Lightricks/LTX-2.3-fp8|ltx-2.3-22b-dev-fp8.safetensors|checkpoints"
  "Comfy-Org/ltx-2|split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors|text_encoders"
  "Kijai/LTX2.3_comfy|vae/taeltx2_3.safetensors|vae"
  "Lightricks/LTX-2.3|ltx-2.3-spatial-upscaler-x2-1.1.safetensors|latent_upscale_models"
  "SulphurAI/Sulphur-2-base|sulphur_lora_rank_768.safetensors|loras"
  "SulphurAI/Sulphur-2-base|distill_loras/ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors|loras/ltx23"
)

# -----------------------------------------------------------------------------
# Civitai files: "download link|ComfyUI models subfolder"
# The real filename comes from Civitai when it downloads.
# -----------------------------------------------------------------------------
CIVITAI_FILES=(
  "https://civitai.red/api/download/models/2784573?fileId=2670611|loras"
  "https://civitai.red/api/download/models/3105328?fileId=2985158|loras"
  "https://civitai.red/api/download/models/3025398?fileId=2904187|loras"
  "https://civitai.red/api/download/models/2968696?fileId=2848243|loras"
)

# -----------------------------------------------------------------------------
# Files the template always downloads but your workflows never use.
# An empty file with the same name makes the template skip them.
# (They'll show up in ComfyUI's dropdowns as empty files - don't pick them.)
# -----------------------------------------------------------------------------
PLACEHOLDERS=(
  "text_encoders/t5xxl_fp16.safetensors"
  "loras/ltx-2.3-22b-distilled-lora-384.safetensors"
)

# Only these workflows are copied into the sidebar.
WORKFLOWS=(
  "sulphur_ltx23_i2v_distilled.json"
  "sulphur_ltx23_i2v_base.json"
)

# Keep Hugging Face's fast download mode, but cap its memory use per download.
export HF_XET_HIGH_PERFORMANCE=1
export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_SIZE=4gb
export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_PERFILE_SIZE=2gb
export HF_XET_RECONSTRUCTION_DOWNLOAD_BUFFER_LIMIT=4gb
export HF_HUB_DOWNLOAD_TIMEOUT=60

log() { echo "[ltx-extras] $*"; }
START=$SECONDS

# --- Where to keep the big files ----------------------------------------------
if [ -d "$VOLUME" ] && touch "$VOLUME/.ltx-extras-write-test" 2>/dev/null; then
  rm -f "$VOLUME/.ltx-extras-write-test"
  STORE="$VOLUME/ltx-models"
  log "Storing models on the volume ($STORE) and linking them into ComfyUI."
else
  STORE="$APP_MODELS"
  log "No writable volume at $VOLUME - downloading straight into ComfyUI (not kept after a stop)."
fi
mkdir -p "$STORE"

# --- A Python that has huggingface_hub (the image ships its own) ---------------
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
  for p in /app/venv_stable/bin/python3 /app/venv_blackwell/bin/python3 python3; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import huggingface_hub' >/dev/null 2>&1; then
      PYTHON="$p"; break
    fi
  done
fi
if [ -z "$PYTHON" ]; then
  log "WARNING: no Python with huggingface_hub found - skipping Hugging Face downloads (the template will still fetch its own)."
fi

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout --kill-after=30 "$DOWNLOAD_TIMEOUT")
else
  TIMEOUT_CMD=()
fi

# Put a file that lives in $STORE into ComfyUI's models folder.
link_into_comfy() {
  local sub="$1" name="$2"
  [ "$STORE" = "$APP_MODELS" ] && return 0
  mkdir -p "$APP_MODELS/$sub"
  ln -sfn "$STORE/$sub/$name" "$APP_MODELS/$sub/$name"
}

# --- Hugging Face download (one file, up to 3 tries) ----------------------------
hf_fetch() {
  local repo="$1" path="$2" sub="$3"
  local name; name="$(basename "$path")"
  local dest="$STORE/$sub/$name"
  if [ -s "$dest" ]; then
    log "already have $name"
    link_into_comfy "$sub" "$name"; return 0
  fi
  [ -n "$PYTHON" ] || return 1
  mkdir -p "$STORE/$sub"
  local attempt start tmp got
  for attempt in 1 2 3; do
    start=$SECONDS
    log "downloading $name (attempt $attempt/3)"
    tmp="$(mktemp -d "$STORE/$sub/.dl.XXXXXX")"
    got="$(HF_DL_REPO="$repo" HF_DL_PATH="$path" HF_DL_DIR="$tmp" "${TIMEOUT_CMD[@]}" "$PYTHON" - <<'PY'
import os, sys
from huggingface_hub import hf_hub_download
try:
    print(hf_hub_download(repo_id=os.environ["HF_DL_REPO"], filename=os.environ["HF_DL_PATH"],
                          local_dir=os.environ["HF_DL_DIR"], token=os.environ.get("HF_TOKEN") or None))
except Exception as e:
    sys.stderr.write("download failed: %s\n" % e); sys.exit(1)
PY
)"
    if [ -n "$got" ] && [ -s "$got" ] && mv -f "$got" "$dest"; then
      rm -rf "$tmp"
      log "finished $name in $((SECONDS - start))s"
      link_into_comfy "$sub" "$name"; return 0
    fi
    rm -rf "$tmp"
    log "attempt $attempt failed for $name after $((SECONDS - start))s"
    sleep 5
  done
  log "WARNING: could not download $name"
  return 1
}

# --- Civitai download (one file, up to 3 tries) ---------------------------------
# A small marker file remembers the real filename, so restarts can skip it.
civitai_fetch() {
  local url="$1" sub="$2"
  local id; id="$(echo "$url" | sed -E 's#.*/models/([0-9]+).*#\1#')"
  local marker="$STORE/$sub/.civitai-$id"
  mkdir -p "$STORE/$sub"
  if [ -f "$marker" ] && [ -s "$STORE/$sub/$(cat "$marker")" ]; then
    log "already have $(cat "$marker") (Civitai $id)"
    link_into_comfy "$sub" "$(cat "$marker")"; return 0
  fi
  local auth=()
  if [ -n "${CIVITAI_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $CIVITAI_TOKEN")
  else
    log "WARNING: CIVITAI_TOKEN not set - Civitai may refuse $id"
  fi
  local attempt start tmp name rc
  for attempt in 1 2 3; do
    start=$SECONDS
    log "downloading Civitai $id (attempt $attempt/3)"
    tmp="$(mktemp -d "$STORE/$sub/.dl.XXXXXX")"
    rc=0
    (cd "$tmp" && "${TIMEOUT_CMD[@]}" curl -fsSL --retry 2 --connect-timeout 30 "${auth[@]}" -J -O "$url") || rc=$?
    name="$(ls -1 "$tmp" 2>/dev/null | head -1)"
    if [ "$rc" -eq 0 ] && [ -n "$name" ] && [ -s "$tmp/$name" ]; then
      mv -f "$tmp/$name" "$STORE/$sub/$name" && rm -rf "$tmp"
      echo "$name" > "$marker"
      log "finished $name (Civitai $id) in $((SECONDS - start))s"
      link_into_comfy "$sub" "$name"; return 0
    fi
    rm -rf "$tmp"
    if [ "$rc" -eq 22 ]; then
      log "Civitai refused $id - check CIVITAI_TOKEN (attempt $attempt)"
    else
      log "attempt $attempt failed for Civitai $id (curl exit $rc)"
    fi
    sleep 5
  done
  log "WARNING: could not download Civitai $id"
  return 1
}

# --- 1. Placeholders for unused files -------------------------------------------
for p in "${PLACEHOLDERS[@]}"; do
  mkdir -p "$APP_MODELS/$(dirname "$p")"
  [ -e "$APP_MODELS/$p" ] || : > "$APP_MODELS/$p"
done
log "created placeholders for ${#PLACEHOLDERS[@]} unused files"

# --- 2. Downloads, MAX_PARALLEL at a time -----------------------------------------
JOBS=()
for e in "${HF_FILES[@]}"; do
  IFS='|' read -r repo path sub <<< "$e"
  JOBS+=("hf_fetch '$repo' '$path' '$sub'")
done
for e in "${CIVITAI_FILES[@]}"; do
  JOBS+=("civitai_fetch '${e%%|*}' '${e##*|}'")
done

log "starting ${#JOBS[@]} downloads, $MAX_PARALLEL at a time"
FAILED_DIR="$(mktemp -d)"
n=0
for job in "${JOBS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do wait -n || true; done
  n=$((n + 1))
  ( eval "$job" || touch "$FAILED_DIR/$n" ) &
done
wait || true
FAILED=$(ls "$FAILED_DIR" | wc -l); rm -rf "$FAILED_DIR"

# --- 3. Sulphur workflows, with the upscaler switched to v1.1 --------------------
mkdir -p "$APP_WORKFLOWS"
for wf in "${WORKFLOWS[@]}"; do
  src="$WORKFLOW_SOURCE/$wf"
  if [ -f "$src" ]; then
    [ -f "$APP_WORKFLOWS/$wf" ] || \
      sed 's/ltx-2\.3-spatial-upscaler-x2-1\.0\.safetensors/ltx-2.3-spatial-upscaler-x2-1.1.safetensors/g' "$src" > "$APP_WORKFLOWS/$wf"
  else
    log "WARNING: workflow $wf not found in $WORKFLOW_SOURCE"
  fi
done
log "Sulphur workflows are in the sidebar under Sulphur_workflows"

if [ "$FAILED" -gt 0 ]; then
  log "DONE with $FAILED failed download(s) in $((SECONDS - START))s - see WARNING lines above."
else
  log "DONE - all downloads finished in $((SECONDS - START))s. Handing over to the template's setup."
fi
exit 0
