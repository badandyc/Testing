rm -f ~/ads1115_calibrate.py && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/ADS1115/ads1115_calibrate.py?$(date +%s)" -o ~/ads1115_calibrate.py && \
python3 ~/ads1115_calibrate.py
