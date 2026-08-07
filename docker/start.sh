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
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned for more breathtaking views of the Universe."
    "Discover the latest wonders revealed by the James Webb Space Telescope."
    "Our journey through deep space continues in just a moment."
    "Exploring distant galaxies, stars, and cosmic mysteries."
    "More incredible discoveries from the edge of the observable Universe."
    "Witness the beauty of the cosmos through the eyes of Webb."
    "Every observation brings us closer to understanding our cosmic origins."
    "Prepare for another unforgettable journey across space and time."
    "New cosmic wonders are waiting just beyond the next frame."
    "Thank you for exploring the Universe with us. More amazing views are coming soon."
)

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Generate the coordinate-label marker dot once
# at startup: a small transparent PNG with a
# gold-filled center and white ring, matching
# the panel's gold accent color. Used by
# build_labels_chain() as ffmpeg input index 2.
# Always generated (cheap, one frame, 20x20) —
# harmless/unused by ffmpeg on videos that don't
# have a matching .labels.txt file.
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    # Guarantee the file always exists and is a valid PNG, even in the
    # unlikely case the geq-based generation above fails — this is what
    # gets passed to ffmpeg as a real input on every stream start, so it
    # must never be missing. Falls back to an invisible 1x1 transparent
    # pixel (labels would render without a visible dot, but the stream
    # itself keeps running instead of crashing on a missing input file).
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
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
# (polls YouTube Data API every 60s — subs
# don't change second to second, and this
# respects API quota)
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
                # Manual comma insertion — locale-independent, so it works
                # the same regardless of the container's default locale
                # (printf "%'d" silently fails to group digits under the
                # bare "C" locale that Ubuntu containers ship with).
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                # Log the raw response once so it shows up in the Actions
                # log — this tells us exactly why the count isn't parsing
                # (bad channel ID, disabled API, quota, key restrictions, etc.)
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
# Strategy: find the channel's currently-live
# video once (search.list — costs more quota,
# so only called when we don't already have an
# id), then poll videos.list (cheap, 1 unit)
# every 30s for concurrentViewers. If the
# broadcast ends/restarts, re-search.
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
                    # Below the display threshold — keep the panel blank
                    # rather than showing a small/discouraging number.
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    # Broadcast ended or hasn't registered yet — clear and re-search.
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
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Default headline / fact pools (used as a
# last resort if galaxy_info.txt / facts.txt
# are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "The James Webb Space Telescope is capturing the deepest infrared views of the early Universe ever recorded."
    "Webb has detected galaxies that formed just a few hundred million years after the Big Bang."
    "Scientists are using Webb to analyze the atmospheres of distant exoplanets with unprecedented precision."
    "Powerful infrared observations are revealing stars being born inside dense clouds of cosmic dust."
    "Astronomers are studying supermassive black holes that existed surprisingly early in cosmic history."
    "Webb is helping researchers understand how galaxies grew and evolved across billions of years."
    "New observations are uncovering complex organic molecules in star-forming regions throughout the Milky Way."
    "Planetary systems around distant stars are showing remarkable diversity in size, composition, and structure."
    "The Euclid mission is creating the largest 3D map of the Universe to investigate dark matter and dark energy."
    "The Vera C. Rubin Observatory is expected to transform astronomy with its wide-field survey of the southern sky."
    "Gravitational wave observatories are detecting collisions between black holes and neutron stars across the cosmos."
    "NASA and international space missions continue expanding our understanding of planets, stars, galaxies, and Universe."
    "Webb is observing protoplanetary disks where new planets are actively forming around young stars."
    "Astronomers continue discovering ancient galaxies that challenge existing models of the early Universe."
    "Every new Webb observation provides valuable insights into the history, evolution, and future of our cosmos."
)

DEFAULT_FACTS=(
    "The Universe is approximately 13.8 billion years old."
    "A light-year is the distance light travels in one year, about 9.46 trillion kilometers."
    "The James Webb Space Telescope observes the Universe primarily in infrared light."
    "Webb has detected galaxies that formed only a few hundred million years after the Big Bang."
    "Scientists use Webb to study the atmospheres of distant exoplanets in remarkable detail."
    "Webb is revealing stars forming inside dense clouds of gas and cosmic dust."
    "Astronomers are discovering massive black holes that existed much earlier than previously expected."
    "The Euclid space telescope is mapping billions of galaxies to study dark matter and dark energy."
    "The Vera C. Rubin Observatory will survey the southern sky and discover millions of new celestial objects."
    "The Milky Way contains hundreds of billions of stars."
    "The observable Universe contains billions of galaxies."
    "The Sun contains about 99.8 percent of the total mass in our solar system."
    "Jupiter is the largest planet in our solar system."
    "Mars is home to Olympus Mons, the largest volcano in the solar system."
    "Saturn's rings are composed mostly of ice particles with smaller amounts of rock and dust."
    "Venus is the hottest planet in our solar system because of its dense carbon dioxide atmosphere."
    "Mercury experiences the largest temperature variations of any planet in the solar system."
    "Neptune has the fastest winds recorded on any planet, reaching over 2,000 kilometers per hour."
    "Uranus rotates on its side, likely because of a massive collision early in its history."
    "Earth is the only known planet confirmed to support life."
    "The Moon moves about 3.8 centimeters farther away from Earth each year."
    "The International Space Station travels around Earth at about 28,000 kilometers per hour."
    "Neutron stars are so dense that a teaspoon of their material would weigh billions of tons."
    "A black hole's gravity is so strong that not even light can escape beyond its event horizon."
    "The Milky Way's central supermassive black hole is known as Sagittarius A*."
    "Gravitational waves are ripples in space-time produced by massive cosmic collisions."
    "Dark matter cannot be seen directly but its gravity shapes galaxies and galaxy clusters."
    "Dark energy is believed to drive the accelerating expansion of the Universe."
    "The Milky Way and Andromeda galaxies are expected to merge in about 4.5 billion years."
    "A supernova is the powerful explosion that marks the end of a massive star's life."
    "The Sun's core reaches temperatures of around 15 million degrees Celsius."
    "Proxima Centauri is the closest known star to the Sun."
    "Thousands of exoplanets have been confirmed orbiting stars beyond our solar system."
    "Some exoplanets may contain water-rich atmospheres or rocky surfaces."
    "The largest known structures in the Universe are cosmic filaments stretching across billions of light-years."
    "Time passes more slowly near extremely strong gravitational fields, as predicted by Einstein's theory of relativity."
    "Voyager 1 is the most distant human-made object from Earth."
    "Voyager 1 entered interstellar space in 2012 and continues sending scientific data."
    "Earth's magnetic field protects life by deflecting harmful charged particles from the Sun."
    "Auroras occur when energetic particles from the Sun collide with gases in Earth's upper atmosphere."
    "James Webb has captured some of the deepest and sharpest infrared images ever recorded."
    "Webb is helping scientists understand how the first galaxies formed after the Big Bang."
    "Some galaxies observed by Webb are more massive than astronomers expected for the early Universe."
    "Star-forming nebulae contain the gas and dust needed to create new stars and planets."
    "The asteroid belt between Mars and Jupiter contains millions of rocky objects."
    "Comets are icy objects that develop glowing tails when they approach the Sun."
    "Pulsars are rapidly rotating neutron stars that emit regular beams of radio waves."
    "The Event Horizon Telescope captured the first images of black holes in 2019 and 2022."
    "The search for Earth-like exoplanets is one of the most exciting areas of modern astronomy."
)

#############################################
# build_labels_chain: optional feature — draws
# pointer/callout labels onto specific
# coordinates in the video, similar to
# hand-annotated documentary footage. Fully
# optional per video: only activates if a file
# named <basename>.labels.txt exists.
#
# File format — one label per line, comma
# separated:
#   x,y,Label text here
# where x,y is the pixel position on the
# 1280x720 output frame that the label should
# point at. Box placement, connector line, and
# edge-avoidance (flips below/left near frame
# edges) are computed automatically.
#
# Visual style matches the rest of the panel:
# gold-ring/white marker dot (uses the
# pre-rendered dot_marker.png), gold-tinted
# connector line, and a label box with a gold
# accent bar + thin gold outline (same language
# as the CTA box).
#
# Notes/limits:
#  - Keep label text under ~28 characters — the
#    box is a fixed width and does not
#    reflow/resize to fit longer text.
#  - Best used for points with x > ~370 so
#    labels don't collide with the left info
#    panel.
#  - The connector is a right-angle line
#    (vertical then horizontal), not a true
#    diagonal — ffmpeg has no native diagonal
#    line primitive without much heavier
#    filters, so this is the practical choice.
#  - Requires dot_marker.png (generated once at
#    startup) to be wired in as ffmpeg input
#    index 2 — see run_video()'s -i list.
#
# Sets globals: LABELS_CHAIN (filter string to
# append), LABELS_OUT (bracketed output label
# to continue the chain from, e.g. "[base]" if
# no labels file exists, or the last label's
# output node otherwise).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # FIX: without `local`, every bare loop variable assigned in this
    # function (i, idx, and the C-style `for ((i=...))` counters below)
    # is a GLOBAL bash variable. The main stream loop at the bottom of
    # this file also uses a bare `i` (`for ((i = 0; i < NUM_URLS; i++))`),
    # and this function runs (via prepare_video_content -> run_video)
    # once per video inside that loop. Any unscoped `i`/`idx` in here
    # silently overwrites the outer loop's counter, which is what caused
    # the stream to get stuck replaying the first video forever instead
    # of advancing through the whole playlist.
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    # First pass: collect valid lines so we know the count up front
    # (needed to size the marker `split` filter correctly).
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
    local BOX_GAP=10          # minimum clear space required between two label boxes
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14      # gap between accent bar and text start
    local LABEL_PAD_R=16      # gap between text end and box's right edge
    local AVG_CHAR_W=10       # rough proportional-font width estimate at fontsize 18
    local BOX_W_MIN=110       # never smaller than this, even for a 1-word label
    local BOX_W_MAX=260       # never bigger than this, even for a long label
    local placed_x=() placed_y=() placed_w=()  # boxes already placed this video
    local k collision tries

    # Split the pre-rendered marker image (input [2:v]) into one copy per
    # label so each can be overlaid independently at its own coordinate.
    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[2:v]split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        # Auto-size the box to the label's text instead of using one
        # fixed width for every label — "Pulsar Wind" no longer gets the
        # same wide box as a much longer phrase.
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

        # Collision avoidance: if this box overlaps (within BOX_GAP of)
        # any box already placed for an earlier label on this video,
        # push it downward in BOX_H+BOX_GAP steps until it's clear, so
        # two nearby coordinate labels never end up crowding each other
        # like "Glowing gas knot" / "Dust cloud region" did before.
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
            # Ran off the bottom of the frame — wrap back to the top and
            # keep nudging; after a handful of tries just accept overlap
            # rather than loop forever (extremely dense label sets only).
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

        # Gold-tinted connector line (right-angle: vertical then horizontal)
        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        # Label box: dark fill + gold accent bar (left edge) + thin gold outline
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        # Circular gold-ring/white marker dot, overlaid on top of everything
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8))[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: (re)loads headlines +
# facts for the video about to stream, and
# rebuilds BASE_CHAIN / FACT_END to match.
#
# Per-video override: if files named
#   <basename>.headlines.txt
#   <basename>.facts.txt
# exist (basename = video filename without
# extension — same derivation used for the
# up-next bumper title), they're used verbatim,
# in the order given. Useful for curating panel
# content to match a specific video.
#
# Otherwise falls back to the shared pool
# (galaxy_info.txt / facts.txt / built-in
# defaults), shuffled into a fresh random order
# each video so the panel doesn't feel like a
# static banner repeating identically on every
# clip.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # FIX: same reasoning as build_labels_chain() above — this function
    # is also called once per video from inside the outer stream loop
    # (`for ((i = 0; i < NUM_URLS; i++))` at the bottom of this file),
    # and it reuses bare `i`/`idx` in several for-loops below. Without
    # `local`, those loops overwrite the outer loop's global `i`, which
    # made the stream get stuck re-playing the first video forever
    # instead of advancing through the playlist.
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
    CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
    CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
    CHAIN+="[ovl][video]overlay=0:0[base];"

    # Optional coordinate-based callout labels for this video, drawn onto
    # the raw video before the panel/UI so the panel stays on top.
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

    CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=15:x=313-text_w:y=19[p9];"
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
# build_final_filter: appends the CTA / next-
# video countdown / ticker / watermark / border
# section onto BASE_CHAIN. Called fresh for each
# video since the countdown depends on that
# video's probed duration.
#############################################
build_final_filter() {
    local total_duration="$1"
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
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next video in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
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

    # Pulsing ring around the subscribe icon (baked into overlay.png at
    # SUB_ICON_X/SUB_ICON_Y) — visible for 1s out of every 3s, so it
    # catches the eye without being a constant distraction.
    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    tail+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=3:enable='${SUB_PULSE_ENABLE}'[wm2];"

    tail+="[wm2]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$tail"
}

#############################################
# Up-next bumper: short branded title card
# streamed between videos to reduce drop-off
# at the loop/transition point.
#############################################
run_bumper() {
    local next_url="$1"

    local raw title
    raw="${next_url##*/}"
    raw="${raw%.*}"
    raw="${raw//[-_]/ }"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
        title="A New Discovery"
    else
        raw="${next_url##*/}"
        raw="${raw%.*}"
        raw="${raw//[-_]/ }"
        title=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
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
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    # Load headlines/facts tied to this specific video (curated file if
    # present, otherwise a freshly shuffled pool) and rebuild the panel
    # filter chain to match.
    prepare_video_content "$url"

    # Probe actual duration so the CTA box can show a real countdown to
    # the next video. Falls back gracefully if probing fails.
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
    duration=${duration%.*}
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
    if [ -n "$duration" ]; then
        echo "Probed duration: ${duration}s"
    else
        echo "Could not probe duration — countdown will show generic filler text."
    fi

    local filter
    filter=$(build_final_filter "$duration")

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$DOT_MARKER" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map 0:a? \
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
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
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

# Shuffle playback order fresh for every workflow run, so the sequence
# of videos isn't identical every time the 5-hour cron restarts the
# container. (Fisher-Yates via `shuf`, always available on Ubuntu.)
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

        echo "Loading next video..."
        echo ""
    done
done
