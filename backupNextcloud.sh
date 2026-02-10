#!/bin/bash

backupDir=/home/yangn0/disk1T/nextcloudBackups
mkdir -p $backupDir

startTime=`date`
startTime_s=`date +%s`
echo ------------------------------------------------------------------
echo $startTime

# delete old backups
cd $backupDir
if (($(ls -l | grep "d" | wc -l) >= 2))
then
    file_array=($(ls))
    rm -rf ${file_array[0]}
    echo "delete ${file_array[0]}"
fi

docker exec --user www-data -i nextcloud php occ maintenance:mode --on || (echo 'Nextcloud开启维护模式失败' && exit)
cd /home/yangn0/disk6T/
mkdir $backupDir/nextcloud-${startTime_s}
tar -zcf - nextcloud | split -d -b 20G - $backupDir/nextcloud-${startTime_s}/nextcloud-${startTime_s}.tgz.
echo nextcloud-${startTime_s} '打包成功'
docker exec --user www-data -i nextcloud php occ maintenance:mode --off

cd /home/yangn0/aliyunpan/
backup_dir=$backupDir/nextcloud-${startTime_s}
for file in `ls $backup_dir`
  do
    ./aliyunpan upload ${backup_dir}/$file /NASbackups/nextcloudBackups/nextcloud-${startTime_s}
  done

# --verbose
# delete old backups in aliyunpan
cd /home/yangn0/aliyunpan/
# ./aliyunpan recycle d --all
./aliyunpan drive 99819931
./aliyunpan cd /NASbackups/nextcloudBackups
if (($(./aliyunpan l --name -asc | grep -o  " nextcloud-[0-9]*"| wc -l) >= 3))
then
    file_array=($(./aliyunpan l --name -asc | grep -o  " nextcloud-[0-9]*"))
    ./aliyunpan rm ${file_array[0]}
fi

endTime=`date`
endTime_s=`date +%s`

sumTime=$[ $endTime_s - $startTime_s ]

echo "$startTime ---> $endTime" "Total:$sumTime seconds"
