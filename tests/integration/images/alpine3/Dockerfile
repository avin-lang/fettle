FROM alpine:3.20

ARG PUBKEY

RUN apk add --no-cache openrc openssh sudo shadow iproute2 python3 \
 && sed -i 's/^#\?rc_sys=.*/rc_sys="docker"/' /etc/rc.conf \
 && sed -i 's/^#\?rc_provide=.*/rc_provide="loopback net"/' /etc/rc.conf \
 && printf '::sysinit:/sbin/openrc sysinit\n::sysinit:/sbin/openrc boot\n::wait:/sbin/openrc default\n::shutdown:/sbin/openrc shutdown\n' > /etc/inittab \
 && rc-update add sshd default \
 && rm -f /etc/runlevels/*/hwclock /etc/runlevels/*/hwdrivers /etc/runlevels/*/modules \
      /etc/runlevels/*/mdev /etc/runlevels/*/machine-id /etc/runlevels/*/networking \
 && ssh-keygen -A

RUN adduser -D -s /bin/sh fettle \
 && adduser -D -s /bin/sh fettlepw \
 && echo 'fettlepw:fettlepw' | chpasswd \
 && echo 'fettle:*' | chpasswd -e \
 && echo 'fettle ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/fettle \
 && echo 'fettlepw ALL=(ALL) ALL' > /etc/sudoers.d/fettlepw \
 && chmod 0440 /etc/sudoers.d/fettle /etc/sudoers.d/fettlepw \
 && for u in fettle fettlepw; do \
      install -d -m 700 -o $u -g $u /home/$u/.ssh \
      && echo "$PUBKEY" > /home/$u/.ssh/authorized_keys \
      && chown $u:$u /home/$u/.ssh/authorized_keys \
      && chmod 600 /home/$u/.ssh/authorized_keys; \
    done \
 && mkdir -p /etc/ssh/sshd_config.d \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
      > /etc/ssh/sshd_config.d/10-fettle.conf \
 && (grep -q '^Include' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config)

STOPSIGNAL SIGUSR2
EXPOSE 22
CMD ["/sbin/init"]
