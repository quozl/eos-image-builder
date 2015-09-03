#!/bin/bash
# -*- mode: Shell-script; sh-basic-offset: 2; indent-tabs-mode: nil -*-
shopt -s nullglob
shopt -s extglob

# Show current script and time when xtrace (set -x) enabled. Will look
# like "+ run-build 10:13:40: some command".
export PS4='+ ${BASH_SOURCE[0]##*/} \t: '

EIB_SCRATCH=/var/cache/eos-image-builder
EIB_OSTREE_CHECKOUT=${EIB_SCRATCH}/ostree-co
export EIB_OSTREE=${EIB_SCRATCH}/ostree/${EIB_OSTREE_REPO}
export EIB_DATA=${EIB_SRC}/data
EIB_HELPERS=${EIB_SRC}/helpers
EIB_OUT_ROOT=${EIB_SCRATCH}/out
EIB_CACHEDIR=${EIB_SCRATCH}/cache
EIB_TMPDIR=${EIB_SCRATCH}/tmp
EIB_OSTREE_TMPDIR=${EIB_TMPDIR}/ostree-bin
export EIB_CONTENT=/var/eib/content
export EIB_APPS_CONTENT=${EIB_CONTENT}/apps

# Run hooks under customization/
run_hooks() {
  echo "Running $1 customization"
  local hook interpreter
  local install_root=$2

  # Combine hooks from all and product dirs, but sort them by basename
  pushd "${EIB_SRC}"/customization &>/dev/null
  local files=$(printf "%s\n" {all,${EIB_PRODUCT}}/$1/* | sort -t '/' -k 3)
  popd &>/dev/null

  for hook in ${files}; do
    # Skip backup files
    [ "${hook: -1}" = "~" ] && continue
    hookpath="${EIB_SRC}"/customization/${hook}
    if [ "${hook: -7}" == ".chroot" ]; then
      if [ -z "$install_root" ]; then
        echo "Skipping hook, no chroot available: ${hook}"
        continue
      fi

      echo "Run hook in chroot: ${hook}"
      [ -x "${hook}" ] && interpreter= || interpreter="bash -ex"
      mkdir -p $install_root/tmp
      cp ${hookpath} $install_root/tmp/hook
      chroot $install_root $interpreter /tmp/hook
      rm -f $install_root/tmp/hook
      continue
    fi

    echo "Run hook: ${hook}"
      
    if [ -x "${hookpath}" ]; then
      ${hookpath}
    else
      (
        . ${hookpath}
      )
    fi
  done
}

eib_version() {
  echo ${EIB_PRODUCT}-${EIB_BRANCH}-${EIB_ARCH}-${EIB_PLATFORM}.${EIB_BUILD_VERSION}.${EIB_PERSONALITY}
}

# Generate full path to output directory
eib_outdir() {
  echo ${EIB_OUT_ROOT}/${EIB_PERSONALITY}
}

# Generate full path to output file
eib_outfile() {
  echo $(eib_outdir)/$(eib_version).$1
}

# Generate full remote output directory
eib_image_dest() {
  echo ${EIB_IMAGE_PATH}/${EIB_PRODUCT}-${EIB_ARCH}-${EIB_PLATFORM}/${EIB_BRANCH}/${EIB_PERSONALITY}/${EIB_BUILD_VERSION}
}

# Generate full remote url
eib_image_url() {
  echo ${EIB_IMAGE_URL_ROOT}/${EIB_PRODUCT}-${EIB_ARCH}-${EIB_PLATFORM}/${EIB_BRANCH}/${EIB_PERSONALITY}/${EIB_BUILD_VERSION}
}

# Encode the original image version and personality as an xattr of the
# root directory of each partition.
# Usage: <root directory path> <personality>
eib_write_version_xattr() {
  attr -s eos-image-version -V "$(eib_version).$2" "$1"
}

# Declare the EIB_MOUNTS array, but don't reinitialize it.
declare -a EIB_MOUNTS

# Mount a filesystem and track the target mount point.
eib_mount() {
  local target

  if [ $# -lt 2 ]; then
    echo "At least 2 arguments needed to $FUNCNAME" >&2
    return 1
  fi

  mount "$@"

  # The target is the last argument
  eval target="\${$#}"
  EIB_MOUNTS+=("${target}")
}

# Unmount all tracked mount points.
eib_umount_all() {
  local -i n

  # Work from the end of the array to unmount submounts first
  for ((n = ${#EIB_MOUNTS[@]} - 1; n >= 0; n--)); do
    umount "${EIB_MOUNTS[n]}"
  done

  # Clear and re-declare the array
  unset EIB_MOUNTS
  declare -a EIB_MOUNTS
}

# Path to the build specific cache directory. The build version is not
# included since the files will be persistent.
eib_cachedir() {
  echo "${EIB_CACHEDIR}"/${EIB_PRODUCT}-${EIB_BRANCH}-${EIB_ARCH}-${EIB_PLATFORM}
}

# Generate full path to cache file.
eib_cachefile() {
  echo "$(eib_cachedir)/$1"
}

# Provide the path to the keyring file. If it doesn't exist, create it.
eib_keyring() {
  local keyring="${EIB_TMPDIR}"/eib-keyring.gpg
  local keysdir="${EIB_DATA}"/keys
  local -a keys
  local keyshome key

  # Create the keyring if necessary
  if [ ! -f "${keyring}" ]; then
    # Check that there are keys
    if [ ! -d "${keysdir}" ]; then
      echo "No gpg keys directory at ${keysdir}" >&2
      return 1
    fi
    keys=("${keysdir}"/*.asc)
    if [ ${#keys[@]} -eq 0 ]; then
      echo "No gpg keys in ${keysdir}" >&2
      return 1
    fi

    # Create a homedir with proper 0700 perms so gpg doesn't complain
    keyshome=$(mktemp -d --tmpdir="${EIB_TMPDIR}" eib-keyring.XXXXXXXXXX)

    # Import the keys
    for key in "${keys[@]}"; do
      gpg --batch --quiet --homedir "${keyshome}" --keyring "${keyring}" \
        --no-default-keyring --import "${key}"
    done

    # Set normal permissions for the keyring since gpg creates it 0600
    chmod 0644 "${keyring}"

    rm -rf "${keyshome}"
  fi

  echo "${keyring}"
}

eib_fix_boot_checksum() {
  local disk=${1:?No disk supplied to ${FUNCNAME}}
  local deploy=${2:?No deployment supplied to ${FUNCNAME}}

  [ -x "${deploy}"/usr/sbin/amlogic-fix-spl-checksum ] || return 0
  "${deploy}"/usr/sbin/amlogic-fix-spl-checksum "${disk}"
}

# Create a .inprogress file on the remote image server to indicate that
# this build has started publishing files.
eib_start_publishing() {
  local destdir="$(eib_image_dest)"

  # Skip on dry runs
  [ -n "${EIB_DRY_RUN}" ] && return 0

  if [ "$(hostname -s)" != "${EIB_IMAGE_HOST_SHORT}" ]; then
    ssh ${EIB_IMAGE_USER}@${EIB_IMAGE_HOST} mkdir -p "${destdir}"
    ssh ${EIB_IMAGE_USER}@${EIB_IMAGE_HOST} touch \
      "${destdir}"/.inprogress
  else
    sudo -u ${EIB_IMAGE_USER} mkdir -p "${destdir}"
    sudo -u ${EIB_IMAGE_USER} touch "${destdir}"/.inprogress
  fi
}

# Delete the .inprogress file on the remote image server to indicate
# that this build has finished publishing files.
eib_end_publishing() {
  local destdir="$(eib_image_dest)"

  # Skip on dry runs
  [ -n "${EIB_DRY_RUN}" ] && return 0

  if [ "$(hostname -s)" != "${EIB_IMAGE_HOST_SHORT}" ]; then
    ssh ${EIB_IMAGE_USER}@${EIB_IMAGE_HOST} rm -f \
      "${destdir}"/.inprogress
  else
    sudo -u ${EIB_IMAGE_USER} rm -f "${destdir}"/.inprogress
  fi
}

# Try to work around a race where partx sometimes reports EBUSY failure
eib_partx_scan() {
  udevadm settle
  local i=0
  while ! partx -a -v "$1"; do
	(( ++i ))
	[ $i -ge 10 ] && break
    echo "partx scan $1 failed, retrying..."
    sleep 1
  done
}

# Work around a race where loop deletion sometimes fails with EBUSY
eib_delete_loop() {
  udevadm settle
  local i=0
  while ! losetup -d "$1"; do
	(( ++i ))
	[ $i -ge 10 ] && break
    echo "losetup remove $1 failed, retrying..."
    sleep 1
  done
}

recreate_dir() {
  rm -rf $1
  mkdir -p $1
}

# Read ID of named user account from ostree deployment
ostree_uid() {
  grep ^${1}: ${OSTREE_DEPLOYMENT}/lib/passwd | cut -d : -f 3
}

# Read ID of named group from ostree deployment
ostree_gid() {
  grep ^${1}: ${OSTREE_DEPLOYMENT}/lib/group | cut -d : -f 3
}

# Created a detached signature with gpg.
sign_file() {
  local file=${1:?No file supplied to ${FUNCNAME}}

  gpg --homedir=${EIB_SYSCONF}/gnupg \
      --armour \
      --sign-with ${EIB_IMAGE_SIGNING_KEYID} \
      --detach-sign \
      --output "${file}.asc" \
      "${file}"
}

# Make a minimal chroot with the EOS ostree to use during the build.
make_tmp_ostree() {
  local packages=ostree
  local keyring

  # Include the keyring package to verify pulled commits.
  packages+=",eos-keyring"

  # Include ca-certificates to silence nagging from libsoup even though
  # we don't currently use https for ostree serving.
  packages+=",ca-certificates"

  # FIXME: Shouldn't need to specify pinentry-curses here, but
  # debootstrap can't deal with the optional dependency on
  # pinentry-gtk2 | pinentry-curses | pinentry correctly.
  packages+=",pinentry-curses"

  recreate_dir "${EIB_OSTREE_TMPDIR}"
  keyring=$(eib_keyring)
  debootstrap --arch=${EIB_ARCH} --keyring="${keyring}" \
    --variant=minbase --include="${packages}" \
    --components=core,endless,extra ${EIB_BRANCH} \
    "${EIB_OSTREE_TMPDIR}" "${EIB_OBS_REPO}" \
    "${EIB_DATA}"/debootstrap.script
}

# Run the temporary ostree within the chroot.
tmp_ostree() {
  chroot "${EIB_OSTREE_TMPDIR}" ostree "$@"
}

# Emulate the old ostree write-refs builtin where a local ref is forced
# to the commit of another ref.
tmp_ostree_write_refs() {
  local repo=${1:?No ostree repo supplied to ${FUNCNAME}}
  local src=${2:?No ostree source ref supplied to ${FUNCNAME}}
  local dest=${3:?No ostree dest ref supplied to ${FUNCNAME}}
  local destdir=${dest%/*}

  # Create the needed directory for the dest ref.
  chroot "${EIB_OSTREE_TMPDIR}" mkdir -p "${repo}/refs/heads/${destdir}"

  # Copy the source ref file to the dest ref.
  chroot "${EIB_OSTREE_TMPDIR}" cp -f "${repo}/refs/heads/${src}" \
    "${repo}/refs/heads/${dest}"
}

jenkins_crumb() {
  local token=$(<"${EIB_JENKINS_TOKEN}")

  curl -u "${EIB_JENKINS_USER}:${token}" \
    "${EIB_JENKINS_URL}"'/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,":",//crumb)'
}

true
