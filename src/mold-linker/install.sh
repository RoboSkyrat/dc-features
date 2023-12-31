#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# modified version of the install script from devcontainers/features for github-cli

MOLD_VERSION=${VERSION:-"latest"}
INSTALL_DIRECTLY_FROM_GITHUB_RELEASE=${INSTALLDIRECTLYFROMGITHUBRELEASE:-"true"}

set -e

# Clean up
rm -rf /var/lib/apt/lists/*

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi


apt_get_update()
{
    if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -y
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"
    fi
}

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}    
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

# Use semver logic to decrement a version number then look for the closest match
find_prev_version_from_git_tags() {
    local variable_name=$1
    local current_version=${!variable_name}
    local repository=$2
    # Normally a "v" is used before the version number, but support alternate cases
    local prefix=${3:-"tags/v"}
    # Some repositories use "_" instead of "." for version number part separation, support that
    local separator=${4:-"."}
    # Some tools release versions that omit the last digit (e.g. go)
    local last_part_optional=${5:-"false"}
    # Some repositories may have tags that include a suffix (e.g. actions/node-versions)
    local version_suffix_regex=$6
    # Try one break fix version number less if we get a failure. Use "set +e" since "set -e" can cause failures in valid scenarios.
    set +e
        major="$(echo "${current_version}" | grep -oE '^[0-9]+' || echo '')"
        minor="$(echo "${current_version}" | grep -oP '^[0-9]+\.\K[0-9]+' || echo '')"
        breakfix="$(echo "${current_version}" | grep -oP '^[0-9]+\.[0-9]+\.\K[0-9]+' 2>/dev/null || echo '')"

        if [ "${minor}" = "0" ] && [ "${breakfix}" = "0" ]; then
            ((major=major-1))
            declare -g ${variable_name}="${major}"
            # Look for latest version from previous major release
            find_version_from_git_tags "${variable_name}" "${repository}" "${prefix}" "${separator}" "${last_part_optional}"
        # Handle situations like Go's odd version pattern where "0" releases omit the last part
        elif [ "${breakfix}" = "" ] || [ "${breakfix}" = "0" ]; then
            ((minor=minor-1))
            declare -g ${variable_name}="${major}.${minor}"
            # Look for latest version from previous minor release
            find_version_from_git_tags "${variable_name}" "${repository}" "${prefix}" "${separator}" "${last_part_optional}"
        else
            ((breakfix=breakfix-1))
            if [ "${breakfix}" = "0" ] && [ "${last_part_optional}" = "true" ]; then
                declare -g ${variable_name}="${major}.${minor}"
            else 
                declare -g ${variable_name}="${major}.${minor}.${breakfix}"
            fi
        fi
    set -e
}

# Fall back on direct download if no apt package exists
# Fetches .tar.gz file
install_tgz_using_github() {
    check_packages wget tar
    arch=$(uname -m)

    find_version_from_git_tags MOLD_VERSION https://github.com/rui314/mold
    mold_filename="mold-${MOLD_VERSION}-${arch}-linux"

    mkdir -p /tmp/mold
    pushd /tmp/mold
    wget https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}/${mold_filename}.tar.gz
    exit_code=$?
    set -e
    if [ "$exit_code" != "0" ]; then
        # Handle situation where git tags are ahead of what was is available to actually download
        echo "(!) mold version ${MOLD_VERSION} failed to download. Attempting to fall back one version to retry..."
        find_prev_version_from_git_tags MOLD_VERSION https://github.com/rui314/mold
        wget https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}/${mold_filename}.tar.gz
    fi

    tar -xzf ${mold_filename}.tar.gz

    # Make them executable
    chmod +x ${mold_filename}/bin/*

    # Move the files
    cp ${mold_filename}/bin/* /bin/
    popd

    rm -rf /tmp/mold
}

export DEBIAN_FRONTEND=noninteractive

check_packages curl ca-certificates apt-transport-https
if ! type git > /dev/null 2>&1; then
    check_packages git
fi

# Soft version matching
if [ "${MOLD_VERSION}" != "latest" ] && [ "${MOLD_VERSION}" != "lts" ] && [ "${MOLD_VERSION}" != "stable" ]; then
    find_version_from_git_tags MOLD_VERSION "https://github.com/rui314/mold"
    version_suffix="=${MOLD_VERSION}"
else
    version_suffix=""
fi

# Install mold
echo "Downloading Mold..."

if [ "${INSTALL_DIRECTLY_FROM_GITHUB_RELEASE}" = "true" ]; then
    install_tgz_using_github
else
    . /etc/os-release
    apt-get update
    apt-get -y install "mold${version_suffix}"
    echo "Done!"
fi

# Clean up
rm -rf /var/lib/apt/lists/*