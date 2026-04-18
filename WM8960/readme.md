rm -f ~/wm8960_setup.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_setup.sh?$(date +%s)" -o ~/wm8960_setup.sh && \
chmod +x ~/wm8960_setup.sh && \
sudo bash ~/wm8960_setup.sh && \
rm -f ~/wm8960_setup.sh

wm8960 play sound_check.wav \
wm8960 record \
wm8960 play

Full Duplex Testing: \
Node 1: \
Already points to .185

Node 2: \
sudo sed -i 's/PEER_IP         = "192.168.8.185"/PEER_IP         = "192.168.8.229"/' /usr/local/bin/wm8960_ptt.py && sudo systemctl restart wm8960-ptt

sudo systemctl stop wm8960-ptt wm8960-mixer
