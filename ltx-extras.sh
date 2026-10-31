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
#   4. Puts the Sulphur image-to-video workflows into ComfyUI's Workflows
#      sidebar, switched to the spatial upscaler v1.1 (v1.0 was removed from
#      Hugging Face) and with a Power LoRA Loader for your extra LoRAs.
#   5. Adds extra startup options to ComfyUI (default: --disable-pinned-memory,
#      which stops big video jobs from using up the pod's RAM and getting the
#      ComfyUI process killed). Change them with the COMFY_EXTRA_ARGS variable.
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
#   COMFY_EXTRA_ARGS - optional ComfyUI startup options. If not set, uses
#                    "--disable-pinned-memory". Set it to a single space to add none.
# =============================================================================
set -uo pipefail

APP_MODELS="${APP_MODELS:-/app/ComfyUI/models}"
APP_WORKFLOWS="${APP_WORKFLOWS:-/app/ComfyUI/user/default/workflows/Sulphur_workflows}"
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

# --- 3. Sulphur workflows -------------------------------------------------------
# Built into this script: the template's two Sulphur image-to-video workflows,
# with the spatial upscaler switched to v1.1 and a Power LoRA Loader added
# where the model splits into its two passes, for your extra LoRAs.
mkdir -p "$APP_WORKFLOWS"
if [ ! -f "$APP_WORKFLOWS/sulphur_ltx23_i2v_distilled.json" ]; then
cat > "$APP_WORKFLOWS/sulphur_ltx23_i2v_distilled.json" <<'WORKFLOW_EOF_0'
{
  "id": "00000000-0000-0000-0000-000000000000",
  "revision": 0,
  "last_node_id": 75,
  "last_link_id": 137,
  "nodes": [
    {
      "id": 1,
      "type": "RandomNoise",
      "pos": [
        100,
        130
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            111
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "RandomNoise",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        583502427360064,
        "randomize"
      ]
    },
    {
      "id": 3,
      "type": "LTXVConcatAVLatent",
      "pos": [
        4994.900003051757,
        130
      ],
      "size": [
        181.33333435058594,
        46
      ],
      "flags": {},
      "order": 45,
      "mode": 0,
      "inputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "link": 69
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "link": 70
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            115
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVConcatAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 4,
      "type": "LTXVAudioVAELoader",
      "pos": [
        100,
        554
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "Audio VAE",
          "type": "VAE",
          "links": [
            98,
            109
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVAudioVAELoader",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "ltx-2.3-22b-dev-fp8.safetensors"
      ]
    },
    {
      "id": 5,
      "type": "LTXAVTextEncoderLoader",
      "pos": [
        100,
        742
      ],
      "size": [
        318.4500030517578,
        106
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            102,
            121
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXAVTextEncoderLoader",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "gemma_3_12B_it_fp4_mixed.safetensors",
        "ltx-2.3-22b-dev-fp8.safetensors",
        "default"
      ]
    },
    {
      "id": 6,
      "type": "KSamplerSelect",
      "pos": [
        100,
        978
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            113
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "KSamplerSelect",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "euler_ancestral_cfg_pp"
      ]
    },
    {
      "id": 7,
      "type": "ManualSigmas",
      "pos": [
        100,
        1166
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            114
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "0.85, 0.7250, 0.4219, 0.0"
      ]
    },
    {
      "id": 8,
      "type": "CFGGuider",
      "pos": [
        4624.900003051757,
        130
      ],
      "size": [
        270,
        98
      ],
      "flags": {},
      "order": 43,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 71
        },
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 72
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 73
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            112
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CFGGuider",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        1
      ]
    },
    {
      "id": 9,
      "type": "SamplerCustomAdvanced",
      "pos": [
        3731.333334350586,
        130
      ],
      "size": [
        212.38333740234376,
        106
      ],
      "flags": {},
      "order": 39,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 74
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 75
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 76
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 77
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 78
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            110
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "SamplerCustomAdvanced",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 10,
      "type": "LTXVCropGuides",
      "pos": [
        4337.050006103515,
        130
      ],
      "size": [
        152.70000305175782,
        66
      ],
      "flags": {},
      "order": 41,
      "mode": 0,
      "inputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 79
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 80
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 81
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            72
          ]
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "links": [
            73
          ]
        },
        {
          "name": "latent",
          "type": "LATENT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVCropGuides",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 13,
      "type": "LTXVLatentUpsampler",
      "pos": [
        4337.050006103515,
        326
      ],
      "size": [
        187.8499969482422,
        66
      ],
      "flags": {},
      "order": 42,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 82
        },
        {
          "name": "upscale_model",
          "type": "LATENT_UPSCALE_MODEL",
          "link": 83
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 84
        }
      ],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            87
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVLatentUpsampler",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 14,
      "type": "LTXVImgToVideoInplace",
      "pos": [
        4624.900003051757,
        358
      ],
      "size": [
        270,
        122
      ],
      "flags": {},
      "order": 44,
      "mode": 0,
      "inputs": [
        {
          "name": "vae",
          "type": "VAE",
          "link": 85
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 86
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 87
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            69
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVImgToVideoInplace",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        1,
        false
      ]
    },
    {
      "id": 15,
      "type": "LTXVPreprocess",
      "pos": [
        1100,
        998
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 24,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 88
        }
      ],
      "outputs": [
        {
          "name": "output_image",
          "type": "IMAGE",
          "links": [
            86,
            133
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVPreprocess",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        38
      ]
    },
    {
      "id": 17,
      "type": "KSamplerSelect",
      "pos": [
        100,
        1354
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            76
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "KSamplerSelect",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "euler_ancestral_cfg_pp"
      ]
    },
    {
      "id": 18,
      "type": "ComfyMathExpression",
      "pos": [
        1840,
        358
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 33,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 89
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": null
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            91
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "a/2"
      ]
    },
    {
      "id": 20,
      "type": "ComfyMathExpression",
      "pos": [
        1840,
        688
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 34,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 90
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": null
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            92
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "a/2"
      ]
    },
    {
      "id": 21,
      "type": "EmptyLTXVLatentVideo",
      "pos": [
        2340,
        130
      ],
      "size": [
        270,
        130
      ],
      "flags": {},
      "order": 35,
      "mode": 0,
      "inputs": [
        {
          "name": "width",
          "type": "INT",
          "widget": {
            "name": "width"
          },
          "link": 91
        },
        {
          "name": "height",
          "type": "INT",
          "widget": {
            "name": "height"
          },
          "link": 92
        },
        {
          "name": "length",
          "type": "INT",
          "widget": {
            "name": "length"
          },
          "link": 93
        }
      ],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            96
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "EmptyLTXVLatentVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        768,
        512,
        97,
        1
      ]
    },
    {
      "id": 22,
      "type": "LTXVImgToVideoInplace",
      "pos": [
        2710,
        130
      ],
      "size": [
        270,
        122
      ],
      "flags": {},
      "order": 36,
      "mode": 0,
      "inputs": [
        {
          "name": "vae",
          "type": "VAE",
          "link": 94
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 95
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 96
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            105
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVImgToVideoInplace",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        0.8,
        false
      ]
    },
    {
      "id": 23,
      "type": "LTXVAudioVAEDecode",
      "pos": [
        5881.950009155272,
        306
      ],
      "size": [
        203.00000610351563,
        46
      ],
      "flags": {},
      "order": 49,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 97
        },
        {
          "label": "Audio VAE",
          "name": "audio_vae",
          "type": "VAE",
          "link": 98
        }
      ],
      "outputs": [
        {
          "name": "Audio",
          "type": "AUDIO",
          "links": [
            119
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVAudioVAEDecode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 24,
      "type": "ComfyMathExpression",
      "pos": [
        600,
        460
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 18,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 99
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": [
            117
          ]
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            108
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "a"
      ]
    },
    {
      "id": 25,
      "type": "PrimitiveInt",
      "pos": [
        1470,
        954
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 31,
      "mode": 0,
      "inputs": [
        {
          "name": "value",
          "type": "INT",
          "widget": {
            "name": "value"
          },
          "link": 100
        }
      ],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            90
          ]
        }
      ],
      "title": "Height",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        -282918202334433,
        "randomize"
      ]
    },
    {
      "id": 30,
      "type": "CLIPTextEncode",
      "pos": [
        600,
        790
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 20,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 102
        },
        {
          "name": "text",
          "type": "STRING",
          "widget": {
            "name": "text"
          },
          "link": 101
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            103
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CLIPTextEncode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        ""
      ]
    },
    {
      "id": 31,
      "type": "LTXVConditioning",
      "pos": [
        1100,
        366
      ],
      "size": [
        270,
        78
      ],
      "flags": {},
      "order": 26,
      "mode": 0,
      "inputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 103
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 104
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            79,
            123
          ]
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "links": [
            80,
            124
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVConditioning",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        24
      ]
    },
    {
      "id": 32,
      "type": "LTXVConcatAVLatent",
      "pos": [
        3080,
        130
      ],
      "size": [
        181.33333435058594,
        46
      ],
      "flags": {},
      "order": 37,
      "mode": 0,
      "inputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "link": 105
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "link": 106
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            78,
            127
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVConcatAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 33,
      "type": "LTXVEmptyLatentAudio",
      "pos": [
        1100,
        130
      ],
      "size": [
        270,
        106
      ],
      "flags": {},
      "order": 23,
      "mode": 0,
      "inputs": [
        {
          "label": "Audio VAE",
          "name": "audio_vae",
          "type": "VAE",
          "link": 109
        },
        {
          "name": "frames_number",
          "type": "INT",
          "widget": {
            "name": "frames_number"
          },
          "link": 107
        },
        {
          "name": "frame_rate",
          "type": "INT",
          "widget": {
            "name": "frame_rate"
          },
          "link": 108
        }
      ],
      "outputs": [
        {
          "name": "Latent",
          "type": "LATENT",
          "links": [
            106
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVEmptyLatentAudio",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        97,
        25,
        1
      ]
    },
    {
      "id": 35,
      "type": "LTXVSeparateAVLatent",
      "pos": [
        4043.71667175293,
        130
      ],
      "size": [
        193.33333435058594,
        46
      ],
      "flags": {},
      "order": 40,
      "mode": 0,
      "inputs": [
        {
          "name": "av_latent",
          "type": "LATENT",
          "link": 110
        }
      ],
      "outputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "links": [
            81,
            82
          ]
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "links": [
            70
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVSeparateAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 36,
      "type": "SamplerCustomAdvanced",
      "pos": [
        5276.233337402343,
        130
      ],
      "size": [
        212.38333740234376,
        106
      ],
      "flags": {},
      "order": 46,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 111
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 112
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 113
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 114
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 115
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            116
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "SamplerCustomAdvanced",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 37,
      "type": "LTXVSeparateAVLatent",
      "pos": [
        5588.616674804686,
        130
      ],
      "size": [
        193.33333435058594,
        46
      ],
      "flags": {},
      "order": 47,
      "mode": 0,
      "inputs": [
        {
          "name": "av_latent",
          "type": "LATENT",
          "link": 116
        }
      ],
      "outputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "links": [
            134
          ]
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "links": [
            97
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVSeparateAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 38,
      "type": "CreateVideo",
      "pos": [
        6184.950015258787,
        130
      ],
      "size": [
        270,
        78
      ],
      "flags": {},
      "order": 50,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 118
        },
        {
          "name": "audio",
          "shape": 7,
          "type": "AUDIO",
          "link": 119
        },
        {
          "name": "fps",
          "type": "FLOAT",
          "widget": {
            "name": "fps"
          },
          "link": 117
        }
      ],
      "outputs": [
        {
          "name": "VIDEO",
          "type": "VIDEO",
          "links": [
            125
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CreateVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        30
      ]
    },
    {
      "id": 39,
      "type": "LatentUpscaleModelLoader",
      "pos": [
        100,
        2296
      ],
      "size": [
        280.9166625976562,
        58
      ],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "LATENT_UPSCALE_MODEL",
          "type": "LATENT_UPSCALE_MODEL",
          "links": [
            83
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LatentUpscaleModelLoader",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
      ]
    },
    {
      "id": 40,
      "type": "PrimitiveInt",
      "pos": [
        1470,
        742
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 30,
      "mode": 0,
      "inputs": [
        {
          "name": "value",
          "type": "INT",
          "widget": {
            "name": "value"
          },
          "link": 120
        }
      ],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            89
          ]
        }
      ],
      "title": "Width",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        526344308052355,
        "randomize"
      ]
    },
    {
      "id": 41,
      "type": "CLIPTextEncode",
      "pos": [
        600,
        130
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 16,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 121
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            104
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CLIPTextEncode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "pc game, console game, video game, cartoon, childish, ugly"
      ]
    },
    {
      "id": 42,
      "type": "CFGGuider",
      "pos": [
        1840,
        130
      ],
      "size": [
        270,
        98
      ],
      "flags": {},
      "order": 32,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 122
        },
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 123
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 124
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            75
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CFGGuider",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        1
      ]
    },
    {
      "id": 43,
      "type": "VAEDecodeTiled",
      "pos": [
        100,
        2484
      ],
      "size": [
        270,
        150
      ],
      "flags": {},
      "order": 7,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": null
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "VAEDecodeTiled",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        768,
        64,
        4096,
        4
      ]
    },
    {
      "id": 44,
      "type": "CheckpointLoaderSimple",
      "pos": [
        100,
        2764
      ],
      "size": [
        270,
        98
      ],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            136
          ]
        },
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": null
        },
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            84,
            85,
            94,
            135
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "CheckpointLoaderSimple",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "ltx-2.3-22b-dev-fp8.safetensors"
      ]
    },
    {
      "id": 45,
      "type": "SaveVideo",
      "pos": [
        6554.950015258787,
        130
      ],
      "size": [
        270,
        368
      ],
      "flags": {},
      "order": 51,
      "mode": 0,
      "inputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "link": 125
        }
      ],
      "outputs": [],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "SaveVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "video/LTX_2.3_t2v",
        "auto",
        "auto"
      ]
    },
    {
      "id": 47,
      "type": "LTXVScheduler",
      "pos": [
        3361.333334350586,
        130
      ],
      "size": [
        270,
        154
      ],
      "flags": {},
      "order": 38,
      "mode": 0,
      "inputs": [
        {
          "name": "latent",
          "shape": 7,
          "type": "LATENT",
          "link": 127
        }
      ],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            77
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LTXVScheduler",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        8,
        4,
        1.5,
        true,
        0.1
      ]
    },
    {
      "id": 58,
      "type": "ManualSigmas",
      "pos": [
        100,
        2992
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 9,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "0.85, 0.7933, 0.68, 0.51, 0.2833, 0.0"
      ]
    },
    {
      "id": 65,
      "type": "ManualSigmas",
      "pos": [
        100,
        3180
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 10,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "0.8, 0.55, 0.25, 0.0"
      ]
    },
    {
      "id": 68,
      "type": "ResizeImageResolution",
      "pos": [
        600,
        1332
      ],
      "size": [
        294.8833374023437,
        82
      ],
      "flags": {},
      "order": 19,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 131
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            88,
            132
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-logicutils",
        "ver": "f77c699543b8f9977b24581af66ad026d340b663",
        "Node name for S&R": "ResizeImageResolution",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        1024,
        "NEAREST"
      ]
    },
    {
      "id": 69,
      "type": "GetImageSize",
      "pos": [
        1100,
        1186
      ],
      "size": [
        140,
        66
      ],
      "flags": {},
      "order": 25,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 132
        }
      ],
      "outputs": [
        {
          "name": "width",
          "type": "INT",
          "links": [
            120
          ]
        },
        {
          "name": "height",
          "type": "INT",
          "links": [
            100
          ]
        },
        {
          "name": "batch_size",
          "type": "INT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "GetImageSize",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 70,
      "type": "ImageScaleDownBy",
      "pos": [
        1470,
        554
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 29,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 133
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            95
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-art-venture",
        "ver": "210dc072b1f103f91be18a33bdeb13ab315aaae5",
        "Node name for S&R": "ImageScaleDownBy",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        0.5
      ]
    },
    {
      "id": 73,
      "type": "VAEDecode",
      "pos": [
        5881.950009155272,
        130
      ],
      "size": [
        140,
        46
      ],
      "flags": {},
      "order": 48,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 134
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 135
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            118
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "VAEDecode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": []
    },
    {
      "id": 59,
      "type": "LoraLoaderModelOnly",
      "pos": [
        1100,
        574
      ],
      "size": [
        353.35219381985416,
        82
      ],
      "flags": {},
      "order": 21,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 129
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            126
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "ltx23/ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors",
        0.7
      ]
    },
    {
      "id": 60,
      "type": "LoraLoaderModelOnly",
      "pos": [
        1100,
        786
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 22,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 130
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            128
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "sulphur_lora_rank_768.safetensors",
        1
      ]
    },
    {
      "id": 49,
      "type": "LoraLoaderModelOnly",
      "pos": [
        1470,
        342
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 28,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 128
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            71
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "ltx23/ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors",
        0.5
      ]
    },
    {
      "id": 46,
      "type": "LoraLoaderModelOnly",
      "pos": [
        1470,
        130
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 27,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 126
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            122
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "sulphur_lora_rank_768.safetensors",
        1
      ]
    },
    {
      "id": 26,
      "type": "PrimitiveInt",
      "pos": [
        100,
        1542
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 11,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            99
          ]
        }
      ],
      "title": "Frame Rate",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        24,
        "fixed"
      ]
    },
    {
      "id": 27,
      "type": "PrimitiveInt",
      "pos": [
        100,
        1754
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 12,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            93,
            107
          ]
        }
      ],
      "title": "Length",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        241,
        "fixed"
      ]
    },
    {
      "id": 2,
      "type": "RandomNoise",
      "pos": [
        100,
        342
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 13,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            74
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "RandomNoise",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        354250315970852,
        "randomize"
      ]
    },
    {
      "id": 67,
      "type": "LoadImage",
      "pos": [
        100,
        3368
      ],
      "size": [
        270,
        102
      ],
      "flags": {},
      "order": 14,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            131
          ]
        },
        {
          "name": "MASK",
          "type": "MASK",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "LoadImage",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "your_image.png",
        "image"
      ]
    },
    {
      "id": 29,
      "type": "PrimitiveStringMultiline",
      "pos": [
        100,
        1966
      ],
      "size": [
        400,
        200
      ],
      "flags": {},
      "order": 15,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "STRING",
          "type": "STRING",
          "links": [
            101
          ]
        }
      ],
      "title": "Prompt",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.18.2",
        "Node name for S&R": "PrimitiveStringMultiline",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "The woman takes of her shirt, exposing her breasts to the viewer"
      ],
      "color": "#232",
      "bgcolor": "#353"
    },
    {
      "id": 74,
      "type": "PathchSageAttentionKJ",
      "pos": [
        600,
        1120
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 17,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 136
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            137
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-kjnodes",
        "ver": "d0d61754bf7fa57f2abb4714cdf79058f5862a55",
        "Node name for S&R": "PathchSageAttentionKJ",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.8"
        }
      },
      "widgets_values": [
        "disabled",
        false
      ]
    },
    {
      "id": 75,
      "type": "Power Lora Loader (rgthree)",
      "pos": [
        600,
        790
      ],
      "size": [
        380,
        170
      ],
      "flags": {},
      "order": 18,
      "mode": 0,
      "title": "Your LoRAs (click + Add Lora)",
      "inputs": [
        {
          "dir": 3,
          "name": "model",
          "type": "MODEL",
          "link": 137
        },
        {
          "dir": 3,
          "name": "clip",
          "type": "CLIP",
          "link": null
        }
      ],
      "outputs": [
        {
          "dir": 4,
          "name": "MODEL",
          "shape": 3,
          "type": "MODEL",
          "links": [
            129,
            130
          ]
        },
        {
          "dir": 4,
          "name": "CLIP",
          "shape": 3,
          "type": "CLIP",
          "links": null
        }
      ],
      "properties": {
        "aux_id": "rgthree/rgthree-comfy",
        "Show Strengths": "Single Strength",
        "Match": ""
      },
      "color": "#223",
      "bgcolor": "#335",
      "widgets_values": [
        {},
        {
          "type": "PowerLoraLoaderHeaderWidget"
        },
        {},
        ""
      ]
    }
  ],
  "links": [
    [
      69,
      14,
      0,
      3,
      0,
      "LATENT"
    ],
    [
      70,
      35,
      1,
      3,
      1,
      "LATENT"
    ],
    [
      71,
      49,
      0,
      8,
      0,
      "MODEL"
    ],
    [
      72,
      10,
      0,
      8,
      1,
      "CONDITIONING"
    ],
    [
      73,
      10,
      1,
      8,
      2,
      "CONDITIONING"
    ],
    [
      74,
      2,
      0,
      9,
      0,
      "NOISE"
    ],
    [
      75,
      42,
      0,
      9,
      1,
      "GUIDER"
    ],
    [
      76,
      17,
      0,
      9,
      2,
      "SAMPLER"
    ],
    [
      77,
      47,
      0,
      9,
      3,
      "SIGMAS"
    ],
    [
      78,
      32,
      0,
      9,
      4,
      "LATENT"
    ],
    [
      79,
      31,
      0,
      10,
      0,
      "CONDITIONING"
    ],
    [
      80,
      31,
      1,
      10,
      1,
      "CONDITIONING"
    ],
    [
      81,
      35,
      0,
      10,
      2,
      "LATENT"
    ],
    [
      82,
      35,
      0,
      13,
      0,
      "LATENT"
    ],
    [
      83,
      39,
      0,
      13,
      1,
      "LATENT_UPSCALE_MODEL"
    ],
    [
      84,
      44,
      2,
      13,
      2,
      "VAE"
    ],
    [
      85,
      44,
      2,
      14,
      0,
      "VAE"
    ],
    [
      86,
      15,
      0,
      14,
      1,
      "IMAGE"
    ],
    [
      87,
      13,
      0,
      14,
      2,
      "LATENT"
    ],
    [
      88,
      68,
      0,
      15,
      0,
      "IMAGE"
    ],
    [
      89,
      40,
      0,
      18,
      0,
      "INT"
    ],
    [
      90,
      25,
      0,
      20,
      0,
      "INT"
    ],
    [
      91,
      18,
      1,
      21,
      0,
      "INT"
    ],
    [
      92,
      20,
      1,
      21,
      1,
      "INT"
    ],
    [
      93,
      27,
      0,
      21,
      2,
      "INT"
    ],
    [
      94,
      44,
      2,
      22,
      0,
      "VAE"
    ],
    [
      95,
      70,
      0,
      22,
      1,
      "IMAGE"
    ],
    [
      96,
      21,
      0,
      22,
      2,
      "LATENT"
    ],
    [
      97,
      37,
      1,
      23,
      0,
      "LATENT"
    ],
    [
      98,
      4,
      0,
      23,
      1,
      "VAE"
    ],
    [
      99,
      26,
      0,
      24,
      0,
      "INT"
    ],
    [
      100,
      69,
      1,
      25,
      0,
      "INT"
    ],
    [
      101,
      29,
      0,
      30,
      1,
      "STRING"
    ],
    [
      102,
      5,
      0,
      30,
      0,
      "CLIP"
    ],
    [
      103,
      30,
      0,
      31,
      0,
      "CONDITIONING"
    ],
    [
      104,
      41,
      0,
      31,
      1,
      "CONDITIONING"
    ],
    [
      105,
      22,
      0,
      32,
      0,
      "LATENT"
    ],
    [
      106,
      33,
      0,
      32,
      1,
      "LATENT"
    ],
    [
      107,
      27,
      0,
      33,
      1,
      "INT"
    ],
    [
      108,
      24,
      1,
      33,
      2,
      "INT"
    ],
    [
      109,
      4,
      0,
      33,
      0,
      "VAE"
    ],
    [
      110,
      9,
      0,
      35,
      0,
      "LATENT"
    ],
    [
      111,
      1,
      0,
      36,
      0,
      "NOISE"
    ],
    [
      112,
      8,
      0,
      36,
      1,
      "GUIDER"
    ],
    [
      113,
      6,
      0,
      36,
      2,
      "SAMPLER"
    ],
    [
      114,
      7,
      0,
      36,
      3,
      "SIGMAS"
    ],
    [
      115,
      3,
      0,
      36,
      4,
      "LATENT"
    ],
    [
      116,
      36,
      0,
      37,
      0,
      "LATENT"
    ],
    [
      117,
      24,
      0,
      38,
      2,
      "FLOAT"
    ],
    [
      118,
      73,
      0,
      38,
      0,
      "IMAGE"
    ],
    [
      119,
      23,
      0,
      38,
      1,
      "AUDIO"
    ],
    [
      120,
      69,
      0,
      40,
      0,
      "INT"
    ],
    [
      121,
      5,
      0,
      41,
      0,
      "CLIP"
    ],
    [
      122,
      46,
      0,
      42,
      0,
      "MODEL"
    ],
    [
      123,
      31,
      0,
      42,
      1,
      "CONDITIONING"
    ],
    [
      124,
      31,
      1,
      42,
      2,
      "CONDITIONING"
    ],
    [
      125,
      38,
      0,
      45,
      0,
      "VIDEO"
    ],
    [
      126,
      59,
      0,
      46,
      0,
      "MODEL"
    ],
    [
      127,
      32,
      0,
      47,
      0,
      "LATENT"
    ],
    [
      128,
      60,
      0,
      49,
      0,
      "MODEL"
    ],
    [
      129,
      75,
      0,
      59,
      0,
      "MODEL"
    ],
    [
      130,
      75,
      0,
      60,
      0,
      "MODEL"
    ],
    [
      131,
      67,
      0,
      68,
      0,
      "IMAGE"
    ],
    [
      132,
      68,
      0,
      69,
      0,
      "IMAGE"
    ],
    [
      133,
      15,
      0,
      70,
      0,
      "IMAGE"
    ],
    [
      134,
      37,
      0,
      73,
      0,
      "LATENT"
    ],
    [
      135,
      44,
      2,
      73,
      1,
      "VAE"
    ],
    [
      136,
      44,
      0,
      74,
      0,
      "MODEL"
    ],
    [
      137,
      74,
      0,
      75,
      0,
      "MODEL"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {
    "ue_links": [],
    "ds": {
      "scale": 0.7110762169468995,
      "offset": [
        -4814.316727263041,
        516.1340178453138
      ]
    },
    "links_added_by_ue": [],
    "frontendVersion": "1.42.8",
    "VHS_latentpreview": false,
    "VHS_latentpreviewrate": 0,
    "VHS_MetadataImage": true,
    "VHS_KeepIntermediate": true
  },
  "version": 0.4
}
WORKFLOW_EOF_0
fi
if [ ! -f "$APP_WORKFLOWS/sulphur_ltx23_i2v_base.json" ]; then
cat > "$APP_WORKFLOWS/sulphur_ltx23_i2v_base.json" <<'WORKFLOW_EOF_1'
{
  "id": "1fc90497-0a6e-49da-a848-5e9a71dfae1c",
  "revision": 0,
  "last_node_id": 71,
  "last_link_id": 120,
  "nodes": [
    {
      "id": 3,
      "type": "LTXVConcatAVLatent",
      "pos": [
        5880.670120534078,
        4864.087071545735
      ],
      "size": [
        270,
        60
      ],
      "flags": {},
      "order": 47,
      "mode": 0,
      "inputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "link": 1
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "link": 2
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            54
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "LTXVConcatAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 4,
      "type": "LTXVAudioVAELoader",
      "pos": [
        2790.669915402209,
        4624.086916856088
      ],
      "size": [
        420,
        68.88020833333334
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "Audio VAE",
          "type": "VAE",
          "links": [
            37,
            46
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LTXVAudioVAELoader",
        "models": [
          {
            "name": "ltx-2.3-22b-dev-fp8.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors",
            "directory": "checkpoints"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx-2.3-22b-dev-fp8.safetensors"
      ]
    },
    {
      "id": 9,
      "type": "SamplerCustomAdvanced",
      "pos": [
        4663.003365446446,
        4297.115751528979
      ],
      "size": [
        213.125,
        321.125
      ],
      "flags": {},
      "order": 41,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 6
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 7
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 8
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 71
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 10
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            49
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.60",
        "Node name for S&R": "SamplerCustomAdvanced",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 10,
      "type": "LTXVCropGuides",
      "pos": [
        5003.002813944201,
        4477.115867546215
      ],
      "size": [
        240,
        80
      ],
      "flags": {},
      "order": 43,
      "mode": 0,
      "inputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 11
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 12
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 13
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            4
          ]
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "links": [
            5
          ]
        },
        {
          "name": "latent",
          "type": "LATENT",
          "slot_index": 2,
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LTXVCropGuides",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 13,
      "type": "LTXVLatentUpsampler",
      "pos": [
        5420.670174339184,
        4554.086906767633
      ],
      "size": [
        320,
        80
      ],
      "flags": {},
      "order": 44,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 16
        },
        {
          "name": "upscale_model",
          "type": "LATENT_UPSCALE_MODEL",
          "link": 17
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 18
        }
      ],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            21
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.14.1",
        "Node name for S&R": "LTXVLatentUpsampler",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 18,
      "type": "ComfyMathExpression",
      "pos": [
        3686.595361217282,
        5159.689419347806
      ],
      "size": [
        210,
        74
      ],
      "flags": {
        "collapsed": true
      },
      "order": 35,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 26
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": null
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            29
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "a/2"
      ]
    },
    {
      "id": 19,
      "type": "Reroute",
      "pos": [
        5113.002289344508,
        4717.115812059704
      ],
      "size": [
        75,
        26
      ],
      "flags": {},
      "order": 19,
      "mode": 0,
      "inputs": [
        {
          "name": "",
          "type": "*",
          "link": 27
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "VAE",
          "links": [
            18,
            19,
            64
          ]
        }
      ],
      "properties": {
        "showOutputText": false,
        "horizontal": false,
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        }
      }
    },
    {
      "id": 20,
      "type": "ComfyMathExpression",
      "pos": [
        3696.595361217282,
        5219.689419347806
      ],
      "size": [
        210,
        74
      ],
      "flags": {
        "collapsed": true
      },
      "order": 36,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 28
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": null
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            30
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "a/2"
      ]
    },
    {
      "id": 21,
      "type": "EmptyLTXVLatentVideo",
      "pos": [
        4006.2826404334255,
        5344.7618986551115
      ],
      "size": [
        270,
        146.66666666666669
      ],
      "flags": {},
      "order": 37,
      "mode": 0,
      "inputs": [
        {
          "name": "width",
          "type": "INT",
          "widget": {
            "name": "width"
          },
          "link": 29
        },
        {
          "name": "height",
          "type": "INT",
          "widget": {
            "name": "height"
          },
          "link": 30
        },
        {
          "name": "length",
          "type": "INT",
          "widget": {
            "name": "length"
          },
          "link": 31
        }
      ],
      "outputs": [
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            34
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.60",
        "Node name for S&R": "EmptyLTXVLatentVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        768,
        512,
        97,
        1
      ]
    },
    {
      "id": 23,
      "type": "LTXVAudioVAEDecode",
      "pos": [
        6906.595361217282,
        4509.689419347806
      ],
      "size": [
        265.8984375,
        60
      ],
      "flags": {},
      "order": 51,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 36
        },
        {
          "label": "Audio VAE",
          "name": "audio_vae",
          "type": "VAE",
          "link": 37
        }
      ],
      "outputs": [
        {
          "name": "Audio",
          "type": "AUDIO",
          "links": [
            57
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXVAudioVAEDecode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 24,
      "type": "ComfyMathExpression",
      "pos": [
        3686.595361217282,
        5359.689419347806
      ],
      "size": [
        210,
        74
      ],
      "flags": {
        "collapsed": true
      },
      "order": 17,
      "mode": 0,
      "inputs": [
        {
          "label": "a",
          "name": "values.a",
          "type": "FLOAT,INT",
          "link": 38
        },
        {
          "label": "b",
          "name": "values.b",
          "shape": 7,
          "type": "FLOAT,INT",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "FLOAT",
          "type": "FLOAT",
          "links": [
            58
          ]
        },
        {
          "name": "INT",
          "type": "INT",
          "links": [
            48
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "ComfyMathExpression",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "a"
      ]
    },
    {
      "id": 26,
      "type": "PrimitiveInt",
      "pos": [
        2336.595361217282,
        5319.689419347806
      ],
      "size": [
        360,
        82
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            38
          ]
        }
      ],
      "title": "Frame Rate",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        24,
        "fixed"
      ]
    },
    {
      "id": 33,
      "type": "LTXVEmptyLatentAudio",
      "pos": [
        4006.2826404334255,
        5174.7618986551115
      ],
      "size": [
        270,
        120
      ],
      "flags": {},
      "order": 23,
      "mode": 0,
      "inputs": [
        {
          "name": "audio_vae",
          "type": "VAE",
          "link": 46
        },
        {
          "name": "frames_number",
          "type": "INT",
          "widget": {
            "name": "frames_number"
          },
          "link": 47
        },
        {
          "name": "frame_rate",
          "type": "INT",
          "widget": {
            "name": "frame_rate"
          },
          "link": 48
        }
      ],
      "outputs": [
        {
          "name": "Latent",
          "type": "LATENT",
          "links": [
            45
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LTXVEmptyLatentAudio",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        97,
        25,
        1
      ]
    },
    {
      "id": 35,
      "type": "LTXVSeparateAVLatent",
      "pos": [
        4998.928242945224,
        4302.718304462968
      ],
      "size": [
        240,
        60
      ],
      "flags": {},
      "order": 42,
      "mode": 0,
      "inputs": [
        {
          "name": "av_latent",
          "type": "LATENT",
          "link": 49
        }
      ],
      "outputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "links": [
            13,
            16
          ]
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "links": [
            2
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "LTXVSeparateAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 37,
      "type": "LTXVSeparateAVLatent",
      "pos": [
        6566.595361217282,
        4289.689419347806
      ],
      "size": [
        193.33333435058594,
        60
      ],
      "flags": {},
      "order": 49,
      "mode": 0,
      "inputs": [
        {
          "name": "av_latent",
          "type": "LATENT",
          "link": 55
        }
      ],
      "outputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "links": [
            63
          ]
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "links": [
            36
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "LTXVSeparateAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 39,
      "type": "LatentUpscaleModelLoader",
      "pos": [
        2796.595361217282,
        4929.689419347806
      ],
      "size": [
        400,
        68.88020833333334
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "LATENT_UPSCALE_MODEL",
          "type": "LATENT_UPSCALE_MODEL",
          "links": [
            17
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LatentUpscaleModelLoader",
        "models": [
          {
            "name": "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
            "directory": "latent_upscale_models"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
      ]
    },
    {
      "id": 41,
      "type": "CLIPTextEncode",
      "pos": [
        3329.7889603347535,
        4776.827954203707
      ],
      "size": [
        590,
        160
      ],
      "flags": {},
      "order": 20,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 59
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            42
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "CLIPTextEncode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "pc game, console game, video game, cartoon, childish, ugly"
      ],
      "color": "#323",
      "bgcolor": "#535"
    },
    {
      "id": 38,
      "type": "CreateVideo",
      "pos": [
        6876.595361217282,
        5249.689419347806
      ],
      "size": [
        270,
        86.66666666666667
      ],
      "flags": {},
      "order": 52,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 56
        },
        {
          "name": "audio",
          "shape": 7,
          "type": "AUDIO",
          "link": 57
        },
        {
          "name": "fps",
          "type": "FLOAT",
          "widget": {
            "name": "fps"
          },
          "link": 58
        }
      ],
      "outputs": [
        {
          "name": "VIDEO",
          "type": "VIDEO",
          "links": [
            65
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "CreateVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        24
      ]
    },
    {
      "id": 17,
      "type": "KSamplerSelect",
      "pos": [
        4263.002827395487,
        4617.115887723123
      ],
      "size": [
        270,
        68.88020833333334
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            8
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "KSamplerSelect",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "euler_ancestral"
      ]
    },
    {
      "id": 32,
      "type": "LTXVConcatAVLatent",
      "pos": [
        4426.282640433423,
        5214.7618986551115
      ],
      "size": [
        187.5,
        60
      ],
      "flags": {},
      "order": 39,
      "mode": 0,
      "inputs": [
        {
          "name": "video_latent",
          "type": "LATENT",
          "link": 44
        },
        {
          "name": "audio_latent",
          "type": "LATENT",
          "link": 45
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            10,
            72
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXVConcatAVLatent",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 6,
      "type": "KSamplerSelect",
      "pos": [
        5880.670120534078,
        4604.086974024002
      ],
      "size": [
        270,
        68.88020833333334
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            52
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.75",
        "Node name for S&R": "KSamplerSelect",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "lcm"
      ]
    },
    {
      "id": 8,
      "type": "CFGGuider",
      "pos": [
        5912.599959001766,
        4423.823877234353
      ],
      "size": [
        270,
        106.66666666666667
      ],
      "flags": {},
      "order": 45,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 74
        },
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 4
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 5
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            51
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.71",
        "Node name for S&R": "CFGGuider",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        1
      ]
    },
    {
      "id": 31,
      "type": "LTXVConditioning",
      "pos": [
        3949.7889603347517,
        4466.827954203707
      ],
      "size": [
        270,
        86.66666666666667
      ],
      "flags": {},
      "order": 28,
      "mode": 0,
      "inputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 41
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 42
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            11,
            61
          ]
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "links": [
            12,
            62
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "LTXVConditioning",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        24
      ]
    },
    {
      "id": 11,
      "type": "LoraLoaderModelOnly",
      "pos": [
        2773.1336757485674,
        4476.085433610091
      ],
      "size": [
        420,
        95.546875
      ],
      "flags": {},
      "order": 5,
      "mode": 4,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.75",
        "Node name for S&R": "LoraLoaderModelOnly",
        "models": [
          {
            "name": "ltx-2.3-22b-distilled-lora-384.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384.safetensors",
            "directory": "loras"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx-2.3-22b-distilled-lora-384.safetensors",
        0.5
      ]
    },
    {
      "id": 42,
      "type": "CFGGuider",
      "pos": [
        4263.002827395487,
        4457.1159247141295
      ],
      "size": [
        270,
        106.66666666666667
      ],
      "flags": {},
      "order": 34,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 91
        },
        {
          "name": "positive",
          "type": "CONDITIONING",
          "link": 61
        },
        {
          "name": "negative",
          "type": "CONDITIONING",
          "link": 62
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            7
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.64",
        "Node name for S&R": "CFGGuider",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        3.6
      ]
    },
    {
      "id": 59,
      "type": "LoraLoaderModelOnly",
      "pos": [
        3925.267489279434,
        3915.3128510626825
      ],
      "size": [
        520,
        82
      ],
      "flags": {},
      "order": 25,
      "mode": 4,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 102
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            92
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "models": [
          {
            "name": "ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left/resolve/main/ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "directory": "loras"
          }
        ],
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx-2.3-22b-distilled-lora-384.safetensors",
        0.4
      ]
    },
    {
      "id": 43,
      "type": "VAEDecodeTiled",
      "pos": [
        6906.254137353754,
        4292.4490696725115
      ],
      "size": [
        270,
        150
      ],
      "flags": {},
      "order": 50,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 63
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 64
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            56
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.14.1",
        "Node name for S&R": "VAEDecodeTiled",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        768,
        64,
        4096,
        4
      ]
    },
    {
      "id": 30,
      "type": "CLIPTextEncode",
      "pos": [
        3336.48484479923,
        4295.310146525117
      ],
      "size": [
        600,
        380
      ],
      "flags": {},
      "order": 22,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 39
        },
        {
          "name": "text",
          "type": "STRING",
          "widget": {
            "name": "text"
          },
          "link": 40
        }
      ],
      "outputs": [
        {
          "name": "CONDITIONING",
          "type": "CONDITIONING",
          "links": [
            41
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "CLIPTextEncode",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        ""
      ],
      "color": "#232",
      "bgcolor": "#353"
    },
    {
      "id": 63,
      "type": "VAELoader",
      "pos": [
        3414.926988071283,
        3611.6877123439103
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            100
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "VAELoader",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.7",
          "input_ue_unconnectable": {}
        }
      },
      "widgets_values": [
        "taeltx2_3.safetensors"
      ]
    },
    {
      "id": 64,
      "type": "LTX2SamplingPreviewOverride",
      "pos": [
        3892.195479122999,
        3665.280447781146
      ],
      "size": [
        316.6166595458984,
        98
      ],
      "flags": {},
      "order": 18,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 103
        },
        {
          "name": "latent_upscale_model",
          "shape": 7,
          "type": "LATENT_UPSCALE_MODEL",
          "link": null
        },
        {
          "name": "vae",
          "shape": 7,
          "type": "VAE",
          "link": 100
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            120
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-kjnodes",
        "ver": "1.2.6",
        "Node name for S&R": "LTX2SamplingPreviewOverride",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.7",
          "input_ue_unconnectable": {}
        }
      },
      "widgets_values": [
        24
      ]
    },
    {
      "id": 7,
      "type": "ManualSigmas",
      "pos": [
        6224.660410991754,
        4898.071435222228
      ],
      "size": [
        270,
        70
      ],
      "flags": {},
      "order": 7,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "0.85, 0.7250, 0.4219, 0.0"
      ]
    },
    {
      "id": 65,
      "type": "ManualSigmas",
      "pos": [
        6217.247087588566,
        5026.76550550138
      ],
      "size": [
        270,
        70
      ],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "0.8, 0.55, 0.25, 0.0"
      ]
    },
    {
      "id": 1,
      "type": "RandomNoise",
      "pos": [
        5902.5558736697385,
        4275.718965924739
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 9,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            50
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.75",
        "Node name for S&R": "RandomNoise",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        42,
        "fixed"
      ]
    },
    {
      "id": 45,
      "type": "SaveVideo",
      "pos": [
        7369.541094572275,
        4907.865833890682
      ],
      "size": [
        660,
        1253
      ],
      "flags": {
        "collapsed": false
      },
      "order": 53,
      "mode": 0,
      "inputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "link": 65
        }
      ],
      "outputs": [],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.5.1",
        "Node name for S&R": "SaveVideo",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "video/LTX_2.3_t2v",
        "auto",
        "auto"
      ]
    },
    {
      "id": 58,
      "type": "ManualSigmas",
      "pos": [
        6240.851860236549,
        4764.14729890691
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 10,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            107
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.4",
        "Node name for S&R": "ManualSigmas",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.4.1"
        }
      },
      "widgets_values": [
        "0.85, 0.7933, 0.68, 0.51, 0.2833, 0.0"
      ]
    },
    {
      "id": 44,
      "type": "CheckpointLoaderSimple",
      "pos": [
        2814.7492122205467,
        4316.591698272993
      ],
      "size": [
        420,
        108.88020833333334
      ],
      "flags": {},
      "order": 11,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            103
          ]
        },
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": []
        },
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            27,
            32
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "CheckpointLoaderSimple",
        "models": [
          {
            "name": "ltx-2.3-22b-dev-fp8.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors",
            "directory": "checkpoints"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx-2.3-22b-dev-fp8.safetensors"
      ]
    },
    {
      "id": 47,
      "type": "LTXVScheduler",
      "pos": [
        4318.092195490125,
        4750.604726542793
      ],
      "size": [
        270,
        170
      ],
      "flags": {},
      "order": 40,
      "mode": 0,
      "inputs": [
        {
          "name": "latent",
          "shape": 7,
          "type": "LATENT",
          "link": 72
        }
      ],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            71
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "LTXVScheduler",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        50,
        2.72,
        0.8,
        true,
        0
      ]
    },
    {
      "id": 36,
      "type": "SamplerCustomAdvanced",
      "pos": [
        6261.288582068708,
        4238.939740147696
      ],
      "size": [
        212.38333740234376,
        320.3833374023437
      ],
      "flags": {},
      "order": 48,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 50
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 51
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 52
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 107
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 54
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            55
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": []
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.75",
        "Node name for S&R": "SamplerCustomAdvanced",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": []
    },
    {
      "id": 25,
      "type": "PrimitiveInt",
      "pos": [
        2336.595361217282,
        5169.689419347806
      ],
      "size": [
        360,
        82
      ],
      "flags": {},
      "order": 32,
      "mode": 0,
      "inputs": [
        {
          "name": "value",
          "type": "INT",
          "widget": {
            "name": "value"
          },
          "link": 113
        }
      ],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            28
          ]
        }
      ],
      "title": "Height",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        768,
        "fixed"
      ]
    },
    {
      "id": 40,
      "type": "PrimitiveInt",
      "pos": [
        2336.595361217282,
        5019.689419347806
      ],
      "size": [
        360,
        82
      ],
      "flags": {},
      "order": 31,
      "mode": 0,
      "inputs": [
        {
          "name": "value",
          "type": "INT",
          "widget": {
            "name": "value"
          },
          "link": 112
        }
      ],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            26
          ]
        }
      ],
      "title": "Width",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        1366,
        "fixed"
      ]
    },
    {
      "id": 27,
      "type": "PrimitiveInt",
      "pos": [
        2336.595361217282,
        4869.689419347806
      ],
      "size": [
        360,
        82
      ],
      "flags": {},
      "order": 12,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "INT",
          "type": "INT",
          "links": [
            31,
            47
          ]
        }
      ],
      "title": "Length",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "PrimitiveInt",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        241,
        "fixed"
      ]
    },
    {
      "id": 2,
      "type": "RandomNoise",
      "pos": [
        4263.002827395487,
        4297.115751528979
      ],
      "size": [
        270,
        82
      ],
      "flags": {},
      "order": 13,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            6
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.56",
        "Node name for S&R": "RandomNoise",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        219446799783778,
        "randomize"
      ]
    },
    {
      "id": 5,
      "type": "LTXAVTextEncoderLoader",
      "pos": [
        2790.669915402209,
        4754.086965616953
      ],
      "size": [
        420,
        124.44010416666667
      ],
      "flags": {},
      "order": 14,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            39,
            59
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXAVTextEncoderLoader",
        "models": [
          {
            "name": "ltx-2.3-22b-dev-fp8.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors",
            "directory": "checkpoints"
          },
          {
            "name": "gemma_3_12B_it_fp4_mixed.safetensors",
            "url": "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors",
            "directory": "text_encoders"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "gemma_3_12B_it_fp4_mixed.safetensors",
        "ltx-2.3-22b-dev-fp8.safetensors",
        "default"
      ]
    },
    {
      "id": 69,
      "type": "GetImageSize",
      "pos": [
        1905.6292916933273,
        5276.573438769277
      ],
      "size": [
        140,
        124
      ],
      "flags": {},
      "order": 26,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 111
        }
      ],
      "outputs": [
        {
          "name": "width",
          "type": "INT",
          "links": [
            112
          ]
        },
        {
          "name": "height",
          "type": "INT",
          "links": [
            113
          ]
        },
        {
          "name": "batch_size",
          "type": "INT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.19.3",
        "Node name for S&R": "GetImageSize",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.4.1"
        }
      },
      "widgets_values": []
    },
    {
      "id": 68,
      "type": "ResizeImageResolution",
      "pos": [
        1785.6836172397138,
        5114.850880296566
      ],
      "size": [
        294.8833374023437,
        82
      ],
      "flags": {},
      "order": 21,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 110
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            111,
            115
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-logicutils",
        "ver": "1.7.2",
        "Node name for S&R": "ResizeImageResolution",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.4.1"
        }
      },
      "widgets_values": [
        1024,
        "NEAREST"
      ]
    },
    {
      "id": 14,
      "type": "LTXVImgToVideoInplace",
      "pos": [
        5452.439859636542,
        4741.710663510084
      ],
      "size": [
        300,
        130
      ],
      "flags": {},
      "order": 46,
      "mode": 0,
      "inputs": [
        {
          "name": "vae",
          "type": "VAE",
          "link": 19
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 117
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 21
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            1
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXVImgToVideoInplace",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        1,
        false
      ]
    },
    {
      "id": 22,
      "type": "LTXVImgToVideoInplace",
      "pos": [
        4343.539421903357,
        5346.468434118046
      ],
      "size": [
        270,
        130
      ],
      "flags": {},
      "order": 38,
      "mode": 0,
      "inputs": [
        {
          "name": "vae",
          "type": "VAE",
          "link": 32
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 119
        },
        {
          "name": "latent",
          "type": "LATENT",
          "link": 34
        }
      ],
      "outputs": [
        {
          "name": "latent",
          "type": "LATENT",
          "links": [
            44
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXVImgToVideoInplace",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        0.8,
        false
      ]
    },
    {
      "id": 70,
      "type": "ImageScaleDownBy",
      "pos": [
        3471.3317562931416,
        5450.736194047557
      ],
      "size": [
        270,
        58
      ],
      "flags": {},
      "order": 33,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 118
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            119
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfyui-art-venture",
        "ver": "1.1.3",
        "Node name for S&R": "ImageScaleDownBy",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.4.1"
        }
      },
      "widgets_values": [
        0.5
      ]
    },
    {
      "id": 15,
      "type": "LTXVPreprocess",
      "pos": [
        2997.0621597371633,
        5346.6866359262085
      ],
      "size": [
        280,
        66.66666666666667
      ],
      "flags": {},
      "order": 27,
      "mode": 0,
      "inputs": [
        {
          "name": "image",
          "type": "IMAGE",
          "link": 115
        }
      ],
      "outputs": [
        {
          "name": "output_image",
          "type": "IMAGE",
          "links": [
            117,
            118
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.7.0",
        "Node name for S&R": "LTXVPreprocess",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        38
      ]
    },
    {
      "id": 46,
      "type": "LoraLoaderModelOnly",
      "pos": [
        3878.8971825803114,
        4077.2388213759323
      ],
      "size": [
        520,
        82
      ],
      "flags": {},
      "order": 30,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 92
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            91
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LoraLoaderModelOnly",
        "models": [
          {
            "name": "ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left/resolve/main/ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "directory": "loras"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "sulphur_lora_rank_768.safetensors",
        1
      ]
    },
    {
      "id": 60,
      "type": "LoraLoaderModelOnly",
      "pos": [
        4576.3348191503255,
        3886.748626302847
      ],
      "size": [
        520,
        82
      ],
      "flags": {},
      "order": 24,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 101
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            90
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LoraLoaderModelOnly",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "models": [
          {
            "name": "ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left/resolve/main/ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "directory": "loras"
          }
        ],
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "sulphur_lora_rank_768.safetensors",
        1
      ]
    },
    {
      "id": 49,
      "type": "LoraLoaderModelOnly",
      "pos": [
        4726.182413864069,
        4073.897095003737
      ],
      "size": [
        520,
        82
      ],
      "flags": {},
      "order": 29,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 90
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            74
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.3.68",
        "Node name for S&R": "LoraLoaderModelOnly",
        "models": [
          {
            "name": "ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "url": "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left/resolve/main/ltx-2-19b-lora-camera-control-dolly-left.safetensors",
            "directory": "loras"
          }
        ],
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "ltx23/ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors",
        0.5
      ]
    },
    {
      "id": 67,
      "type": "LoadImage",
      "pos": [
        1439.2363751775258,
        5120.03429563223
      ],
      "size": [
        282.83333587646484,
        314
      ],
      "flags": {},
      "order": 15,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            110
          ]
        },
        {
          "name": "MASK",
          "type": "MASK",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.19.3",
        "Node name for S&R": "LoadImage",
        "ue_properties": {
          "widget_ue_connectable": {},
          "input_ue_unconnectable": {},
          "version": "7.4.1"
        }
      },
      "widgets_values": [
        "your_image.png",
        "image"
      ]
    },
    {
      "id": 29,
      "type": "PrimitiveStringMultiline",
      "pos": [
        2336.595361217282,
        4319.689419347806
      ],
      "size": [
        360,
        350
      ],
      "flags": {},
      "order": 16,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "STRING",
          "type": "STRING",
          "links": [
            40
          ]
        }
      ],
      "title": "Prompt",
      "properties": {
        "cnr_id": "comfy-core",
        "ver": "0.16.3",
        "Node name for S&R": "PrimitiveStringMultiline",
        "ue_properties": {
          "widget_ue_connectable": {},
          "version": "7.4.1",
          "input_ue_unconnectable": {}
        },
        "enableTabs": false,
        "tabWidth": 65,
        "tabXOffset": 10,
        "hasSecondTab": false,
        "secondTabText": "Send Back",
        "secondTabOffset": 80,
        "secondTabWidth": 65
      },
      "widgets_values": [
        "The woman pulls up her shirt, revealing her breasts"
      ]
    },
    {
      "id": 71,
      "type": "Power Lora Loader (rgthree)",
      "pos": [
        3892.195479122999,
        3335.280447781146
      ],
      "size": [
        380,
        170
      ],
      "flags": {},
      "order": 19,
      "mode": 0,
      "title": "Your LoRAs (click + Add Lora)",
      "inputs": [
        {
          "dir": 3,
          "name": "model",
          "type": "MODEL",
          "link": 120
        },
        {
          "dir": 3,
          "name": "clip",
          "type": "CLIP",
          "link": null
        }
      ],
      "outputs": [
        {
          "dir": 4,
          "name": "MODEL",
          "shape": 3,
          "type": "MODEL",
          "links": [
            101,
            102
          ]
        },
        {
          "dir": 4,
          "name": "CLIP",
          "shape": 3,
          "type": "CLIP",
          "links": null
        }
      ],
      "properties": {
        "aux_id": "rgthree/rgthree-comfy",
        "Show Strengths": "Single Strength",
        "Match": ""
      },
      "color": "#223",
      "bgcolor": "#335",
      "widgets_values": [
        {},
        {
          "type": "PowerLoraLoaderHeaderWidget"
        },
        {},
        ""
      ]
    }
  ],
  "links": [
    [
      1,
      14,
      0,
      3,
      0,
      "LATENT"
    ],
    [
      2,
      35,
      1,
      3,
      1,
      "LATENT"
    ],
    [
      4,
      10,
      0,
      8,
      1,
      "CONDITIONING"
    ],
    [
      5,
      10,
      1,
      8,
      2,
      "CONDITIONING"
    ],
    [
      6,
      2,
      0,
      9,
      0,
      "NOISE"
    ],
    [
      7,
      42,
      0,
      9,
      1,
      "GUIDER"
    ],
    [
      8,
      17,
      0,
      9,
      2,
      "SAMPLER"
    ],
    [
      10,
      32,
      0,
      9,
      4,
      "LATENT"
    ],
    [
      11,
      31,
      0,
      10,
      0,
      "CONDITIONING"
    ],
    [
      12,
      31,
      1,
      10,
      1,
      "CONDITIONING"
    ],
    [
      13,
      35,
      0,
      10,
      2,
      "LATENT"
    ],
    [
      16,
      35,
      0,
      13,
      0,
      "LATENT"
    ],
    [
      17,
      39,
      0,
      13,
      1,
      "LATENT_UPSCALE_MODEL"
    ],
    [
      18,
      19,
      0,
      13,
      2,
      "VAE"
    ],
    [
      19,
      19,
      0,
      14,
      0,
      "VAE"
    ],
    [
      21,
      13,
      0,
      14,
      2,
      "LATENT"
    ],
    [
      26,
      40,
      0,
      18,
      0,
      "INT"
    ],
    [
      27,
      44,
      2,
      19,
      0,
      "VAE"
    ],
    [
      28,
      25,
      0,
      20,
      0,
      "INT"
    ],
    [
      29,
      18,
      1,
      21,
      0,
      "INT"
    ],
    [
      30,
      20,
      1,
      21,
      1,
      "INT"
    ],
    [
      31,
      27,
      0,
      21,
      2,
      "INT"
    ],
    [
      32,
      44,
      2,
      22,
      0,
      "VAE"
    ],
    [
      34,
      21,
      0,
      22,
      2,
      "LATENT"
    ],
    [
      36,
      37,
      1,
      23,
      0,
      "LATENT"
    ],
    [
      37,
      4,
      0,
      23,
      1,
      "VAE"
    ],
    [
      38,
      26,
      0,
      24,
      0,
      "INT"
    ],
    [
      39,
      5,
      0,
      30,
      0,
      "CLIP"
    ],
    [
      40,
      29,
      0,
      30,
      1,
      "STRING"
    ],
    [
      41,
      30,
      0,
      31,
      0,
      "CONDITIONING"
    ],
    [
      42,
      41,
      0,
      31,
      1,
      "CONDITIONING"
    ],
    [
      44,
      22,
      0,
      32,
      0,
      "LATENT"
    ],
    [
      45,
      33,
      0,
      32,
      1,
      "LATENT"
    ],
    [
      46,
      4,
      0,
      33,
      0,
      "VAE"
    ],
    [
      47,
      27,
      0,
      33,
      1,
      "INT"
    ],
    [
      48,
      24,
      1,
      33,
      2,
      "INT"
    ],
    [
      49,
      9,
      0,
      35,
      0,
      "LATENT"
    ],
    [
      50,
      1,
      0,
      36,
      0,
      "NOISE"
    ],
    [
      51,
      8,
      0,
      36,
      1,
      "GUIDER"
    ],
    [
      52,
      6,
      0,
      36,
      2,
      "SAMPLER"
    ],
    [
      54,
      3,
      0,
      36,
      4,
      "LATENT"
    ],
    [
      55,
      36,
      0,
      37,
      0,
      "LATENT"
    ],
    [
      56,
      43,
      0,
      38,
      0,
      "IMAGE"
    ],
    [
      57,
      23,
      0,
      38,
      1,
      "AUDIO"
    ],
    [
      58,
      24,
      0,
      38,
      2,
      "FLOAT"
    ],
    [
      59,
      5,
      0,
      41,
      0,
      "CLIP"
    ],
    [
      61,
      31,
      0,
      42,
      1,
      "CONDITIONING"
    ],
    [
      62,
      31,
      1,
      42,
      2,
      "CONDITIONING"
    ],
    [
      63,
      37,
      0,
      43,
      0,
      "LATENT"
    ],
    [
      64,
      19,
      0,
      43,
      1,
      "VAE"
    ],
    [
      65,
      38,
      0,
      45,
      0,
      "VIDEO"
    ],
    [
      71,
      47,
      0,
      9,
      3,
      "SIGMAS"
    ],
    [
      72,
      32,
      0,
      47,
      0,
      "LATENT"
    ],
    [
      74,
      49,
      0,
      8,
      0,
      "MODEL"
    ],
    [
      90,
      60,
      0,
      49,
      0,
      "MODEL"
    ],
    [
      91,
      46,
      0,
      42,
      0,
      "MODEL"
    ],
    [
      92,
      59,
      0,
      46,
      0,
      "MODEL"
    ],
    [
      100,
      63,
      0,
      64,
      2,
      "VAE"
    ],
    [
      101,
      71,
      0,
      60,
      0,
      "MODEL"
    ],
    [
      102,
      71,
      0,
      59,
      0,
      "MODEL"
    ],
    [
      103,
      44,
      0,
      64,
      0,
      "MODEL"
    ],
    [
      107,
      58,
      0,
      36,
      3,
      "SIGMAS"
    ],
    [
      110,
      67,
      0,
      68,
      0,
      "IMAGE"
    ],
    [
      111,
      68,
      0,
      69,
      0,
      "IMAGE"
    ],
    [
      112,
      69,
      0,
      40,
      0,
      "INT"
    ],
    [
      113,
      69,
      1,
      25,
      0,
      "INT"
    ],
    [
      115,
      68,
      0,
      15,
      0,
      "IMAGE"
    ],
    [
      117,
      15,
      0,
      14,
      1,
      "IMAGE"
    ],
    [
      118,
      15,
      0,
      70,
      0,
      "IMAGE"
    ],
    [
      119,
      70,
      0,
      22,
      1,
      "IMAGE"
    ],
    [
      120,
      64,
      0,
      71,
      0,
      "MODEL"
    ]
  ],
  "groups": [
    {
      "id": 1,
      "title": "Model",
      "bounding": [
        2766.595361217282,
        4189.689419347806,
        460,
        830
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 2,
      "title": "Generate Low Resolution",
      "bounding": [
        4248.9282429452205,
        4212.718304462968,
        1040,
        830
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 3,
      "title": "Prompt",
      "bounding": [
        3289.788960334754,
        4206.827954203707,
        950,
        830
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 4,
      "title": "Generate High Resolution",
      "bounding": [
        5846.595361217282,
        4189.689419347806,
        990,
        830
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 5,
      "title": "Lantent Upscale",
      "bounding": [
        5306.595361217282,
        4189.689419347806,
        510,
        830
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 6,
      "title": "Video Settings",
      "bounding": [
        2286.595361217282,
        4189.689419347806,
        450,
        1280
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 7,
      "title": "Image Preprocess",
      "bounding": [
        2766.595361217282,
        5049.689419347806,
        830,
        420
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 8,
      "title": "Empty Latent",
      "bounding": [
        3976.282640433426,
        5084.7618986551115,
        1340,
        420
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "id": 9,
      "title": "Number conversion",
      "bounding": [
        3626.595361217282,
        5049.689419347806,
        280,
        420
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    }
  ],
  "config": {},
  "extra": {
    "ds": {
      "scale": 0.3073560549142828,
      "offset": [
        -4516.255908192106,
        -4066.4451888726635
      ]
    },
    "frontendVersion": "1.42.8",
    "workflowRendererVersion": "LG",
    "ue_links": [],
    "links_added_by_ue": [],
    "VHS_latentpreview": false,
    "VHS_latentpreviewrate": 0,
    "VHS_MetadataImage": true,
    "VHS_KeepIntermediate": true
  },
  "version": 0.4
}
WORKFLOW_EOF_1
fi
log "Sulphur workflows are in the sidebar under Sulphur_workflows"

# --- 4. Extra ComfyUI startup options ----------------------------------------------
# The template's setup starts ComfyUI with a fixed command; add our options to it.
STARTUP_SCRIPT="${STARTUP_SCRIPT:-/app/startup_unix.sh}"
EXTRA_ARGS="${COMFY_EXTRA_ARGS---disable-pinned-memory}"
EXTRA_ARGS="$(echo "$EXTRA_ARGS" | xargs)"   # trim spaces
if [ -n "$EXTRA_ARGS" ] && [ -f "$STARTUP_SCRIPT" ]; then
  if grep -q "ltx-extras-args" "$STARTUP_SCRIPT"; then
    log "ComfyUI startup options already added (container restart)"
  elif grep -q 'main.py --listen 0.0.0.0 --port 8188' "$STARTUP_SCRIPT"; then
    sed -i -e "s|main.py --listen 0.0.0.0 --port 8188|main.py --listen 0.0.0.0 --port 8188 $EXTRA_ARGS|" \
           -e "1a # ltx-extras-args: ComfyUI start options added by ltx-extras.sh" "$STARTUP_SCRIPT"
    log "ComfyUI will start with: $EXTRA_ARGS"
  else
    log "WARNING: couldn't find ComfyUI's start line in $STARTUP_SCRIPT - extra options not added"
  fi
fi

if [ "$FAILED" -gt 0 ]; then
  log "DONE with $FAILED failed download(s) in $((SECONDS - START))s - see WARNING lines above."
else
  log "DONE - all downloads finished in $((SECONDS - START))s. Handing over to the template's setup."
fi
exit 0
