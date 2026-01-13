#!/bin/bash
# Install super-resolution models for FFmpeg TensorRT backend
# Downloads from HuggingFace and converts to TensorRT engine
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${MODEL_DIR:-$HOME/ffmpeg_build/models}"

# Available models (name:repo:file:arch)
declare -A MODELS=(
    ["realesrgan"]="ai-forever/Real-ESRGAN:RealESRGAN_x4.pth:rrdb"
    ["compact"]="ai-forever/Real-ESRGAN:RealESRGAN_x4.pth:compact"
)

usage() {
    cat << EOF
Usage: $(basename "$0") MODEL [OPTIONS]

Download and compile a super-resolution model for FFmpeg TensorRT backend.

Models:
    realesrgan   Real-ESRGAN x4 (RRDBNet) - highest quality, slower
    compact      SRVGGNetCompact x4 - fast, good quality

Options:
    -r, --resolution WxH   Input resolution (default: 1280x720)
    -o, --output DIR       Output directory (default: \$HOME/ffmpeg_build/models)
    -f, --fp32             Use FP32 precision (default: FP16)
    -h, --help             Show this help

Examples:
    $(basename "$0") compact                    # Build compact model for 720p
    $(basename "$0") realesrgan -r 640x360      # Build RealESRGAN for 360p
    $(basename "$0") compact -r 1920x1080       # Build compact for 1080p

Output:
    Creates: \$MODEL_DIR/<model>_<width>x<height>_fp16.engine

FFmpeg usage:
    ffmpeg -init_hw_device cuda=cu -filter_hw_device cu -i input.mp4 \\
        -vf "format=rgb24,hwupload,dnn_processing=dnn_backend=8:model=\$ENGINE" \\
        -c:v hevc_nvenc output.mp4
EOF
    exit 0
}

# Parse arguments
MODEL_NAME=""
RESOLUTION="1280x720"
FP16="--fp16"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--resolution) RESOLUTION="$2"; shift 2 ;;
        -o|--output) MODEL_DIR="$2"; shift 2 ;;
        -f|--fp32) FP16=""; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) MODEL_NAME="$1"; shift ;;
    esac
done

if [ -z "$MODEL_NAME" ]; then
    echo "Error: MODEL required"
    echo ""
    usage
fi

if [ -z "${MODELS[$MODEL_NAME]}" ]; then
    echo "Error: Unknown model '$MODEL_NAME'"
    echo "Available: ${!MODELS[*]}"
    exit 1
fi

# Parse resolution
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

if ! [[ "$WIDTH" =~ ^[0-9]+$ ]] || ! [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid resolution '$RESOLUTION'. Use format WxH (e.g., 1280x720)"
    exit 1
fi

# Parse model spec
IFS=':' read -r REPO FILE ARCH <<< "${MODELS[$MODEL_NAME]}"

echo "========================================"
echo "Super-Resolution Model Installation"
echo "========================================"
echo "Model: $MODEL_NAME ($ARCH)"
echo "Resolution: ${WIDTH}x${HEIGHT}"
echo "Precision: $([ -n "$FP16" ] && echo FP16 || echo FP32)"
echo "Output: $MODEL_DIR"
echo ""

# Create output directory
mkdir -p "$MODEL_DIR"

# Setup Python venv
VENV_DIR="$MODEL_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Install dependencies
echo "Installing dependencies..."
pip install -q torch huggingface_hub onnx tensorrt basicsr realesrgan 2>/dev/null || true

# Download model
echo "Downloading model from HuggingFace..."
MODEL_PATH=$(python3 -c "
from huggingface_hub import hf_hub_download
path = hf_hub_download('$REPO', '$FILE')
print(path)
")

# Build engine
SUFFIX=$([ -n "$FP16" ] && echo "_fp16" || echo "")
ENGINE="${MODEL_DIR}/${MODEL_NAME}_${WIDTH}x${HEIGHT}${SUFFIX}.engine"

echo "Building TensorRT engine..."
python3 "$SCRIPT_DIR/export-tensorrt.py" \
    --model "$MODEL_PATH" \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --output "$ENGINE" \
    $FP16

deactivate

echo ""
echo "========================================"
echo "Installation complete!"
echo "========================================"
echo "Engine: $ENGINE"
echo ""
echo "Test with:"
echo "  ffmpeg -init_hw_device cuda=cu -filter_hw_device cu \\"
echo "    -f lavfi -i testsrc=duration=3:size=${WIDTH}x${HEIGHT}:rate=30 \\"
echo "    -vf \"format=rgb24,hwupload,dnn_processing=dnn_backend=8:model=$ENGINE\" \\"
echo "    -c:v hevc_nvenc test.mp4"
