#!/usr/bin/env bash
 WORKDIR=$(pwd)
LOCAL_HOSTNAME="gitlab.local"
LOCAL_URL="http://gitlab.local"
GITLAB_ROOT_PASSWORD="sourcefuse"
INITIAL_GITLAB_GROUP="agroup"
GITLAB_EXTERNAL_PORT="8080"
HOST_IP=$(hostname -I | awk '{print $1}')

## create the directory and prep
mkdir -p $WORKDIR
cd $WORKDIR
touch ./config.toml

## insert/update hosts entry
matches_in_hosts="$(grep -n $LOCAL_HOSTNAME /etc/hosts | cut -f1 -d:)"
hosts_entry="127.0.0.1 ${LOCAL_HOSTNAME}"

if [ ! -z "$matches_in_hosts" ]; then
  echo "Updating existing hosts entry."
  # iterate over the line numbers on which matches were found
  while read -r line_number; do
      # replace the text of each line with the desired host entry
      sudo sed -i '' "${line_number}s/.*/${hosts_entry} /" /etc/hosts
  done <<< "$matches_in_hosts"
else
  echo "Adding new hosts entry."
  echo "$hosts_entry" | sudo tee -a /etc/hosts > /dev/null
fi

## create docker-compose.yml file
cat << EOF >docker-compose.yml
---
version: '3'
services:
  omnibus:
    image: "gitlab/gitlab-ee:13.11.3-ee.0"
    container_name: gitlab
    restart: unless-stopped
    hostname: ${LOCAL_HOSTNAME}
    extra_hosts:
      - "${LOCAL_HOSTNAME}:${HOST_IP}"
    environment:
      GITLAB_ROOT_PASSWORD: ${GITLAB_ROOT_PASSWORD}
      GITLAB_OMNIBUS_CONFIG: |
        external_url '${LOCAL_URL}:${GITLAB_EXTERNAL_PORT}'
        nginx['listen_port'] = 80
        gitlab_rails['gitlab_shell_ssh_port'] = 2022
    ports:
      - "${GITLAB_EXTERNAL_PORT}:80"
      - "3443:443"
      - "2022:22"
    volumes:
      - /srv/gitlab/config:/etc/gitlab
      - /srv/gitlab/logs:/var/log/gitlab
      - /srv/gitlab/data:/var/opt/gitlab

  runner:
      image: gitlab/gitlab-runner:alpine
      container_name: runner
      restart: unless-stopped
      depends_on:
        - omnibus
      extra_hosts:
        - "${LOCAL_HOSTNAME}:${HOST_IP}"
      volumes:
        - ./config.toml:/etc/gitlab-runner/config.toml:ro
        - /var/run/docker.sock:/var/run/docker.sock

EOF

## bring up omnibus and runner
docker-compose up -d

## sleep for 7 mins while gitlab configures itself
#sleep 420
sleep 180

## authenticate using root
body_header=$(curl -k -L -c cookies.txt -i "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/users/sign_in" -s)
csrf_token=$(echo $body_header | perl -ne 'print "$1\n" if /new_user.*?authenticity_token"[[:blank:]]value="(.+?)"/' | sed -n 1p)

curl -k -L -b cookies.txt -c cookies.txt -i "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/users/sign_in" \
    --data "user[login]=root&user[password]=${GITLAB_ROOT_PASSWORD}" \
    --data-urlencode "authenticity_token=${csrf_token}"

## get auth token
body_header=$(curl -k -L -H 'user-agent: curl' -b cookies.txt -i "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/profile/personal_access_tokens" -s)
csrf_token=$(echo $body_header | perl -ne 'print "$1\n" if /authenticity_token"[[:blank:]]value="(.+?)"/' | sed -n 1p)

# curl POST request to send the "generate personal access token form"
body_header=$(curl -k -L -b cookies.txt "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/-/profile/personal_access_tokens" \
    --data-urlencode "authenticity_token=${csrf_token}" \
    --data 'personal_access_token[name]=auto-generated&personal_access_token[expires_at]=&personal_access_token[scopes][]=api')

# Scrape the personal access token from the response HTML
PERSONAL_ACCESS_TOKEN=$(echo $body_header | perl -ne 'print "$1\n" if /created-personal-access-token"[[:blank:]]value="(.+?)"/' | sed -n 1p)

## create the group and get the ids
curl --request POST \
  --insecure \
  --header "PRIVATE-TOKEN: $PERSONAL_ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"path\": \"${INITIAL_GITLAB_GROUP}\", \"name\": \"${INITIAL_GITLAB_GROUP}\"}" \
  "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/api/v4/groups/"

sudo apt install jq -y

GROUP_IDS=$(curl -k --header "Private-Token: $PERSONAL_ACCESS_TOKEN" "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/api/v4/groups?name=${INITIAL_GITLAB_GROUP}")

echo $GROUP_IDS | jq -c '.[]' | while read i; do
  id=$(echo $i | jq .id)
  name=$(echo $i | jq .name)

  if [[ $name =~ $INITIAL_GITLAB_GROUP ]]; then
    REGISTRATION_TOKEN=$(curl -k --header "Private-Token: $PERSONAL_ACCESS_TOKEN" "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/api/v4/groups/${id}" | jq -r '.runners_token')

    RUNNER_TOKEN=$(curl --request POST "${LOCAL_URL}:$GITLAB_EXTERNAL_PORT/api/v4/runners" \
      --insecure \
      --form "token=${REGISTRATION_TOKEN}" \
      --form "description=Sample runner" | jq -r .token)

    cat << EOF >config.toml
concurrent = 3
log_level = "warning"
check_interval = 0

[[runners]]
  name = "local-runner"
  url = "${LOCAL_URL}:${GITLAB_EXTERNAL_PORT}"
  token = "${RUNNER_TOKEN}"
  executor = "docker"
  environment = ["DOCKER_DRIVER=overlay2"]
  [runners.custom_build_dir]
  [runners.docker]
    image = "docker:20.10.9-dind"
    privileged = true
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    shm_size = 0
    wait_for_services_timeout = 120
    extra_hosts = ["${LOCAL_HOSTNAME}:${HOST_IP}"]
    pull_policy = "always"
    volumes = [
      "/cache",
      "/var/run/docker.sock:/var/run/docker.sock",
      "/var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket"
    ]
    allowed_images = [
      "*",
      "*/*"
    ]
EOF
  fi
done

docker restart runner
