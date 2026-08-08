#!/bin/bash
set -uo pipefail

if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

RES_W=1280
RES_H=720
FPS=30
DISPLAY_NUM=99
export DISPLAY=":${DISPLAY_NUM}"

MAX_RETRIES="${MAX_RETRIES:-1000}"   # effectively "keep going" — the
                                      # workflow's own timeout-minutes
                                      # + cron restart bound total runtime
RETRY_DELAY="${RETRY_DELAY:-5}"

echo "========================================"
echo "Starting browser-capture broadcast"
echo "Resolution: ${RES_W}x${RES_H} @ ${FPS}fps"
echo "========================================"

# ---------------------------------------------------------------
# Virtual display — Chrome renders into this like a real monitor.
# ---------------------------------------------------------------
Xvfb "$DISPLAY" -screen 0 "${RES_W}x${RES_H}x24" -nolisten tcp &
XVFB_PID=$!
sleep 2

# ---------------------------------------------------------------
# Local web server for index.html. Serving over http://localhost
# instead of file:// avoids some browsers' extra restrictions on
# third-party iframes/autoplay under the file: origin.
# ---------------------------------------------------------------
python3 -m http.server 8080 --directory /app >/var/log/httpserver.log 2>&1 &
HTTP_PID=$!
sleep 1

CHROME_PID=""

cleanup() {
    echo "Shutting down..."
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
    kill "$HTTP_PID" "$XVFB_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

start_chrome() {
    rm -rf /tmp/chrome-profile
    mkdir -p /tmp/chrome-profile
    google-chrome-stable \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu \
        --window-position=0,0 \
        --window-size="${RES_W},${RES_H}" \
        --kiosk \
        --autoplay-policy=no-user-gesture-required \
        --disable-infobars \
        --disable-notifications \
        --disable-session-crashed-bubble \
        --no-first-run \
        --user-data-dir=/tmp/chrome-profile \
        "http://localhost:8080/index.html" \
        >/var/log/chrome.log 2>&1 &
    CHROME_PID=$!
}

echo "Launching browser..."
start_chrome
echo "Waiting for the page and video player to settle..."
sleep 10

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
    echo "----------------------------------------"
    echo "Starting capture -> RTMP (attempt ${attempt}/${MAX_RETRIES})"
    echo "----------------------------------------"

    # If Chrome died since the last loop, relaunch it before capturing.
    if ! kill -0 "$CHROME_PID" 2>/dev/null; then
        echo "Browser is not running — relaunching..."
        start_chrome
        sleep 10
    fi

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -f x11grab \
        -video_size "${RES_W}x${RES_H}" \
        -framerate "$FPS" \
        -i "$DISPLAY" \
        -f lavfi -i anullsrc=r=48000:cl=stereo \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
    exit_code=$?

    echo "WARNING: ffmpeg capture exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$MAX_RETRIES" ]; then
        echo "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    fi
done

echo "ERROR: Max retries reached."
exit 1
