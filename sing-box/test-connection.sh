ping google.com -c 4
ping 8.8.8.8 -c 4
ping github.com -c 4

wget ipinfo.io/what-is-my-ip
cat what-is-my-ip

# GUI smoke test: xeyes shows up instantly on the Windows desktop via WSLg
export DISPLAY="${DISPLAY:-:0}"
xeyes >/dev/null 2>&1 &
chromium --no-sandbox "google.com/search?hl=ru-en&q=Jesus+Christ" "https://youtube.com" "ipleak.net" "dnsleaktest.com" "browserleaks.com/webrtc" &
