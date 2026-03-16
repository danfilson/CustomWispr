#!/bin/bash
set -e

# CustomWispr Local Mode Setup
# Installs whisper.cpp server and optionally Ollama for fully offline speech-to-text.
# No OpenAI API key needed. No data leaves your machine.

WHISPER_MODEL="base.en"  # Good balance of speed + accuracy. Options: tiny.en, base.en, small.en, medium.en
OLLAMA_MODEL="llama3.2:3b"
WHISPER_PORT=8080
ENV_FILE="$HOME/.custom-wispr.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   CustomWispr — Local Mode Setup         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Check architecture ──
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo -e "${GREEN}✓${NC} Apple Silicon detected — optimal performance"
elif [ "$ARCH" = "x86_64" ]; then
    echo -e "${YELLOW}!${NC} Intel Mac detected — local mode will work but will be slower"
else
    echo -e "${RED}✗${NC} Unknown architecture: $ARCH"
    exit 1
fi

# ── Check Homebrew ──
if ! command -v brew &>/dev/null; then
    echo -e "${RED}✗${NC} Homebrew not found. Install it first:"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi
echo -e "${GREEN}✓${NC} Homebrew found"

# ── Step 1: Install whisper.cpp ──
echo ""
echo -e "${BLUE}Step 1: whisper.cpp (speech-to-text engine)${NC}"

if command -v whisper-server &>/dev/null; then
    echo -e "${GREEN}✓${NC} whisper-server already installed"
else
    echo "  Installing whisper.cpp via Homebrew..."
    brew install whisper-cpp
    echo -e "${GREEN}✓${NC} whisper.cpp installed"
fi

# ── Step 2: Download Whisper model ──
echo ""
echo -e "${BLUE}Step 2: Downloading Whisper model (${WHISPER_MODEL})${NC}"

MODEL_DIR="$HOME/.local/share/whisper-models"
mkdir -p "$MODEL_DIR"

MODEL_FILE="$MODEL_DIR/ggml-${WHISPER_MODEL}.bin"
if [ -f "$MODEL_FILE" ]; then
    echo -e "${GREEN}✓${NC} Model already downloaded: $MODEL_FILE"
else
    echo "  Downloading ggml-${WHISPER_MODEL}.bin..."
    curl -L --progress-bar \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin" \
        -o "$MODEL_FILE"
    echo -e "${GREEN}✓${NC} Model downloaded: $MODEL_FILE"
fi

# ── Step 3: Optional — Install Ollama for AI cleanup ──
echo ""
echo -e "${BLUE}Step 3: Ollama (optional — AI text cleanup)${NC}"
echo "  Ollama runs a local LLM to clean up transcriptions (fix grammar, remove filler words)."
echo "  Without it, you'll get raw Whisper output (still very usable)."
echo ""

INSTALL_OLLAMA="n"
if command -v ollama &>/dev/null; then
    echo -e "${GREEN}✓${NC} Ollama already installed"
    INSTALL_OLLAMA="y"
else
    read -p "  Install Ollama for AI cleanup? (y/n, default: n): " INSTALL_OLLAMA
    INSTALL_OLLAMA="${INSTALL_OLLAMA:-n}"

    if [ "$INSTALL_OLLAMA" = "y" ] || [ "$INSTALL_OLLAMA" = "Y" ]; then
        echo "  Installing Ollama via Homebrew..."
        brew install ollama
        echo -e "${GREEN}✓${NC} Ollama installed"
    fi
fi

# Pull the LLM model if Ollama is available
if [ "$INSTALL_OLLAMA" = "y" ] || [ "$INSTALL_OLLAMA" = "Y" ]; then
    echo "  Pulling ${OLLAMA_MODEL} model (this may take a minute)..."
    ollama pull "$OLLAMA_MODEL" 2>/dev/null || {
        echo -e "${YELLOW}!${NC} Could not pull model. Make sure Ollama is running: ollama serve"
    }
fi

# ── Step 4: Configure CustomWispr ──
echo ""
echo -e "${BLUE}Step 4: Configuring CustomWispr for local mode${NC}"

# Build the env file content, preserving existing API key if present
if [ -f "$ENV_FILE" ]; then
    EXISTING_KEY=$(grep "^OPENAI_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
fi

{
    if [ -n "$EXISTING_KEY" ]; then
        echo "OPENAI_API_KEY=$EXISTING_KEY"
    fi
    echo "TRANSCRIPTION_MODE=local"
    if [ "$INSTALL_OLLAMA" = "y" ] || [ "$INSTALL_OLLAMA" = "Y" ]; then
        echo "CLEANUP_MODE=local"
        echo "LOCAL_LLM_MODEL=$OLLAMA_MODEL"
    else
        echo "CLEANUP_MODE=off"
    fi
    echo "LOCAL_WHISPER_URL=http://127.0.0.1:$WHISPER_PORT"
} > "$ENV_FILE"

chmod 600 "$ENV_FILE"
echo -e "${GREEN}✓${NC} Config saved to $ENV_FILE"

# ── Step 5: Create launch script ──
echo ""
echo -e "${BLUE}Step 5: Creating launch helper${NC}"

LAUNCH_SCRIPT="$HOME/.local/bin/customwispr-local"
mkdir -p "$(dirname "$LAUNCH_SCRIPT")"

cat > "$LAUNCH_SCRIPT" << SCRIPT
#!/bin/bash
# Start the local whisper.cpp server and CustomWispr together.
# Usage: customwispr-local

WHISPER_PORT=$WHISPER_PORT
MODEL_FILE="$MODEL_FILE"
WHISPER_PID=""

cleanup() {
    if [ -n "\$WHISPER_PID" ]; then
        kill "\$WHISPER_PID" 2>/dev/null
        echo "Whisper server stopped."
    fi
}
trap cleanup EXIT

# Start whisper.cpp server if not already running
if curl -s "http://127.0.0.1:\$WHISPER_PORT" >/dev/null 2>&1; then
    echo "Whisper server already running on port \$WHISPER_PORT"
else
    echo "Starting whisper.cpp server..."
    whisper-server \\
        --model "\$MODEL_FILE" \\
        --host 127.0.0.1 \\
        --port \$WHISPER_PORT \\
        --threads 4 \\
        2>/dev/null &
    WHISPER_PID=\$!
    sleep 2

    if ! curl -s "http://127.0.0.1:\$WHISPER_PORT" >/dev/null 2>&1; then
        echo "ERROR: Whisper server failed to start."
        exit 1
    fi
    echo "Whisper server running on port \$WHISPER_PORT (PID \$WHISPER_PID)"
fi

# Start Ollama if installed and cleanup mode is local
if command -v ollama &>/dev/null; then
    if ! curl -s "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
        echo "Starting Ollama..."
        ollama serve &>/dev/null &
        sleep 2
    else
        echo "Ollama already running."
    fi
fi

# Launch CustomWispr
echo "Launching CustomWispr..."
open /Applications/CustomWispr.app 2>/dev/null || open ./CustomWispr.app 2>/dev/null || {
    echo "CustomWispr.app not found. Build it first: ./build-arm64.sh"
    exit 1
}

echo ""
echo "CustomWispr is running in local mode."
echo "  - Whisper server: http://127.0.0.1:\$WHISPER_PORT"
echo "  - No data leaves your machine."
echo ""
echo "Press Ctrl+C to stop the whisper server."
wait
SCRIPT

chmod +x "$LAUNCH_SCRIPT"
echo -e "${GREEN}✓${NC} Launch script created: $LAUNCH_SCRIPT"

# ── Step 6: Create launchd plist for auto-start (optional) ──
PLIST_PATH="$HOME/Library/LaunchAgents/com.personal.whisper-server.plist"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.personal.whisper-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v whisper-server)</string>
        <string>--model</string>
        <string>${MODEL_FILE}</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>${WHISPER_PORT}</string>
        <string>--threads</string>
        <string>4</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/whisper-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/whisper-server.log</string>
</dict>
</plist>
PLIST

echo -e "${GREEN}✓${NC} LaunchAgent created (whisper server auto-start at login)"
echo "  To enable:  launchctl load $PLIST_PATH"
echo "  To disable: launchctl unload $PLIST_PATH"

# ── Done ──
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo "  Quick start:"
echo "    1. Rebuild the app:  ./build-arm64.sh"
echo "    2. Launch everything: ~/.local/bin/customwispr-local"
echo ""
echo "  Or start the whisper server manually:"
echo "    whisper-server -m $MODEL_FILE --host 127.0.0.1 --port $WHISPER_PORT"
echo "    open CustomWispr.app"
echo ""
echo "  To switch back to cloud mode:"
echo "    Edit ~/.custom-wispr.env and set TRANSCRIPTION_MODE=cloud"
echo ""
echo "  Model sizes (re-run with WHISPER_MODEL=small.en for better accuracy):"
echo "    tiny.en  — 75 MB  — fastest, good for clear English"
echo "    base.en  — 142 MB — recommended starting point"
echo "    small.en — 466 MB — very good accuracy"
echo "    medium   — 1.5 GB — near cloud quality, multilingual"
echo ""
