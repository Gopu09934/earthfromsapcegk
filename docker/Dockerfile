FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# ffmpeg for the capture/encode/push, xvfb for a virtual display Chrome
# can render into, python3 to serve index.html locally (Chrome handles
# some iframe/autoplay behavior more predictably over http:// than
# file://), and Google Chrome itself — installed from Google's own apt
# repo rather than the Ubuntu "chromium-browser" package, which on
# 24.04 is just a snap wrapper that doesn't work reliably in containers.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        xvfb \
        python3 \
        wget \
        gnupg \
        ca-certificates \
        fonts-liberation \
        fonts-noto-color-emoji \
    && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN chmod +x start.sh
CMD ["./start.sh"]
