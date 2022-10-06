#!/bin/bash

AVAILABLE_ARCHITECTURES="amd64 arm64 armhf"

cat > generated_config.yml <<EOF
version: 2.1

commands:
  armhf-setup:
    # Sets-up the environment to run armhf builds.
    # Ref: https://thegeeklab.de/posts/2020/09/run-an-arm32-docker-daemon-on-arm64-servers/
    steps:
      - run:
          name: Setup armhf environment
          command: |
            cat _escapeme_<<EOF | sudo tee /etc/apt/sources.list.d/docker-armhf.list
            deb [arch=armhf] https://download.docker.com/linux/ubuntu focal stable
            EOF
            sudo dpkg --add-architecture armhf
            sudo apt-get update
            sudo systemctl stop docker
            sudo systemctl stop containerd
            sudo systemctl disable docker
            sudo systemctl disable containerd
            sudo ln -sf /bin/true /usr/sbin/update-initramfs
            sudo apt-get install --yes docker-ce:armhf docker-ce-cli:armhf docker-ce-rootless-extras:armhf docker-compose-plugin:armhf
            sudo mkdir -p /etc/systemd/system/containerd.service.d
            sudo mkdir -p /etc/systemd/system/docker.service.d
            cat _escapeme_<<EOF | sudo tee /etc/systemd/system/containerd.service.d/arm32.conf
            [Service]
            ExecStart=
            ExecStart=/usr/bin/setarch linux32 -B /usr/bin/containerd
            EOF
            cat _escapeme_<<EOF | sudo tee /etc/systemd/system/docker.service.d/arm32.conf
            [Service]
            ExecStart=
            ExecStart=/usr/bin/setarch linux32 -B /usr/bin/dockerd -H unix:// --containerd=/run/containerd/containerd.sock
            EOF
            sudo systemctl daemon-reload
            sudo systemctl start containerd
            sudo systemctl start docker

  debian-build:
    parameters:
      suite:
        type: string
        default: "bookworm"
      architecture:
        type: string
        default: "arm64"
      full_build:
        type: string # yes or no
        default: "yes"
      extra_repos:
        type: string
        default: ""
      host_arch:
        type: string
        default: ""
    steps:
      - run:
          name: <<parameters.architecture>> build
          command: |
            mkdir -p /tmp/buildd-results ; \\
            git clone -b "$CIRCLE_BRANCH" "${CIRCLE_REPOSITORY_URL//git@github.com:/https:\/\/github.com\/}" sources ; \\
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_TAG \\
              -e EXTRA_REPOS="<<parameters.extra_repos>>" \\
              -e RELENG_FULL_BUILD="<<parameters.full_build>>" \\
              -e RELENG_HOST_ARCH="<<parameters.host_arch>>" \\
              -v /tmp/buildd-results:/buildd \\
              -v ${PWD}/sources:/buildd/sources \\
              quay.io/droidian/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /buildd/sources ; releng-build-package"

  deploy:
    parameters:
      suite:
        type: string
        default: "bookworm"
      architecture:
        type: string
        default: "arm64"
    steps:
      - run:
          name: <<parameters.architecture>> deploy
          command: |
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_PROJECT_USERNAME \\
              -e CIRCLE_PROJECT_REPONAME \\
              -e CIRCLE_TAG \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEY="\$(echo \${GPG_STAGINGPRODUCTION_SIGNING_KEY} | base64 -d)" \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEYID \\
              -e INTAKE_SSH_USER \\
              -e INTAKE_SSH_KEY="\$(echo \${INTAKE_SSH_KEY} | base64 -d)" \\
              -v /tmp/buildd-results:/tmp/buildd-results \\
              quay.io/droidian/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /tmp/buildd-results ; repo-droidian-sign.sh ; repo-droidian-deploy.sh"

jobs:
EOF

# Determine which architectures to build
ARCHITECTURES="$(grep 'Architecture:' debian/control | awk '{ print $2 }' | sort -u | grep -v all)"
if echo "${ARCHITECTURES}" | grep -q "any"; then
    ARCHITECTURES="${AVAILABLE_ARCHITECTURES}"
fi

# Host arch specified?
HOST_ARCH="$(grep 'XS-Droidian-Host-Arch:' debian/control | head -n 1 | awk '{ print $2 }')" || true
BUILD_ON="$(grep 'XS-Droidian-Build-On:' debian/control | head -n 1 | awk '{ print $2 }')" || true
if [ -n "${HOST_ARCH}" ] && [ -n "${BUILD_ON}" ]; then
    ARCHITECTURES="${BUILD_ON}"
elif [ -n "${HOST_ARCH}" ]; then
    echo "Both XS-Droidian-Host-Arch and XS-Droidian-Build-On must be specified to allow crossbuilds" >&2
    exit 1
fi

# Retrieve EXTRA_REPOS
EXTRA_REPOS="$(grep 'XS-Droidian-Extra-Repos:' debian/control | cut -d ' ' -f2-)" || true

# Determine suite
SUITE="$(echo ${CIRCLE_BRANCH} | cut -d/ -f2)"

full_build="yes"
for arch in ${ARCHITECTURES}; do
    if [ "${arch}" == "amd64" ]; then
        resource_class="medium"
    else
        resource_class="arm.medium"
    fi

    if [ "${arch}" == "armhf" ]; then
        prepare="- armhf-setup"
    else
        prepare=""
    fi

    cat >> generated_config.yml <<EOF
  build-${arch}:
    machine:
      image: ubuntu-2004:current
      resource_class: ${resource_class}
    steps:
      ${prepare}
      - debian-build:
          suite: "${SUITE}"
          architecture: "${arch}"
          full_build: "${full_build}"
          host_arch: "${HOST_ARCH}"
          extra_repos: "${EXTRA_REPOS}"
      - deploy:
          suite: "${SUITE}"
          architecture: "${arch}"
EOF

    full_build="no"
done

cat >> generated_config.yml <<EOF
workflows:
  build:
    jobs:
EOF

for arch in ${ARCHITECTURES}; do
    cat >> generated_config.yml <<EOF
      - build-${arch}:
          context:
            - droidian-buildd
EOF
done

# Workaround for circleci import() misbehaviour
sed -i 's|_escapeme_<|\\<|g' generated_config.yml
