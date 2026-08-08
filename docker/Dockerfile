FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y \
        ffmpeg \
        curl \
        ca-certificates \
        python3 \
        python3-pip && \
    rm -rf /var/lib/apt/lists/*

# yt-dlp resolves the two YouTube live page URLs (ISS feeds) to real,
# ffmpeg-readable stream URLs. Installed with -U at build time so every
# fresh image build picks up the latest extractor — YouTube changes
# break yt-dlp periodically, so an old pinned version can silently stop
# resolving live URLs weeks from now even with no other code changes.
RUN pip3 install --no-cache-dir --break-system-packages -U yt-dlp

WORKDIR /app
# Copy the entire build context instead of naming files one by one.
# This automatically picks up everything the script can use — start.sh,
# overlay.png, font.ttf, galaxy_info.txt, facts.txt, and any per-video
# *.labels.txt / *.headlines.txt / *.facts.txt files — without needing
# a Dockerfile edit every time you add a new one.
COPY . .
RUN chmod +x start.sh
CMD ["./start.sh"]
