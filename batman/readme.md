rm -f ~/batman.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/batman/batman/batman.sh?$(date +%s)" -o ~/batman.sh && \
chmod +x ~/batman.sh && \
sudo bash ~/batman.sh XX && \
rm -f ~/batman.sh
