rm -f ~/golden_image_creation.sh &&
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" -o ~/golden_image_creation.sh &&
chmod +x ~/golden_image_creation.sh &&
sudo bash ~/golden_image_creation.sh &&
rm -f ~/golden_image_creation.sh


wget https://raw.githubusercontent.com/badandyc/Testing/master/WM8960/wm8960_setup.sh && \
chmod +x wm8960_setup.sh && \
sudo ./wm8960_setup.sh && \
sudo reboot
