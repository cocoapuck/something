#!/usr/bin/env bash
set -euo pipefail

PYLINGUAL_REPO="https://github.com/syssec-utd/pylingual.git"
PYLINGUAL_BRANCH="main"

BUNDLE="${1:-pylingual-offline}"

echo "============================================================"
echo " PyLingual offline bundle builder"
echo "============================================================"
echo

# ------------------------------------------------------------
# Check host
# ------------------------------------------------------------

echo "==> Checking host"

echo "Python:"
python3 --version

echo "Architecture:"
uname -m

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "ERROR: This script expects an x86_64 machine."
    exit 1
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
    echo
    echo "ERROR: Python venv support is not installed."
    echo
    echo "On Ubuntu, install it with:"
    echo
    echo "    sudo apt install python3-venv"
    echo
    exit 1
fi

# ------------------------------------------------------------
# Create bundle
# ------------------------------------------------------------

echo
echo "==> Creating bundle: $BUNDLE"

rm -rf "$BUNDLE"

mkdir -p "$BUNDLE"
mkdir -p "$BUNDLE/wheels"
mkdir -p "$BUNDLE/hf-cache"

# ------------------------------------------------------------
# Download PyLingual source
# ------------------------------------------------------------

echo
echo "==> Downloading PyLingual source"

git clone \
    --depth 1 \
    --branch "$PYLINGUAL_BRANCH" \
    "$PYLINGUAL_REPO" \
    "$BUNDLE/pylingual"

echo
echo "==> Recording PyLingual commit"

git -C "$BUNDLE/pylingual" rev-parse HEAD \
    | tee "$BUNDLE/PYLINGUAL_COMMIT"

# ------------------------------------------------------------
# Download Python dependencies
#
# The target system is:
#
#   Ubuntu
#   x86_64
#   CPython 3.12
#
# We therefore ask pip to resolve/download CPython 3.12 wheels
# even though this builder may itself be running Python 3.14.
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Downloading Python 3.12 dependencies"
echo "============================================================"

python3 -m pip download \
    --dest "$BUNDLE/wheels" \
    --only-binary=:all: \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux_2_17_x86_64 \
    --platform manylinux2014_x86_64 \
    "$BUNDLE/pylingual"

# ------------------------------------------------------------
# Download build requirements
#
# pip download of a local project does not necessarily leave
# every build dependency in the wheelhouse, so explicitly add
# hatchling.
# ------------------------------------------------------------

echo
echo "==> Downloading build dependencies"

python3 -m pip download \
    --dest "$BUNDLE/wheels" \
    --only-binary=:all: \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux_2_17_x86_64 \
    --platform manylinux2014_x86_64 \
    "hatchling"

# ------------------------------------------------------------
# Create temporary isolated environment for Hugging Face
#
# IMPORTANT:
#
# Ubuntu may mark its system Python as
# "externally-managed-environment" under PEP 668.
#
# Therefore DO NOT do:
#
#     python3 -m pip install huggingface_hub
#
# Instead we create a disposable venv.
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Preparing Hugging Face model downloader"
echo "============================================================"

MODEL_VENV="$(mktemp -d)"

cleanup() {
    echo
    echo "==> Cleaning temporary model downloader"
    rm -rf "$MODEL_VENV"
}

trap cleanup EXIT

echo "==> Creating temporary venv:"
echo "    $MODEL_VENV"

python3 -m venv "$MODEL_VENV"

source "$MODEL_VENV/bin/activate"

echo "==> Temporary environment:"
python --version

echo "==> Installing huggingface_hub"

python -m pip install \
    --quiet \
    --upgrade pip

python -m pip install \
    --quiet \
    huggingface_hub

# ------------------------------------------------------------
# Download PyLingual Python 3.12 models
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Downloading Python 3.12 PyLingual models"
echo "============================================================"

python - "$BUNDLE/hf-cache" <<'PY'
import sys
from pathlib import Path

from huggingface_hub import snapshot_download


cache = Path(sys.argv[1]).resolve()

repos = [
    "syssec-utd/py312-pylingual-v1-segmenter",
    "syssec-utd/py312-pylingual-v1-tokenizer",
    "syssec-utd/py312-pylingual-v1-statement",
    "syssec-utd/py312-pylingual-v1-tok",
]

for repo in repos:
    print()
    print("=" * 70)
    print(f"Downloading: {repo}")
    print("=" * 70)

    snapshot_download(
        repo_id=repo,
        cache_dir=str(cache),
        revision="main",
    )

print()
print("=" * 70)
print("All model repositories downloaded successfully.")
print("=" * 70)
PY

deactivate

# ------------------------------------------------------------
# Create offline installer
# ------------------------------------------------------------

echo
echo "==> Creating install-offline.sh"

cat > "$BUNDLE/install-offline.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON="${PYTHON:-python3.12}"
VENV="${VENV:-$HERE/.venv}"

echo "============================================================"
echo " PyLingual offline installer"
echo "============================================================"
echo

# ------------------------------------------------------------
# Check Python
# ------------------------------------------------------------

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "ERROR: $PYTHON was not found."
    echo
    echo "Install Python 3.12 and make sure python3.12 is in PATH."
    exit 1
fi

echo "Python:"
"$PYTHON" --version

# ------------------------------------------------------------
# Check architecture
# ------------------------------------------------------------

ARCH="$(uname -m)"

echo "Architecture:"
echo "  $ARCH"

if [[ "$ARCH" != "x86_64" ]]; then
    echo "ERROR: This bundle is for x86_64."
    exit 1
fi

# ------------------------------------------------------------
# Check bundle
# ------------------------------------------------------------

if [[ ! -d "$HERE/wheels" ]]; then
    echo "ERROR: wheels/ directory is missing."
    exit 1
fi

if [[ ! -d "$HERE/pylingual" ]]; then
    echo "ERROR: pylingual/ directory is missing."
    exit 1
fi

if [[ ! -d "$HERE/hf-cache" ]]; then
    echo "ERROR: hf-cache/ directory is missing."
    exit 1
fi

# ------------------------------------------------------------
# Create venv
# ------------------------------------------------------------

if [[ -d "$VENV" ]]; then
    echo
    echo "Virtual environment already exists:"
    echo "  $VENV"
else
    echo
    echo "==> Creating virtual environment"

    "$PYTHON" -m venv "$VENV"
fi

source "$VENV/bin/activate"

echo
echo "Virtual environment:"
python --version

# ------------------------------------------------------------
# Install entirely from local wheelhouse
# ------------------------------------------------------------

echo
echo "==> Installing PyLingual from local packages"

python -m pip install \
    --no-index \
    --find-links="$HERE/wheels" \
    "$HERE/pylingual"

# ------------------------------------------------------------
# Create offline environment helper
# ------------------------------------------------------------

echo
echo "==> Creating offline environment helper"

cat > "$VENV/bin/pylingual-offline-env" <<EOF
#!/usr/bin/env bash

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

export HF_HOME="$HERE/hf-cache"
export HF_HUB_CACHE="$HERE/hf-cache"

export HF_HUB_DISABLE_TELEMETRY=1
EOF

chmod +x "$VENV/bin/pylingual-offline-env"

# ------------------------------------------------------------
# Verify executable
# ------------------------------------------------------------

echo
echo "==> Verifying PyLingual"

if ! command -v pylingual >/dev/null 2>&1; then
    echo "ERROR: pylingual executable was not installed."
    exit 1
fi

pylingual --help >/dev/null

echo "PyLingual installation OK."

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Installation complete"
echo "============================================================"
echo
echo "Activate the environment:"
echo
echo "    source \"$VENV/bin/activate\""
echo
echo "Enable offline Hugging Face mode:"
echo
echo "    source \"$VENV/bin/pylingual-offline-env\""
echo
echo "Then:"
echo
echo "    pylingual --help"
echo
INSTALL

chmod +x "$BUNDLE/install-offline.sh"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Bundle complete"
echo "============================================================"
echo

echo "Bundle:"
echo "  $BUNDLE"

echo
echo "Bundle size:"
du -sh "$BUNDLE"

echo
echo "Wheel count:"
find "$BUNDLE/wheels" -type f | wc -l

echo
echo "Model cache size:"
du -sh "$BUNDLE/hf-cache"

echo
echo "PyLingual commit:"
cat "$BUNDLE/PYLINGUAL_COMMIT"

echo
echo "You can now copy the entire directory:"
echo
echo "    $BUNDLE/"
echo
echo "to the offline Python 3.12 x86_64 Ubuntu machine."
echo
