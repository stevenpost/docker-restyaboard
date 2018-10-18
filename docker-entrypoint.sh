#!/bin/bash
set -e

if [ "$1" = 'start' ]; then

  # config
  sed -i \
      -e "s/^.*'R_DB_HOST'.*$/define('R_DB_HOST', '${POSTGRES_HOST}');/g" \
      -e "s/^.*'R_DB_PORT'.*$/define('R_DB_PORT', '5432');/g" \
      -e "s/^.*'R_DB_USER'.*$/define('R_DB_USER', '${POSTGRES_USER}');/g" \
      -e "s/^.*'R_DB_PASSWORD'.*$/define('R_DB_PASSWORD', '${POSTGRES_PASSWORD}');/g" \
      -e "s/^.*'R_DB_NAME'.*$/define('R_DB_NAME', '${POSTGRES_DB}');/g" \
      ${ROOT_DIR}/server/php/config.inc.php
  echo $TZ > /etc/timezone
  rm /etc/localtime
  cp /usr/share/zoneinfo/$TZ /etc/localtime
  sed -i "s|;date.timezone = |date.timezone = ${TZ}|" /etc/php/7.0/fpm/php.ini

  # postfix
  echo "[${SMTP_SERVER}]:${SMTP_PORT} ${SMTP_USERNAME}:${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
  postmap /etc/postfix/sasl_passwd
  echo "www-data@${SMTP_DOMAIN} ${SMTP_USERNAME}" > /etc/postfix/sender_canonical
  postmap /etc/postfix/sender_canonical
  sed -i \
      -e '/mydomain.*/d' \
      -e '/myhostname.*/d' \
      -e '/myorigin.*/d' \
      -e '/mydestination.*/d' \
      -e "$ a mydomain = ${SMTP_DOMAIN}" \
      -e "$ a myhostname = localhost" \
      -e '$ a myorigin = $mydomain' \
      -e '$ a mydestination = localhost, $myhostname, localhost.$mydomain' \
      -e '$ a sender_canonical_maps = hash:/etc/postfix/sender_canonical' \
      -e "s/relayhost =.*$/relayhost = [${SMTP_SERVER}]:${SMTP_PORT}/" \
      -e '/smtp_.*/d' \
      -e '$ a smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache' \
      -e '$ a smtp_sasl_auth_enable = yes' \
      -e '$ a smtp_sasl_security_options = noanonymous' \
      -e '$ a smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd' \
      -e '$ a smtp_use_tls = yes' \
      -e '$ a smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt' \
      -e '$ a smtp_tls_security_level = encrypt' \
      -e '$ a smtp_tls_note_starttls_offer = yes' \
      /etc/postfix/main.cf

  # init db
  export PGHOST=${POSTGRES_HOST}
  export PGPORT=5432
  export PGUSER=${POSTGRES_USER}
  export PGPASSWORD=${POSTGRES_PASSWORD}
  export PGDATABASE=${POSTGRES_DB}
  set +e
  while :
  do
    psql -c "\q"
    if [ "$?" = 0 ]; then
      break
    fi
    sleep 1
  done
  if [ "$(psql -c '\d')" = "No relations found." ]; then
    psql -f "${ROOT_DIR}/sql/restyaboard_with_empty_data.sql"
  fi
  set -e

  # cron shell
  echo "*/5 * * * * root ${ROOT_DIR}/server/php/shell/instant_email_notification.sh" >> /etc/cron.d/restya
  echo "0 * * * * root ${ROOT_DIR}/server/php/shell/periodic_email_notification.sh" >> /etc/cron.d/restya
  echo "*/30 * * * * root ${ROOT_DIR}/server/php/shell/imap.sh" >> /etc/cron.d/restya
  echo "*/5 * * * * root ${ROOT_DIR}/server/php/shell/webhook.sh" >> /etc/cron.d/restya
  echo "*/5 * * * * root ${ROOT_DIR}/server/php/shell/card_due_notification.sh" >> /etc/cron.d/restya

  # Let the cron scripts log to syslog
  sed -i '2iexec 1> >(logger -s -t $(basename $0)) 2>&1' "${ROOT_DIR}/server/php/shell/instant_email_notification.sh"
  sed -i '2iexec 1> >(logger -s -t $(basename $0)) 2>&1' "${ROOT_DIR}/server/php/shell/periodic_email_notification.sh"
  sed -i '2iexec 1> >(logger -s -t $(basename $0)) 2>&1' "${ROOT_DIR}/server/php/shell/imap.sh"
  sed -i '2iexec 1> >(logger -s -t $(basename $0)) 2>&1' "${ROOT_DIR}/server/php/shell/webhook.sh"
  sed -i '2iexec 1> >(logger -s -t $(basename $0)) 2>&1' "${ROOT_DIR}/server/php/shell/card_due_notification.sh"

  # Make the cron scripts executable
  chmod +x "/etc/cron.d/restya"
  chmod +x "${ROOT_DIR}/server/php/shell/instant_email_notification.sh"
  chmod +x "${ROOT_DIR}/server/php/shell/periodic_email_notification.sh"
  chmod +x "${ROOT_DIR}/server/php/shell/imap.sh"
  chmod +x "${ROOT_DIR}/server/php/shell/webhook.sh"
  chmod +x "${ROOT_DIR}/server/php/shell/card_due_notification.sh"

  # set the MAIL addresses for cronjobs
  sed -i "1iMAILFROM=${MAILFROM}" /etc/crontab
  sed -i "1iMAILTO=${MAILTO}" /etc/crontab

  crontab /etc/cron.d/restya

  # service start
  service rsyslog start
  service cron start
  service php7.0-fpm start
  service nginx start
  service postfix start

  # tail log
  sleep 1
  exec tail -f /var/log/nginx/access.log \
               /var/log/nginx/error.log \
               /var/log/messages \
               /var/log/syslog \
               /var/log/php7.0-fpm.log
fi

exec "$@"
