rm -f ~/golden_image_creation.sh &&
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" -o ~/golden_image_creation.sh &&
chmod +x ~/golden_image_creation.sh &&
sudo bash ~/golden_image_creation.sh &&
rm -f ~/golden_image_creation.sh
