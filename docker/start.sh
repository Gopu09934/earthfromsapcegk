#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (Documentary Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Technical Talk India"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))

# Don't show "N watching now" until the live viewer count reaches this
# many — a very low number (e.g. "5 watching") reads worse to a new
# visitor than showing nothing at all. Raise/lower to taste.
VIEWER_MIN_TO_SHOW=10

# Approximate center + radius (in 1280x720 output coordinates) of the
# subscribe icon baked into overlay.png, used to draw a pulsing gold
# ring around it every few seconds so it catches the eye. Adjust these
# three numbers to match the icon's actual position in your overlay.png
# — the defaults below are an estimate for the bottom-right corner.
SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

#############################################
# Documentary look — cinematic grade / grain /
# letterbox toggles. All optional and cheap
# enough for a 2-core runner at 720p.
#############################################
ENABLE_CINE_GRADE=true     # subtle contrast/saturation lift + vignette
ENABLE_FILM_GRAIN=true     # very light noise, broadcast-doc texture
FILM_GRAIN_STRENGTH=4      # keep low (2-6) — cost scales with this
ENABLE_LETTERBOX=true      # thin cinematic bars top/bottom
LETTERBOX_H=26

#############################################
# Live YouTube source handling
#############################################
# Any VIDEO_URL entry that looks like a YouTube page (not a direct
# media file) is treated as a LIVE source: resolved to a real,
# ffmpeg-readable stream URL via yt-dlp immediately before each
# attempt (signed URLs expire, so this happens per-attempt, not once
# at startup), streamed for SEGMENT_SECONDS, then handed off to the
# next entry in the rotation (with a bumper in between, same as any
# other video). Regular direct-file URLs behave exactly as before —
# probed for real duration, read with -re, no yt-dlp involved.
SEGMENT_SECONDS="${SEGMENT_SECONDS:-1500}"   # 25 min per live source before rotating
YTDLP_FORMAT="${YTDLP_FORMAT:-best[protocol^=m3u8]/best}"

is_youtube_url() {
    case "$1" in
        *youtube.com/watch*|*youtu.be/*|*youtube.com/live/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolves a YouTube page URL to a direct, ffmpeg-consumable stream
# URL. Tries the HLS-preferring format first (best for long-running
# live ingestion), falls back to plain "best" if that selector finds
# nothing. Returns empty string on failure — caller must check.
resolve_live_stream_url() {
    local page_url="$1"
    local resolved="" err=""
    err=$(yt-dlp -g -f "$YTDLP_FORMAT" "$page_url" 2>&1 >"$ASSET_DIR/.ytdlp_out")
    resolved=$(head -1 "$ASSET_DIR/.ytdlp_out")
    if [ -z "$resolved" ]; then
        echo "yt-dlp (format=${YTDLP_FORMAT}) produced no URL. stderr was:" >&2
        echo "$err" >&2
        err=$(yt-dlp -g -f "best" "$page_url" 2>&1 >"$ASSET_DIR/.ytdlp_out")
        resolved=$(head -1 "$ASSET_DIR/.ytdlp_out")
        if [ -z "$resolved" ]; then
            echo "yt-dlp (format=best) also produced no URL. stderr was:" >&2
            echo "$err" >&2
        fi
    fi
    echo "$resolved"
}

#############################################
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned for more breathtaking views from orbit."
    "Our journey around planet Earth continues in just a moment."
    "Another live vantage point from space is coming up next."
    "Every orbit brings a new view of our home planet."
    "Thank you for watching Earth from above with us. More live views are coming soon."
)

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Generate the coordinate-label marker dot once
# at startup (unchanged from original — see
# build_labels_chain() below).
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text (unchanged across videos)
# — updated defaults to match a live-Earth-
# observation feed instead of Webb, since
# that's what's being streamed now. Override
# any of these via env vars if you mix in
# other content later.
#############################################
PANEL_TITLE1="${PANEL_TITLE1:-L I V E   F R O M}"
PANEL_TITLE2="${PANEL_TITLE2:-T H E   S P A C E   S T A T I O N}"
PANEL_HEADER="${PANEL_HEADER:-E A R T H   F R O M   O R B I T}"
PANEL_EYEBROW="${PANEL_EYEBROW:-LIVE ORBITAL FEED}"
PANEL_CREDIT="${PANEL_CREDIT:-Credits\\: NASA}"

printf '%s' "$PANEL_TITLE1"  > "$ASSET_DIR/title1.txt"
printf '%s' "$PANEL_TITLE2"  > "$ASSET_DIR/title2.txt"
printf '%s' "$PANEL_HEADER"  > "$ASSET_DIR/header.txt"
printf '%s' "$PANEL_EYEBROW" > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for daily views from space' > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Default headline / fact pools — a mix of
# general space facts plus ISS-specific ones,
# since the two configured sources are the
# NASA ISS live feeds.
#############################################
DEFAULT_HEADLINES=(
    "You are watching a live camera feed from the International Space Station in low Earth orbit."
    "The ISS orbits Earth roughly every 90 minutes, meaning the crew sees a sunrise or sunset about every 45 minutes."
    "The Space Station travels at approximately 28,000 kilometers per hour, or about 7.7 kilometers every second."
    "The International Space Station has been continuously inhabited by rotating crews since November 2000."
    "The ISS orbits at an altitude of roughly 400 kilometers above the Earth's surface."
    "Astronauts aboard the Station conduct scientific research across biology, physics, astronomy, and materials science."
    "The Space Station is a joint project between NASA, Roscosmos, ESA, JAXA, and the Canadian Space Agency."
    "Views from the ISS cameras shift constantly as the Station passes over oceans, continents, and city lights."
    "During orbital night, the cameras may briefly show a dark screen until the Station passes back into sunlight."
    "The Space Station is roughly the size of a football field, including its solar arrays."
    "Every 24 hours, the ISS completes about 16 full orbits of planet Earth."
    "Live views like this one help people around the world see Earth the way astronauts do."
)

DEFAULT_FACTS=(
    "The International Space Station orbits Earth at about 400 kilometers altitude."
    "The ISS completes roughly 16 orbits of Earth every single day."
    "Astronauts aboard the ISS experience around 16 sunrises and 16 sunsets daily."
    "The Space Station travels at nearly 28,000 kilometers per hour."
    "The ISS has been continuously staffed by astronauts since November 2000."
    "The Space Station's solar arrays span roughly the length of a football field."
    "Water aboard the ISS is heavily recycled, including moisture from the cabin air."
    "Astronauts on the ISS follow a structured daily exercise routine to offset bone and muscle loss in microgravity."
    "The ISS travels far enough in one day to circle the Earth about 16 times over."
    "Mission Control communicates with the ISS crew around the clock from stations on the ground."
    "The Space Station is a collaboration between five space agencies: NASA, Roscosmos, ESA, JAXA, and CSA."
    "A light-year is the distance light travels in one year, about 9.46 trillion kilometers."
    "The Universe is approximately 13.8 billion years old."
    "The Moon moves about 3.8 centimeters farther from Earth every year."
    "Auroras occur when charged particles from the Sun interact with Earth's upper atmosphere."
    "Earth's atmosphere, visible as a thin blue line from orbit, protects all known life."
    "The James Webb Space Telescope observes the Universe primarily in infrared light."
    "Voyager 1 is the most distant human-made object from Earth."
)

#############################################
# build_labels_chain — unchanged from original.
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14
    local LABEL_PAD_R=16
    local AVG_CHAR_W=10
    local BOX_W_MIN=110
    local BOX_W_MAX=260
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[2:v]split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        if [ $((box_x + box_w)) -gt 1260 ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt 0 ] && box_x=10

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8))[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content — same idea as original,
# plus the cinematic grade / grain / letterbox
# pass applied right at the top of the chain,
# before any panel UI is drawn on top.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    local i idx

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))
    FACT_DIVIDER_Y=$((DOTS_Y + 40))
    FACT_LABEL_Y=$((FACT_DIVIDER_Y + 14))
    FACT_TEXT_Y=$((FACT_LABEL_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 23 > "$ASSET_DIR/fact${idx}.txt"
    done

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    local VIDEO_FX="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black"
    if [ "$ENABLE_CINE_GRADE" = true ]; then
        VIDEO_FX+=",eq=contrast=1.06:saturation=1.10:brightness=0.01,vignette=PI/5:mode=backward"
    fi
    if [ "$ENABLE_FILM_GRAIN" = true ]; then
        VIDEO_FX+=",noise=alls=${FILM_GRAIN_STRENGTH}:allf=t+u"
    fi

    CHAIN="[0:v]${VIDEO_FX}[video];"
    CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
    CHAIN+="[ovl][video]overlay=0:0[base];"

    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    CHAIN+="${LABELS_OUT}drawbox=x=0:y=0:w=333:h=720:color=black@0.60:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
    CHAIN+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
    CHAIN+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${GOLD}@0.9:t=fill[p5];"
    CHAIN+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${GOLD}@0.6:t=fill[p6];"

    CHAIN+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

    CHAIN+="[p8]drawtext=fontfile=${FONT}:text='${PANEL_CREDIT}':fontcolor=white@0.85:fontsize=15:x=313-text_w:y=19[p9];"
    CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=313-text_w:y=39[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=313-text_w:y=57[p10b];"
    CHAIN+="[p10b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=313-text_w:y=75[p10c];"

    CHAIN+="[p10c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=23:x=33:y=95:${SHADOW}[p11];"
    CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=17:x=33:y=124:${SHADOW}[p12];"
    CHAIN+="[p12]drawbox=x=33:y=155:w=280:h=2:color=white@0.3:t=fill[p13];"

    CHAIN+="[p13]drawbox=x=33:y=171:w=8:h=8:color=${GOLD}:t=fill[p14];"
    CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=168[p15];"

    CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=210[p16];"

    local prev="p16"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=33:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=white@0.35:fontsize=9:x=33:y=$((PROGRESS_Y - 15))[pgcap];"
    CHAIN+="[pgcap]drawbox=x=33:y=${PROGRESS_Y}:w=280:h=2:color=white@0.15:t=fill[pg1];"
    CHAIN+="[pg1]drawbox=x=33:y=${PROGRESS_Y}:w='280*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((33 + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((33 + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    CHAIN+="[${prev}]drawbox=x=33:y=${FACT_DIVIDER_Y}:w=280:h=2:color=${GOLD}@0.4:t=fill[fp1];"
    CHAIN+="[fp1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=${FACT_LABEL_Y}[fp2];"
    prev="fp2"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=16:line_spacing=7:x=33:y=${FACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
        prev="$nxt"
    done

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter — CTA / countdown / ticker
# / watermark / letterbox. next_label lets the
# caller say "Next video" vs "Switching view"
# depending on whether the current source is a
# live feed or a regular clip.
#############################################
build_final_filter() {
    local total_duration="$1"
    local next_label="${2:-Next video}"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    tail+="[${FACT_END}]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='${next_label} in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.85:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=16:x=17:y=695[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.45:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=353:y=655[wm1];"

    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    tail+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=3:enable='${SUB_PULSE_ENABLE}'[wm2];"

    local last_node="wm2"
    if [ "$ENABLE_LETTERBOX" = true ]; then
        tail+="[wm2]drawbox=x=0:y=0:w=1280:h=${LETTERBOX_H}:color=black:t=fill[lb1];"
        tail+="[lb1]drawbox=x=0:y=$((720 - LETTERBOX_H)):w=1280:h=${LETTERBOX_H}:color=black:t=fill[lb2];"
        last_node="lb2"
    fi

    tail+="[${last_node}]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$tail"
}

#############################################
# Up-next bumper — unchanged in structure.
#############################################
run_bumper() {
    local next_url="$1"

    local raw title
    if is_youtube_url "$next_url"; then
        title="Live View From Orbit"
    else
        raw="${next_url##*/}"
        raw="${raw%.*}"
        raw="${raw//[-_]/ }"
        raw="$(echo "$raw" | tr -d '[:space:]')"
        if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
            title="A New View"
        else
            raw="${next_url##*/}"
            raw="${raw%.*}"
            raw="${raw//[-_]/ }"
            title=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
        fi
    fi

    local sub_idx=$((RANDOM % ${#BUMPER_MESSAGES[@]}))
    printf '%s' "$title" | fold -s -w 34 > "$ASSET_DIR/bumper_title.txt"
    printf '%s' "${BUMPER_MESSAGES[$sub_idx]}" > "$ASSET_DIR/bumper_sub.txt"

    echo ">>> Up next: $title"

    local fade_out_start
    fade_out_start=$(awk -v d="$BUMPER_DURATION" 'BEGIN{print d - 0.6}')

    local BFILTER
    BFILTER="[0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720[bg];"
    BFILTER+="[bg]drawbox=x=0:y=0:w=1280:h=720:color=black@0.55:t=fill[b1];"
    BFILTER+="[b1]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[b2];"
    BFILTER+="[b2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[b3];"
    BFILTER+="[b3]drawbox=x=0:y=313:w=1280:h=2:color=${GOLD}@0.8:t=fill[b4];"
    BFILTER+="[b4]drawtext=fontfile=${FONT}:text='UP NEXT':fontcolor=${GOLD}:fontsize=22:x=(w-text_w)/2:y=260[b5];"
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=36:line_spacing=8:x=(w-text_w)/2:y=347:${SHADOW}[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=white@0.75:fontsize=18:x=(w-text_w)/2:y=427[b7];"
    BFILTER+="[b7]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.4:fontsize=14:x=(w-text_w)/2:y=470[b8];"
    BFILTER+="[b8]fade=t=in:st=0:d=0.5,fade=t=out:st=${fade_out_start}:d=0.6[final]"

    ffmpeg \
    -hide_banner \
    -loglevel warning \
    -loop 1 -t "$BUMPER_DURATION" -i overlay.png \
    -f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cl=stereo \
    -filter_complex "$BFILTER" \
    -map "[final]" \
    -map 1:a \
    -r 24 \
    -s 1280x720 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -threads 2 \
    -profile:v high \
    -level 4.1 \
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
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing to next video"
}

#############################################
# Stream one source (file OR live YouTube page)
# with automatic retry on failure/crash.
#############################################
run_video() {
    local url="$1"
    local attempt=1
    local live_source=false
    is_youtube_url "$url" && live_source=true

    prepare_video_content "$url"

    local duration next_label
    if [ "$live_source" = true ]; then
        duration="$SEGMENT_SECONDS"
        next_label="Switching view"
        echo "Live source detected — will stream for ${duration}s before rotating."
    else
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
        duration=${duration%.*}
        [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
        next_label="Next video"
        if [ -n "$duration" ]; then
            echo "Probed duration: ${duration}s"
        else
            echo "Could not probe duration — countdown will show generic filler text."
        fi
    fi

    local filter
    filter=$(build_final_filter "$duration" "$next_label")

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        local input_url="$url"
        local re_flag=(-re)

        if [ "$live_source" = true ]; then
            echo "Resolving live stream URL via yt-dlp..."
            input_url=$(resolve_live_stream_url "$url")
            if [ -z "$input_url" ]; then
                echo "WARNING: yt-dlp could not resolve a playable stream URL for $url (attempt ${attempt}/${MAX_RETRIES})."
                attempt=$((attempt + 1))
                [ "$attempt" -le "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
                continue
            fi
            # Live sources are already delivered in real time — reading
            # with -re on top of that just adds latency, so we drop it
            # for live inputs and keep it only for local/VOD files.
            re_flag=()
        fi

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        "${re_flag[@]}" \
        -i "$input_url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$DOT_MARKER" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map 0:a? \
        -t "${duration:-0}" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
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
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Segment finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this source. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

# If any source is a YouTube page URL, yt-dlp is required to resolve it
# to a playable stream. Fail fast with a clear message rather than
# looping forever on resolution errors.
NEEDS_YTDLP=false
for u in "${URLS[@]}"; do
    if is_youtube_url "$u"; then
        NEEDS_YTDLP=true
        echo "Detected live YouTube source: $u"
    fi
done
if [ "$NEEDS_YTDLP" = true ]; then
    if ! command -v yt-dlp >/dev/null 2>&1; then
        echo "ERROR: yt-dlp is required to resolve YouTube live URLs but is not installed."
        echo "Install it with: pip install -U yt-dlp   (add --break-system-packages if needed)"
        exit 1
    fi
    echo "yt-dlp version: $(yt-dlp --version 2>&1)"
fi

# Shuffle playback order fresh for every workflow run, so the sequence
# isn't identical every time the container restarts.
if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        next_idx=$(( (i + 1) % NUM_URLS ))
        next_url="${URLS[$next_idx]}"

        run_video "$url"

        if [ "$ENABLE_BUMPER" = true ]; then
            run_bumper "$next_url"
        fi

        echo "Loading next source..."
        echo ""
    done
done
