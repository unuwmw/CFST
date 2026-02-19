#!/bin/bash
export LANG=en_US.UTF-8

# 进入脚本所在目录：确保所有文件与 .sh 同目录时能正常工作
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# 脚本开始：删除旧日志并创建新日志（后续全程只追加，不覆盖不删除）
rm -f ./log.txt
touch ./log.txt
echo "开始时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt

point=443                                   # 目标端口（cfst测速的端口，常用443）
x_email=              # Cloudflare账号邮箱
zone_id=     # Cloudflare Zone ID
api_key= # Cloudflare Global API Key / API Key
CFST_URL_R="-url https://xn--e1a.eu.org/300.zip"   # 下载测速用的测试文件URL, 测速网址更新https://github.com/XIU2/CloudflareSpeedTest/discussions/490
CFST_N=200                                  # 测速线程数（并发数量，越大越快但更吃CPU/网络）
CFST_T=4                                    # 每个IP的测速次数（延迟/HTTPing探测次数）
CFST_DN=5                                  # 输出/保留的优选IP数量（最终写入result.csv并上传DNS的条数上限）
DEFAULT_CFST_TL=200                          # 默认平均延迟上限（ms；CONFIG_LIST未单独填写时用这个值）
CFST_TL=$DEFAULT_CFST_TL                     # 当前使用的平均延迟上限（循环里会被CONFIG_LIST的第三段覆盖）
CFST_TLL=30                                  # 平均延迟下限固定为30ms（低于该值的IP会被过滤/不参与结果）
CFST_TLR=0                                   # 丢包率上限（0 表示过滤任何丢包）
DEFAULT_CFST_SL=0                            # 默认下载速度下限（MB/s；CONFIG_LIST未单独填写时用这个值）
CFST_SL=$DEFAULT_CFST_SL                     # 当前使用的下载速度下限（循环里会被CONFIG_LIST的第四段覆盖）
CFST_SPD=""                                  # 开启测速参数占位，默认留空开启；不需要时可填 -dd 关闭）
ymorip=1                                     # 1=更新Cloudflare DNS；0=仅输出结果不更新DNS
domain=951258.xyz                            # 主域名

# CONFIG_LIST 格式：子域名:地区码(cfcolo，可多个用逗号):平均延迟上限(可选):下载速度下限(可选)
CONFIG_LIST="SG:SIN:100:40 US:LAX,SEA,SJC:200:10 JP:NRT,KIX:100:20"

# 分隔线（加长，便于对齐显示）
SEP_LINE="----------------------------------------------------------------------------------"

cf_login() {
  sed -i '/api.cloudflare.com/d' /etc/hosts
  proxy="false";
  max_retries=5
  for ((i=1; i<=$max_retries; i++)); do
    res=$(curl -sm10 -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}" \
      -H "X-Auth-Email:$x_email" -H "X-Auth-Key:$api_key" -H "Content-Type:application/json")
    resSuccess=$(echo "$res" | jq -r ".success")
    if [[ $resSuccess == "true" ]]; then
      #echo "Cloudflare账号登陆成功!"
      #echo "Cloudflare账号登陆成功!" >> ./log.txt
      break
    elif [ $i -eq $max_retries ]; then
      sed -i '/api.cloudflare.com/d' /etc/hosts
      echo "尝试5次登陆CF失败，检查CF邮箱、区域ID、API Key，这三者信息是否填写正确，或者查下当前代理的网络能否打开Cloudflare官网？"
      echo "尝试5次登陆CF失败，检查CF邮箱、区域ID、API Key，这三者信息是否填写正确，或者查下当前代理的网络能否打开Cloudflare官网？" >> ./log.txt
      echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
      exit 1
    else
      echo "Cloudflare账号登陆失败，尝试重连 ($i/$max_retries)..."
      echo "Cloudflare账号登陆失败，尝试重连 ($i/$max_retries)..." >> ./log.txt
      sed -i '/api.cloudflare.com/d' /etc/hosts
      echo -e "104.18.12.137 api.cloudflare.com\n104.16.160.55 api.cloudflare.com\n104.16.96.55 api.cloudflare.com" >> /etc/hosts
      sleep 2
    fi
  done
}

prune_result_csv() {
  # 返回值约定：0=成功；非0=本轮无有效结果/中断（但不退出主脚本）
  if [ -f "./result.csv" ]; then
    second_line=$(sed -n '2p' ./result.csv | tr -d '[:space:]')
    if [ -z "$second_line" ]; then
      echo "优选IP失败，请尝试更换端口或者重新执行一次"
      echo "优选IP失败，请尝试更换端口或者重新执行一次" >> ./log.txt
      echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
      return 3
    fi

    num=$CFST_DN
    new_num=$((num + 1))

    if [ "$(awk -F, 'NR==2 {print $6}' ./result.csv)" == "0.00" ]; then
      awk -F, "NR<=$new_num" ./result.csv > ./new_result.csv
      mv ./new_result.csv ./result.csv
    fi

    # 按 CFST_DN 动态保留（表头 + CFST_DN 条）
    keep_lines=$((CFST_DN + 1))  # 1 行表头 + DN 行数据
    if awk -F ',' "NR==${keep_lines}+1 {exit 0} END{exit 1}" ./result.csv; then
      awk -F ',' "NR<=${keep_lines}" ./result.csv > ./new_result.csv
      mv ./new_result.csv ./result.csv
    fi

    sed -i '/api.cloudflare.com/d' /etc/hosts
    return 0
  else
    echo "优选IP中断，未生成result.csv文件，请尝试更换端口或者重新执行一次"
    echo "优选IP中断，未生成result.csv文件，请尝试更换端口或者重新执行一次" >> ./log.txt
    echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
    return 4
  fi
}


# 多个优选IP -> 一个域名
ymonly_update() {
  local SUB="$1"
  local CLEAN_TYPE="$2"
  local RECORD_NAME="${SUB}.${domain}"

  echo "正在更新解析：多个优选IP解析到一个域名。请稍后...";
  echo "正在更新解析：多个优选IP解析到一个域名。请稍后..." >> ./log.txt
  url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"
  params="name=${RECORD_NAME}&type=${CLEAN_TYPE}"
  response=$(curl -sm10 -X GET "$url?$params" -H "X-Auth-Email: $x_email" -H "X-Auth-Key: $api_key")

  if [[ $(echo "$response" | jq -r '.success') == "true" ]]; then
    records=$(echo "$response" | jq -r '.result')
    if [[ $(echo "$records" | jq 'length') -gt 0 ]]; then
      for record in $(echo "$records" | jq -c '.[]'); do
        record_id=$(echo "$record" | jq -r '.id')
        delete_url="$url/$record_id"
        delete_response=$(curl -s -X DELETE "$delete_url" -H "X-Auth-Email: $x_email" -H "X-Auth-Key: $api_key")
        if [[ $(echo "$delete_response" | jq -r '.success') == "true" ]]; then
          echo "成功删除 DNS 记录：$(echo "$record" | jq -r '.name')"
          echo "成功删除 DNS 记录：$(echo "$record" | jq -r '.name')" >> ./log.txt
        else
          echo "删除 DNS 记录失败"
          echo "删除 DNS 记录失败" >> ./log.txt
        fi
      done
    else
      echo "没有找到指定的 DNS 记录"
      echo "没有找到指定的 DNS 记录" >> ./log.txt
    fi
  else
    echo "获取 DNS 记录失败"
    echo "获取 DNS 记录失败" >> ./log.txt
    echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
    exit 5
  fi

  if [[ -f "./result.csv" ]]; then
    ips=$(awk -F ',' 'NR > 1 {print $1}' ./result.csv)
    for ip in $ips; do
      if [[ "$ip" =~ ":" ]]; then
        record_type="AAAA"
      else
        record_type="A"
      fi
      data='{
        "type": "'"$record_type"'",
        "name": "'"$RECORD_NAME"'",
        "content": "'"$ip"'",
        "ttl": 60,
        "proxied": false
      }'
      response=$(curl -s -X POST "$url" -H "X-Auth-Email: $x_email" -H "X-Auth-Key: $api_key" -H "Content-Type: application/json" -d "$data")
      if [[ $(echo "$response" | jq -r '.success') == "true" ]]; then
        echo "IP地址 $ip 成功解析到 ${RECORD_NAME}"
        echo "IP地址 $ip 成功解析到 ${RECORD_NAME}" >> ./log.txt
      else
        echo "导入IP地址 $ip 失败"
        echo "导入IP地址 $ip 失败" >> ./log.txt
      fi
      sleep 3
    done
  else
    echo "CSV文件 result.csv 不存在"
    echo "CSV文件 result.csv 不存在" >> ./log.txt
    echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
    exit 6
  fi
}

rm -f ./result.csv

if [ "$ymorip" == "1" ]; then
  cf_login
fi

for cfg in $CONFIG_LIST; do
  OLDIFS="$IFS"
  IFS=':' read -r SUBDOMAIN CFCOLO_CODES CUSTOM_TL CUSTOM_SL <<< "$cfg"
  IFS="$OLDIFS"

  if [ -n "$CUSTOM_TL" ] && [[ "$CUSTOM_TL" =~ ^[0-9]+$ ]]; then
    CFST_TL="$CUSTOM_TL"
  else
    CFST_TL="$DEFAULT_CFST_TL"
  fi

  if [ -n "$CUSTOM_SL" ] && [[ "$CUSTOM_SL" =~ ^[0-9]+$ ]]; then
    CFST_SL="$CUSTOM_SL"
  else
    CFST_SL="$DEFAULT_CFST_SL"
  fi

  for IP_ADDR in ipv4 ipv6; do
    # 每次执行 cfst 命令前都清理 result.csv（log.txt 保留）
    rm -f ./result.csv

    if [ "$IP_ADDR" = "ipv6" ]; then
      if [ ! -f "./ipv6.txt" ]; then
        echo "当前工作模式为ipv6，但该目录下没有【ipv6.txt】，请配置【ipv6.txt】。下载地址：https://github.com/XIU2/CloudflareSpeedTest/releases";
        echo "当前工作模式为ipv6，但该目录下没有【ipv6.txt】，请配置【ipv6.txt】。下载地址：https://github.com/XIU2/CloudflareSpeedTest/releases" >> ./log.txt
        continue
      else
        echo "$SEP_LINE"
        echo "开始执行：国家 $SUBDOMAIN | 地区码 $CFCOLO_CODES | 延迟阈值 $CFST_TL | 下载速度下限 $CFST_SL | 工作模式为ipv6"
        echo "$SEP_LINE"
        echo "$SEP_LINE" >> ./log.txt
        echo "开始执行：国家 $SUBDOMAIN | 地区码 $CFCOLO_CODES | 延迟阈值 $CFST_TL | 下载速度下限 $CFST_SL | 工作模式为ipv6" >> ./log.txt
        echo "$SEP_LINE" >> ./log.txt
      fi
      ./cfst -tp $point $CFST_URL_R -t $CFST_T -n $CFST_N -dn $CFST_DN -p $CFST_DN -httping -cfcolo "$CFCOLO_CODES" -tl "$CFST_TL" -tll "$CFST_TLL" -tlr "$CFST_TLR" -sl $CFST_SL -f ./ipv6.txt $CFST_SPD -dt 8

    else
      if [ ! -f "./ip.txt" ]; then
        echo "当前工作模式为ipv4，但该目录下没有【ip.txt】，请配置【ip.txt】。下载地址：https://github.com/XIU2/CloudflareSpeedTest/releases";
        echo "当前工作模式为ipv4，但该目录下没有【ip.txt】，请配置【ip.txt】。下载地址：https://github.com/XIU2/CloudflareSpeedTest/releases" >> ./log.txt
        continue
      fi
      echo "$SEP_LINE"
      echo "开始执行：国家 $SUBDOMAIN | 地区码 $CFCOLO_CODES | 延迟阈值 $CFST_TL | 下载速度下限 $CFST_SL | 工作模式为ipv4"
      echo "$SEP_LINE"
      echo "$SEP_LINE" >> ./log.txt
      echo "开始执行：国家 $SUBDOMAIN | 地区码 $CFCOLO_CODES | 延迟阈值 $CFST_TL | 下载速度下限 $CFST_SL | 工作模式为ipv4" >> ./log.txt
      echo "$SEP_LINE" >> ./log.txt
      ./cfst -tp $point $CFST_URL_R -t $CFST_T -n $CFST_N -dn $CFST_DN -p $CFST_DN -httping -cfcolo "$CFCOLO_CODES" -tl "$CFST_TL" -tll "$CFST_TLL" -tlr "$CFST_TLR" -sl $CFST_SL -f ./ip.txt $CFST_SPD -dt 8

    fi

    # 不再因为 result.csv 缺失/空而直接 exit，而是继续下一轮（ipv6/下一个国家）
    if ! prune_result_csv; then
      echo "本轮未获得有效优选IP，继续下一轮..."
      echo "本轮未获得有效优选IP，继续下一轮..." >> ./log.txt
      continue
    fi

    echo "测速完毕";
    echo "测速完毕" >> ./log.txt

    if [ "$ymorip" == "1" ]; then
      if [ "$IP_ADDR" = "ipv6" ]; then
        ymonly_update "$SUBDOMAIN" "AAAA"
      else
        ymonly_update "$SUBDOMAIN" "A"
      fi
    else
      echo "优选IP排名如下" >> ./log.txt
      awk -F ',' 'NR > 1 {print $1}' ./result.csv >> ./log.txt
    fi
  done
done

echo "结束时间：$(date '+%Y-%m-%d %H:%M:%S')" >> ./log.txt
exit
