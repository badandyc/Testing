rm -f ~/keypad_test.py && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/keypad/keypad_test.py?$(date +%s)" -o ~/keypad_test.py && \
sudo python3 ~/keypad_test.py
