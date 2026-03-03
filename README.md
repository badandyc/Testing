BDM
Step 1: Bootstrap (hostname + Avahi)
rm -f bdm_initial_setup && \
curl -fsSL https://raw.githubusercontent.com/badandyc/Testing/master/bdm_initial_setup -o bdm_initial_setup && \
sudo bash bdm_initial_setup

Step 2: Build AP + Networking
rm -f bdm_AP_setup && \
curl -fsSL https://raw.githubusercontent.com/badandyc/Testing/master/bdm_AP_setup -o bdm_AP_setup && \
sudo bash bdm_AP_setup

Step 3: Install MediaMTX
rm -f bdm_mediamtx_setup && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/Testing/master/bdm_mediamtx_setup?$(date +%s)" -o bdm_mediamtx_setup && \
sudo bash bdm_mediamtx_setup

Step 4: Install Nginx
rm -f bdm_web_setup.sh && \
curl -fsSL https://raw.githubusercontent.com/badandyc/Testing/master/bdm_web_setup.sh -o bdm_web_setup.sh && \
sudo bash bdm_web_setup.sh

BDC
Step 1: Bootstrap
rm -f bdc_fresh_install_setup.sh && \
curl -fsSL https://raw.githubusercontent.com/badandyc/Testing/master/bdc_fresh_install_setup.sh -o bdc_fresh_install_setup.sh && \
sudo bash bdc_fresh_install_setup.sh

MISC:
ping <bdm-hostname>.local
systemctl status birddog-stream
http://10.10.10.1:8889/cam01
sshkeygen -R x.x.x.x
