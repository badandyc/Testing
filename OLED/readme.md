rm -f ~/oled_test.py && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/OLED/oled_test.py?$(date +%s)" -o ~/oled_test.py && \
sudo python3 ~/oled_test.py
