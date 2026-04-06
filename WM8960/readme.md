rm -f ~/wm8960_setup.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_setup.sh?$(date +%s)" -o ~/wm8960_setup.sh && \
chmod +x ~/wm8960_setup.sh && \
sudo bash ~/wm8960_setup.sh && \
rm -f ~/wm8960_setup.sh

wm8960 play sound_check.wav \
wm8960 record \
wm8960 play
