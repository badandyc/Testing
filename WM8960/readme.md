rm -f ~/wm8960_setup.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_setup.sh?$(date +%s)" -o ~/wm8960_setup.sh && \
chmod +x ~/wm8960_setup.sh && \
sudo bash ~/wm8960_setup.sh && \
rm -f ~/wm8960_setup.sh

wm8960 play sound_check.wav \
wm8960 record \
wm8960 play

amixer -c 0 cset numid=4 1 \
amixer -c 0 cset numid=6 1

arecord -D hw:0,0 -f S32_LE -r 16000 -c 2 -d 5 /home/birddog/silent.wav && sox /home/birddog/silent.wav -n stat && wm8960 play /home/birddog/silent.wav

arecord -D hw:0,0 -f S32_LE -r 16000 -c 2 -d 5 /home/birddog/talking.wav && sox /home/birddog/talking.wav -n stat && wm8960 play /home/birddog/talking.wav

sudo systemctl stop wm8960-ptt wm8960-mixer
