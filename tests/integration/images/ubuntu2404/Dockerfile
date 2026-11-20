FROM ubuntu:24.04

ARG PUBKEY
ENV container=docker DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server sudo \
      iproute2 ca-certificates python3-minimal \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /lib/systemd/system/multi-user.target.wants/* \
      /etc/systemd/system/*.wants/* \
      /lib/systemd/system/local-fs.target.wants/* \
      /lib/systemd/system/sockets.target.wants/*udev* \
      /lib/systemd/system/sockets.target.wants/*initctl* \
      /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
      /lib/systemd/system/systemd-update-utmp* \
 && systemctl enable ssh

RUN useradd -m -s /bin/bash fettle \
 && useradd -m -s /bin/bash fettlepw \
 && echo 'fettlepw:fettlepw' | chpasswd \
 && echo 'fettle ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/fettle \
 && echo 'fettlepw ALL=(ALL) ALL' > /etc/sudoers.d/fettlepw \
 && chmod 0440 /etc/sudoers.d/fettle /etc/sudoers.d/fettlepw \
 && for u in fettle fettlepw; do \
      install -d -m 700 -o $u -g $u /home/$u/.ssh \
      && echo "$PUBKEY" > /home/$u/.ssh/authorized_keys \
      && chown $u:$u /home/$u/.ssh/authorized_keys \
      && chmod 600 /home/$u/.ssh/authorized_keys; \
    done \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
      > /etc/ssh/sshd_config.d/10-fettle.conf

STOPSIGNAL SIGRTMIN+3
EXPOSE 22
CMD ["/sbin/init"]
