# Skip the download when the archive already came with the bind mount.
[ -f ./sing-box-1.12.8-linux-amd64.tar.gz ] || \
wget https://github.com/SagerNet/sing-box/releases/download/v1.12.8/sing-box-1.12.8-linux-amd64.tar.gz

# 2. Распаковываем архив
tar -xf ./sing-box-1.12.8-linux-amd64.tar.gz

# 3. Переносим бинарник в системную папку /usr/local/bin/
sudo mv ./sing-box-1.12.8-linux-amd64/sing-box /usr/local/bin/

# 4. Проверяем, что программа теперь доступна и версия корректна
sing-box version

#mkdir /home/student/vpn-setup
#cp ./config.json /home/student/vpn-setup/config.json

sing-box check -c ./config.json

#gnome-terminal -- bash -c "./test-connection.sh"

# Reopen helper: chromium does not auto-restart, so closing the window
# needs an explicit launch. Symlink (not copy) so the bind-mounted file
# is always the live version.
[ -f /etc/sing-box/open-chromium.sh ] && \
    ln -sf /etc/sing-box/open-chromium.sh /usr/local/bin/open-chromium

sing-box run -c ./config.json
