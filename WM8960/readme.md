rm -f ~/wm8960_setup.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_setup.sh?$(date +%s)" -o ~/wm8960_setup.sh && \
chmod +x ~/wm8960_setup.sh && \
sudo bash ~/wm8960_setup.sh && \
rm -f ~/wm8960_setup.sh

wm8960 play sound_check.wav \
wm8960 record \
wm8960 play \

Node 1: \
gst-launch-1.0 alsasrc device=hw:0,0 ! audio/x-raw,rate=16000,channels=2,format=S32LE ! audioconvert ! opusenc ! rtpopuspay ! udpsink host=192.168.8.185 port=5004 \

Node 2: \
gst-launch-1.0 udpsrc port=5004 ! application/x-rtp,encoding-name=OPUS,payload=96 ! rtpopusdepay ! opusdec ! alsasink device=plughw:0,0 \

