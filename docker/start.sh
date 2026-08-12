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

# Background music is optional too — if AUDIO_URL isn't provided the
# stream just uses each video's own audio track, same as before.
# AUDIO_URL accepts one or more tracks, comma separated, same
# convention as VIDEO_URL: "track1.mp3,track2.mp3,track3.mp3"
ENABLE_BG_AUDIO=false
if [ -n "${AUDIO_URL:-}" ]; then
    ENABLE_BG_AUDIO=true
else
    echo "NOTICE: AUDIO_URL not set — streaming each video's own audio only, no background music."
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (Live Earth from Space — ISS Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "Background Audio  : $([ "$ENABLE_BG_AUDIO" = true ] && echo "enabled" || echo "disabled")"
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

#############################################
# Background audio (optional) — the playlist
# itself is built below, right after the marker
# dot is generated (see "Background audio
# playlist" block). These are just the shared
# config/state vars for it.
#############################################
BG_AUDIO_VOLUME=0.25    # music level when mixed under a video that already has its own audio (0.0-1.0)
AUDIO_PLAYLIST="$ASSET_DIR/audio_playlist.txt"
AUDIO_OFFSET=0           # seconds already played from the (looping) playlist — carried forward across videos/bumpers so the music doesn't restart on every switch
AUDIO_TOTAL_DURATION=0   # summed duration of every track in the playlist, filled in below

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
# Right-hand info panel (Station Details +
# Orbital Data) — mirrors the left panel's
# visual language but sits on the right edge,
# and only runs down to y=610 so it never
# overlaps the existing CTA box / bottom ticker
# / subscribe-ring elements built later in
# build_final_filter().
#############################################
RIGHT_PANEL_X=933      # left edge of the right panel (panel runs to x=1280)
RIGHT_PANEL_W=347
RIGHT_PANEL_H=610
ISS_DATA_REFRESH=8     # seconds between simulated orbital readings
SPARK_HISTORY=8        # how many past altitude readings feed the trend sparkline
ISS_LAUNCH_EPOCH=911448000     # 1998-11-20 06:40 UTC (Zarya module launch, approx) — used to compute the live orbit counter
ORBIT_LENGTH_SECONDS=5561      # 1 ISS orbit ≈ 92 minutes 41 seconds

#############################################
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned for more breathtaking views of Earth from orbit."
    "Discover the latest footage captured by the International Space Station."
    "Our journey around planet Earth continues in just a moment."
    "Exploring coastlines, storms, and city lights from 400 kilometers up."
    "More stunning views from the ISS are coming up next."
    "Witness Earth through the cameras of the International Space Station."
    "Every orbit reveals a new perspective on our home planet."
    "Prepare for another unforgettable pass around planet Earth."
    "New views of Earth await just beyond the next frame."
    "Thank you for watching Earth with us. More live ISS footage is coming soon."
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
# Background audio playlist (optional)
#
# Builds a single ffconcat playlist file out of
# every URL in AUDIO_URL (comma separated:
# "url1,url2,url3", same convention as
# VIDEO_URL). run_video()/run_bumper() play this
# playlist with -stream_loop -1 so it always has
# enough audio to cover any video length, and
# seek into it with AUDIO_OFFSET so the music
# picks up roughly where it left off on the
# previous video/bumper instead of restarting
# from track 1 on every switch. (Because each
# video/bumper is a separate ffmpeg process, this
# offset can't be frame-perfect across the whole
# run — if a single video is long enough to wrap
# past the end of the playlist, that one segment
# will loop back to track 1 partway through. For
# a typical few-minute clip against a normal
# music playlist this isn't noticeable.)
#############################################
if [ "$ENABLE_BG_AUDIO" = true ]; then
    IFS=',' read -ra RAW_AUDIO_URLS <<< "$AUDIO_URL"
    AUDIO_URLS=()
    for a in "${RAW_AUDIO_URLS[@]}"; do
        a="${a#"${a%%[![:space:]]*}"}"
        a="${a%"${a##*[![:space:]]}"}"
        [ -n "$a" ] && AUDIO_URLS+=("$a")
    done

    if [ "${#AUDIO_URLS[@]}" -eq 0 ]; then
        echo "NOTICE: AUDIO_URL was set but contained no valid entries — background audio disabled."
        ENABLE_BG_AUDIO=false
    else
        echo "Building background audio playlist (${#AUDIO_URLS[@]} track(s))..."
        : > "$AUDIO_PLAYLIST"
        for a in "${AUDIO_URLS[@]}"; do
            # ffconcat/concat-demuxer line format: file '<path>', with any
            # single quotes in the URL escaped.
            esc="${a//\'/\'\\\'\'}"
            echo "file '${esc}'" >> "$AUDIO_PLAYLIST"
        done

        for a in "${AUDIO_URLS[@]}"; do
            d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$a" 2>/dev/null || echo "")
            d=${d%.*}
            if [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt 0 ]; then
                AUDIO_TOTAL_DURATION=$((AUDIO_TOTAL_DURATION + d))
            else
                echo "WARNING: could not probe duration for audio track, skipping it from the duration total: $a"
            fi
        done

        if [ "$AUDIO_TOTAL_DURATION" -le 0 ]; then
            echo "WARNING: could not determine any audio track durations — background audio disabled."
            ENABLE_BG_AUDIO=false
        else
            echo "Background audio playlist ready — total duration ${AUDIO_TOTAL_DURATION}s, looping continuously."
        fi
    fi
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

#############################################
# Background orbit-counter + simulated
# orbital-data writer (altitude, velocity,
# day/night pass) for the right panel.
#
# NOTE ON DATA SOURCE: there is no simple
# public real-time JSON feed for the ISS's own
# telemetry the way the YouTube Data API exists
# for subscriber counts, so — unlike
# subs.txt/viewers.txt above — these numbers are
# NOT pulled from live NASA/ISS telemetry.
# They're a bounded, slowly-varying simulation
# built from the ISS's published operating
# ranges (altitude ~408-420 km, orbital velocity
# ~27,600 km/h, one full day/night cycle every
# orbit), refreshed every ISS_DATA_REFRESH
# seconds. The on-screen labels are marked
# "(est.)" so viewers aren't told this is
# certified live telemetry. If you later get
# access to a real feed (e.g. Open Notify / ISS
# tracking APIs), swap the awk-based generation
# below for a curl call, same pattern as the
# subs/viewers writers.
#
# The orbit counter is computed for real, from
# the actual station launch timestamp
# (ISS_LAUNCH_EPOCH) divided by the published
# orbital period, so that number is genuine.
#############################################
printf ' ' > "$ASSET_DIR/rp_orbit.txt"
printf ' ' > "$ASSET_DIR/rp_alt.txt"
printf ' ' > "$ASSET_DIR/rp_vel.txt"
printf ' ' > "$ASSET_DIR/rp_pass.txt"
printf ' ' > "$ASSET_DIR/rp_spark.txt"
ISS_DATA_PID=""
(
    # ASCII-only intensity ramp for the sparkline — safer than Unicode
    # block characters (▁▂▃▄▅▆▇█) since there's no guarantee font.ttf
    # has those glyphs, and a missing glyph would render as a blank box.
    SPARK_CHARS=("." ":" "-" "=" "+" "*" "#" "@")
    HISTORY=()
    while true; do
        NOW_EPOCH=$(date -u +%s)
        ORBIT=$(awk -v now="$NOW_EPOCH" -v launched="$ISS_LAUNCH_EPOCH" -v orblen="$ORBIT_LENGTH_SECONDS" 'BEGIN{printf "%d", (now-launched)/orblen}')
        printf 'Orbit #%s' "$ORBIT" > "$ASSET_DIR/rp_orbit.txt.tmp"
        mv -f "$ASSET_DIR/rp_orbit.txt.tmp" "$ASSET_DIR/rp_orbit.txt"

        # Bounded wobble within the ISS's published altitude range —
        # the real station drifts and gets periodically reboosted, so a
        # slow random walk within 408-420 km reads as plausible.
        ALT=$(awk 'BEGIN{srand(); printf "%d", 408 + rand()*12}')
        # Orbital velocity is fairly constant in reality; keep a small
        # wobble so the panel doesn't look like a static repeating chart.
        VEL=$(awk 'BEGIN{srand(); printf "%d", 27550 + rand()*150}')

        # Day/night pass: the ISS completes one full light/dark cycle
        # every orbit (roughly half daylight, half night). Derived from
        # the same real orbital-period math as the orbit counter above.
        PASS_LABEL=$(awk -v now="$NOW_EPOCH" -v orblen="$ORBIT_LENGTH_SECONDS" 'BEGIN{phase=(now%orblen)/orblen; if (phase<0.5) print "DAYLIGHT PASS"; else print "NIGHT PASS"}')

        printf 'Altitude: ~%s km' "$ALT" > "$ASSET_DIR/rp_alt.txt.tmp"
        mv -f "$ASSET_DIR/rp_alt.txt.tmp" "$ASSET_DIR/rp_alt.txt"
        printf 'Velocity: ~%s km/h' "$VEL" > "$ASSET_DIR/rp_vel.txt.tmp"
        mv -f "$ASSET_DIR/rp_vel.txt.tmp" "$ASSET_DIR/rp_vel.txt"
        printf 'Currently: %s' "$PASS_LABEL" > "$ASSET_DIR/rp_pass.txt.tmp"
        mv -f "$ASSET_DIR/rp_pass.txt.tmp" "$ASSET_DIR/rp_pass.txt"

        HISTORY+=("$ALT")
        while [ "${#HISTORY[@]}" -gt "$SPARK_HISTORY" ]; do
            HISTORY=("${HISTORY[@]:1}")
        done
        SPARK=""
        for v in "${HISTORY[@]}"; do
            BUCKET=$(awk -v v="$v" 'BEGIN{b=int(((v-408)/12)*7); if(b<0)b=0; if(b>7)b=7; print b}')
            SPARK+="${SPARK_CHARS[$BUCKET]}"
        done
        printf '%s' "$SPARK" > "$ASSET_DIR/rp_spark.txt.tmp"
        mv -f "$ASSET_DIR/rp_spark.txt.tmp" "$ASSET_DIR/rp_spark.txt"

        sleep "$ISS_DATA_REFRESH"
    done
) &
ISS_DATA_PID=$!

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; [ -n "$ISS_DATA_PID" ] && kill "$ISS_DATA_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'L I V E   E A R T H'                  > "$ASSET_DIR/title1.txt"
printf 'V I E W   F R O M   T H E   I S S'    > "$ASSET_DIR/title2.txt"
printf "L I V E   V I E W   O F   E A R T H"  > "$ASSET_DIR/header.txt"
printf 'LIVE FROM THE INTERNATIONAL SPACE STATION' > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for daily views of planet Earth' > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Static right-panel text (Station Details) —
# same "print once at startup" pattern as the
# left panel's static strings above.
#############################################
printf 'STATION DETAILS' > "$ASSET_DIR/rp_header.txt"
printf 'Station: ISS' > "$ASSET_DIR/rp_line1.txt"
printf 'Launched: 20 Nov 1998' > "$ASSET_DIR/rp_line2.txt"
printf 'Crew Capacity: 7' > "$ASSET_DIR/rp_line3.txt"
printf 'Orbit Altitude: ~400 km' > "$ASSET_DIR/rp_line4.txt"
printf 'ORBITAL DATA (est.)' > "$ASSET_DIR/rp_env_header.txt"
printf 'ALTITUDE TREND (est.)' > "$ASSET_DIR/rp_wind_label.txt"

#############################################
# Default headline / fact pools (used as a
# last resort if galaxy_info.txt / facts.txt
# are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "The International Space Station continues its live orbit of planet Earth."
    "New footage from the ISS reveals coastlines, deserts, and city lights below."
    "Astronauts aboard the ISS are conducting experiments in microgravity."
    "The ISS orbits Earth roughly every 90 minutes, completing about 16 orbits a day."
    "High-resolution cameras aboard the station capture sweeping views of Earth's weather systems."
    "The Cupola module offers astronauts a 360-degree panoramic view of Earth."
    "Solar arrays on the ISS convert sunlight into power for the entire station."
    "Engineers on the ground continue monitoring the health and performance of the ISS."
    "Every orbit helps scientists better understand Earth's climate and atmosphere."
    "The ISS has been continuously crewed by astronauts since November 2000."
    "City lights, auroras, and lightning storms are all visible from the station at night."
    "The station is a joint project of NASA, Roscosmos, ESA, JAXA, and CSA."
    "Earth observation from the ISS supports research into weather, oceans, and natural disasters."
    "The ISS mission continues to pave the way for future long-duration human spaceflight."
    "Each new orbit brings a fresh perspective from one of the most remarkable vantage points ever built."
)

DEFAULT_FACTS=(
    "The International Space Station orbits Earth at an average altitude of about 400 kilometers."
    "The ISS travels at roughly 27,600 kilometers per hour."
    "At that speed, the ISS orbits Earth about once every 90 minutes."
    "Astronauts aboard the ISS see about 16 sunrises and sunsets every day."
    "The first ISS module, Zarya, was launched on November 20, 1998."
    "The station has been continuously occupied by astronauts since November 2, 2000."
    "The ISS is a collaboration between NASA, Roscosmos, ESA, JAXA, and the Canadian Space Agency."
    "The station is about the size of a football field, including its solar arrays."
    "The Cupola module has seven windows and offers the best views of Earth from the station."
    "Astronauts on the ISS conduct experiments in biology, physics, and materials science."
    "Microgravity aboard the ISS allows research that isn't possible on Earth's surface."
    "The station's solar arrays generate electricity to power all onboard systems."
    "Crews typically live and work aboard the ISS for about six months at a time."
    "The ISS has been visited by astronauts and cosmonauts from over 20 countries."
    "From orbit, astronauts can see hurricanes, wildfires, and city lights across the globe."
    "The station orbits Earth at an inclination that lets it pass over most inhabited regions."
    "Supply spacecraft regularly dock with the ISS to deliver food, fuel, and equipment."
    "The Space Station Remote Manipulator System, or Canadarm2, helps with station maintenance and cargo."
    "Auroras are frequently visible glowing below the station near the polar regions."
    "The ISS is expected to remain in operation before being replaced by future commercial stations."
    "Ground controllers in Houston and Moscow monitor the station around the clock."
    "The station's orbit gradually decays over time and requires periodic reboosts."
    "Spacewalks, called EVAs, are used for station maintenance and upgrades."
    "The ISS has served as a continuous human outpost in low Earth orbit for over two decades."
    "Water aboard the ISS is recycled, including moisture reclaimed from the cabin air."
    "Astronauts exercise roughly two hours a day to counteract the effects of microgravity."
    "The station's robotic arms help capture and berth uncrewed cargo spacecraft."
    "Radio and data relay satellites keep the ISS in near-constant contact with the ground."
    "The ISS has supported thousands of scientific experiments from researchers around the world."
    "From the station, the curvature of the Earth is clearly visible against the blackness of space."
    "Nighttime views from the ISS reveal glowing city grids across entire continents."
    "The station's location shifts slightly westward with each orbit as Earth rotates beneath it."
    "Storm systems, ocean currents, and cloud patterns are all trackable from the ISS."
    "The ISS travels far enough in a day to circle the Earth roughly 16 times."
    "Live views from the station have inspired millions of people to look up at the sky."
    "The station relies on solar power almost entirely, with batteries for the dark side of each orbit."
    "Crew members communicate with mission control in both English and Russian."
    "The ISS is one of the brightest objects visible in the night sky from Earth."
    "Scientific research aboard the ISS supports future missions to the Moon and Mars."
    "The station's laboratories include modules from the United States, Russia, Europe, and Japan."
    "Earth's atmosphere appears as a thin blue line when viewed from the station's orbit."
    "The ISS has hosted astronauts continuously for more than two decades."
    "Docking with the ISS requires extremely precise navigation and timing."
    "The station experiences roughly 45 minutes of daylight and 45 minutes of darkness each orbit."
    "Photographs taken from the ISS have documented changes to Earth's glaciers and coastlines over time."
    "The Space Station's exterior experiences extreme temperature swings between sunlight and shadow."
    "Some of the clearest views of Earth's weather patterns come from the ISS's orbital vantage point."
    "The station remains one of the most complex engineering projects ever built."
    "Every crew rotation brings new researchers and new experiments to the ISS."
    "Each live pass over Earth offers a new view of our planet from 400 kilometers up."
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
        # fixed width for every label — "Cyclone System" no longer gets
        # the same wide box as a much longer phrase.
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
        # like "Storm cell" / "Coastal outflow" did before.
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

    #########################################
    # Right panel: station details + live
    # orbital readout. Runs down to
    # y=RIGHT_PANEL_H (610) — above the bottom
    # ticker/CTA row — so it never overlaps the
    # existing elements built in
    # build_final_filter() below. Entirely new;
    # everything above this block is unchanged.
    #########################################
    local rx=$RIGHT_PANEL_X
    CHAIN+="[p16]drawbox=x=${rx}:y=0:w=${RIGHT_PANEL_W}:h=${RIGHT_PANEL_H}:color=black@0.60:t=fill[rp1];"
    CHAIN+="[rp1]drawbox=x=$((rx-4)):y=0:w=4:h=${RIGHT_PANEL_H}:color=black@0.45:t=fill[rp2];"
    CHAIN+="[rp2]drawbox=x=$((rx-8)):y=0:w=4:h=${RIGHT_PANEL_H}:color=black@0.30:t=fill[rp3];"
    CHAIN+="[rp3]drawbox=x=${rx}:y=0:w=${RIGHT_PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[rp4];"
    CHAIN+="[rp4]drawbox=x=${rx}:y=0:w=2:h=${RIGHT_PANEL_H}:color=${GOLD}@0.6:t=fill[rp5];"

    CHAIN+="[rp5]drawbox=x=$((rx+27)):y=28:w=8:h=8:color=${GOLD}:t=fill[rp6];"
    CHAIN+="[rp6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_header.txt:fontcolor=${GOLD}:fontsize=15:x=$((rx+43)):y=25[rp7];"
    CHAIN+="[rp7]drawbox=x=$((rx+27)):y=55:w=294:h=2:color=white@0.3:t=fill[rp8];"

    CHAIN+="[rp8]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_line1.txt:fontcolor=white@0.9:fontsize=15:x=$((rx+27)):y=70:${SHADOW}[rp9];"
    CHAIN+="[rp9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_line2.txt:fontcolor=white@0.9:fontsize=15:x=$((rx+27)):y=94:${SHADOW}[rp10];"
    CHAIN+="[rp10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_line3.txt:fontcolor=white@0.9:fontsize=15:x=$((rx+27)):y=118:${SHADOW}[rp11];"
    CHAIN+="[rp11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_line4.txt:fontcolor=white@0.9:fontsize=15:x=$((rx+27)):y=142:${SHADOW}[rp12];"
    CHAIN+="[rp12]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_orbit.txt:reload=1:fontcolor=${GOLD}:fontsize=15:x=$((rx+27)):y=166[rp13];"

    CHAIN+="[rp13]drawbox=x=$((rx+27)):y=200:w=294:h=2:color=${GOLD}@0.4:t=fill[rp14];"
    CHAIN+="[rp14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_env_header.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=$((rx+27)):y=212[rp15];"

    CHAIN+="[rp15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_alt.txt:reload=1:fontcolor=white:fontsize=17:x=$((rx+27)):y=236:${SHADOW}[rp16];"
    CHAIN+="[rp16]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_vel.txt:reload=1:fontcolor=white:fontsize=17:x=$((rx+27)):y=262:${SHADOW}[rp17];"
    CHAIN+="[rp17]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_pass.txt:reload=1:fontcolor=white:fontsize=17:x=$((rx+27)):y=288:${SHADOW}[rp18];"

    CHAIN+="[rp18]drawbox=x=$((rx+27)):y=320:w=294:h=2:color=${GOLD}@0.4:t=fill[rp19];"
    CHAIN+="[rp19]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_wind_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=$((rx+27)):y=332[rp20];"
    CHAIN+="[rp20]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/rp_spark.txt:reload=1:fontcolor=${GOLD}:fontsize=26:x=$((rx+27)):y=352[rp_end];"

    local prev="rp_end"
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
# advance_audio_offset: call after each ffmpeg
# segment (a run_video attempt, success or
# failure, or a bumper) with however many
# seconds it actually streamed for, so the NEXT
# segment's background-audio seek picks up close
# to where this one left off instead of jumping
# back to the start of the playlist. Wraps around
# AUDIO_TOTAL_DURATION since the playlist itself
# loops forever.
#############################################
advance_audio_offset() {
    local played="$1"
    [ "$ENABLE_BG_AUDIO" = true ] || return 0
    [[ "$played" =~ ^[0-9]+$ ]] || played=0
    AUDIO_OFFSET=$(( (AUDIO_OFFSET + played) % AUDIO_TOTAL_DURATION ))
}

#############################################
# Up-next bumper: short branded title card
# streamed between videos to reduce drop-off
# at the loop/transition point.
#
# FRAME-RATE NOTE: this used to render at -r 24
# while run_video() renders the main stream at
# -r 30. Sending two different frame rates down
# the same RTMP connection (main video -> bumper
# -> next main video -> ...) is what caused
# duplicated/dropped frames on YouTube's side at
# every transition — the ingest has to
# reconcile timestamps across the switch. Now
# locked to -r 30 to match run_video() exactly,
# with -g/-keyint_min left at 60 so the keyframe
# interval (2s at 30fps) also matches the main
# stream instead of drifting to 2.5s like it did
# at 24fps.
#
# AUDIO NOTE: when background audio is enabled,
# the bumper's audio track switches from silence
# (anullsrc) to the same looping playlist the
# videos use, picked up at the current
# AUDIO_OFFSET — so the music keeps playing
# straight through the transition instead of
# cutting out for the 5s bumper.
#############################################
run_bumper() {
    local next_url="$1"

    local raw title
    raw="${next_url##*/}"
    raw="${raw%.*}"
    raw="${raw//[-_]/ }"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
        title="A New View of Earth"
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

    local audio_inputs=(-f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cl=stereo)
    local audio_map=(-map 1:a)
    if [ "$ENABLE_BG_AUDIO" = true ]; then
        # -stream_loop -1 guarantees the playlist never runs dry even if
        # AUDIO_OFFSET lands near the end; -shortest below trims the
        # output back down to the bumper's fixed BUMPER_DURATION.
        audio_inputs=(-ss "$AUDIO_OFFSET" -stream_loop -1 -f concat -safe 0 -i "$AUDIO_PLAYLIST")
        audio_map=(-map 1:a:0)
    fi

    local start_ts end_ts elapsed
    start_ts=$(date +%s)
    ffmpeg \
    -hide_banner \
    -loglevel warning \
    -loop 1 -t "$BUMPER_DURATION" -i overlay.png \
    "${audio_inputs[@]}" \
    -filter_complex "$BFILTER" \
    -map "[final]" \
    "${audio_map[@]}" \
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
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing to next video"
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    advance_audio_offset "$elapsed"
}

#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#
# AUDIO NOTE: when background audio is enabled,
# an extra input (the looping playlist, seeked to
# AUDIO_OFFSET) is added and mixed under the
# video's own audio track with amix — or, if the
# video has no audio track at all, played on its
# own. Either way it's mapped in as [aout] instead
# of the old plain "-map 0:a?".
#############################################
run_video() {
    local url="$1"
    local attempt=1

    prepare_video_content "$url"

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

    # Does this video already carry its own audio track? Decides whether
    # background music (when enabled) gets mixed under it or just plays
    # on its own.
    local has_audio=false
    if [ "$ENABLE_BG_AUDIO" = true ]; then
        if ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$url" 2>/dev/null | grep -q .; then
            has_audio=true
            echo "This video has its own audio — background music will be mixed underneath at volume ${BG_AUDIO_VOLUME}."
        else
            echo "This video has no audio track — background music will play on its own."
        fi
        if [ "$has_audio" = true ]; then
            filter+=";[0:a]volume=1.0[origa];[3:a]volume=${BG_AUDIO_VOLUME}[bga];[origa][bga]amix=inputs=2:duration=first:dropout_transition=2[aout]"
        else
            filter+=";[3:a]volume=1.0[aout]"
        fi
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        local audio_inputs=()
        local map_audio_args=(-map 0:a?)
        if [ "$ENABLE_BG_AUDIO" = true ]; then
            # -stream_loop -1 so the playlist can never run out mid-video
            # (the -shortest flag below trims audio+video to the video's
            # actual length, same as before).
            audio_inputs=(-ss "$AUDIO_OFFSET" -stream_loop -1 -f concat -safe 0 -i "$AUDIO_PLAYLIST")
            map_audio_args=(-map "[aout]")
        fi

        local start_ts end_ts elapsed
        start_ts=$(date +%s)
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
        "${audio_inputs[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        "${map_audio_args[@]}" \
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
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        advance_audio_offset "$elapsed"

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
