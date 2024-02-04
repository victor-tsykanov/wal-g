#!/bin/sh
set -e -x
CONFIG_FILE="/tmp/configs/delete_retain_after_test_config.json"
COMMON_CONFIG="/tmp/configs/common_config.json"
TMP_CONFIG="/tmp/configs/tmp_config.json"
cat ${CONFIG_FILE} > ${TMP_CONFIG}
echo "," >> ${TMP_CONFIG}
cat ${COMMON_CONFIG} >> ${TMP_CONFIG}
/tmp/scripts/wrap_config_file.sh ${TMP_CONFIG}

/usr/lib/postgresql/10/bin/initdb ${PGDATA}

echo "archive_mode = on" >> /var/lib/postgresql/10/main/postgresql.conf
echo "archive_command = '/usr/bin/timeout 600 /usr/bin/wal-g --config=${TMP_CONFIG} wal-push %p'" >> /var/lib/postgresql/10/main/postgresql.conf
echo "archive_timeout = 600" >> /var/lib/postgresql/10/main/postgresql.conf

/usr/lib/postgresql/10/bin/pg_ctl -D ${PGDATA} -w start
/tmp/scripts/wait_while_pg_not_ready.sh
wal-g --config=${TMP_CONFIG} delete everything FORCE --confirm

for i in 1 2 3 4
do
    pgbench -i -s 1 postgres &
    sleep 1
    wal-g --config=${TMP_CONFIG} backup-push ${PGDATA}
    if [ $i = 2 ]
    then
      sleep 1
      retain_time=`date -u +%Y-%m-%dT%H:%M:%SZ`
    fi
done

wal-g --config=${TMP_CONFIG} backup-list
lines_before_delete=`wal-g --config=${TMP_CONFIG} backup-list | wc -l`
wal-g --config=${TMP_CONFIG} backup-list > /tmp/list_before_delete

wal-g --config=${TMP_CONFIG} delete retain 1 --after "${retain_time}" --confirm

wal-g --config=${TMP_CONFIG} backup-list
lines_after_delete=`wal-g --config=${TMP_CONFIG} backup-list | wc -l`
wal-g --config=${TMP_CONFIG} backup-list > /tmp/list_after_delete

# we deleted all backups crated after the first two
expected_backups_deleted=$((4-2))

if [ $(($lines_before_delete-$expected_backups_deleted)) -ne $lines_after_delete ];
then
    echo $(($lines_before_delete-$expected_backups_deleted)) > /tmp/before_delete
    echo $lines_after_delete > /tmp/after_delete
    echo "Wrong number of deleted lines"
    diff /tmp/before_delete /tmp/after_delete
fi

# ensure all backups which we weren't going to delete still exist after performing deletion
xargs -I {} grep {} /tmp/list_before_delete </tmp/list_after_delete

/tmp/scripts/drop_pg.sh
rm ${TMP_CONFIG}
