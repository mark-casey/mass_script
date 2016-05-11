#!/bin/bash

# Bash script to install/configure all-in-one MAAS based on documentation and past experience

set -e
set -u
set -o pipefail


# add software-properties-common if not present
apt-get -qy update
apt-get -qy install software-properties-common


# Use newest packages, available in official PPA
add-apt-repository -y ppa:maas/stable


#
apt-get -qy update

# FIXME this makes it sound optional but it isn't cause DHCP needs to be configured with it
# If this host has more than once network interface the wrong IP/interface
# may be used for things like the host portion of the URL that target nodes
# use to download cloud-init configs post-install. So we'll use the value of
# MAASVM_MGMTNET_IP if it is set and its value is one of this host's IPs.
#
if  [[ -n "${MAASVM_MGMTNET_IP:-}" ]]
then
    if [[ $( grep -c "${MAASVM_MGMTNET_IP}" <(ip a) || true ) > 0 ]]
    then
        echo "maas-cluster-controller maas-cluster-controller/maas-url string http://${MAASVM_MGMTNET_IP}/MAAS" \
        | debconf-set-selections
        echo "maas-region-controller-min maas/default-maas-url string ${MAASVM_MGMTNET_IP}" | debconf-set-selections
    else
        echo "Error: MAASVM_MGMTNET_IP is set to ${MAASVM_MGMTNET_IP} but this host does not appear to have an interface holding that IP."
    fi
else
    echo "Error: MAASVM_MGMTNET_IP must be set."
    exit 1
fi


#
apt-get -qy install maas


# assign defaults if not set
if [[ -z "${MAAS_ADMIN_USER:-}" ]]; then MAAS_ADMIN_USER="admin"; fi
if [[ -z "${MAAS_ADMIN_EMAIL:-}" ]]; then MAAS_ADMIN_EMAIL="admin@email.com"; fi
if [[ -z "${MAAS_ADMIN_PASS:-}" ]]; then MAAS_ADMIN_PASS="admin"; fi
MAASVM_API_URL="http://${MAASVM_MGMTNET_IP}:5240/MAAS/api/1.0"

#
# calls to sleep from here on are to keep from overwhelming MAAS on slow hardware
#

# create admin user
sleep 4
maas-region-admin createadmin --username="${MAAS_ADMIN_USER}" --email="${MAAS_ADMIN_EMAIL}" --password="${MAAS_ADMIN_PASS}"

# store admin user's api key/token
sleep 4
MAAS_ADMIN_APIKEY="$(maas-region-admin apikey --username ${MAAS_ADMIN_USER})"

# log in to included api cli wrapper
sleep 4
maas login "${MAAS_ADMIN_USER}" "${MAASVM_API_URL}" "${MAAS_ADMIN_APIKEY}"

# add Ubuntu Trusty, Wily, and Xenial if not added already
sleep 4
maas "${MAAS_ADMIN_USER}" boot-source-selections create 1 os="ubuntu" release="trusty" arches="amd64" subarches="*" labels="*" || true
maas "${MAAS_ADMIN_USER}" boot-source-selections create 1 os="ubuntu" release="wily" arches="amd64" subarches="*" labels="*" || true
maas "${MAAS_ADMIN_USER}" boot-source-selections create 1 os="ubuntu" release="xenial" arches="amd64" subarches="*" labels="*" || true

# apply image changes and/or start download of images not added from disk
# this happens now and at the end because the first run enumerates architecture types the custom image imports need
sleep 4
maas "${MAAS_ADMIN_USER}" boot-resources import

if [[ "${MAAS_ADD_CENTOS:-}" == "yes" ]]
then
    ### CentOS images in MAAS
    # April 15, 2016:
    #  - maas-image-builder compiles using the steps here, which work around issue(s) encountered.
    #  - maas-image-builder project seems a little neglected at this time (hoping
    #    there is a replacement coming in MAAS v2 or something).
    #  - I had to create virbr0 and add mgmt NIC to it using virsh to get the call to
    #    maas-image-builder to make much progress, which partially broke networking.
    #  - The installer had booted and made real, valid, progress before it seemed to get unhappy.
    #  - I killed the installer/VM when it ran into issues; the fact I was trying to
    #    build the image using QEUM inside a VBox may have been causing several issues.
    #  - This part may be better done on a physical install and the result preserved(?).
    #  - You can also read in the 1.9.0 section of the MAAS changelog about using the daily
    #    image stream at: 'http://maas.ubuntu.com/images/ephemeral-v2/daily/' as a source of
    #    CentOS images for MAAS, but timestamps suggest these are not currently updated daily,
    #    are rather old, and so could take a while to install updates during new deploys.
    #  - Because of the state of CentOS support here the last two lines are commented-out

    # tools
    apt-get -qy install bzr make python-virtualenv python-pip

    # get
    bzr branch lp:maas-image-builder

    # fix1
    # 'python-stevedore' is the name of the apt package, not the Py package (https://code.launchpad.net/~ti-mo/maas-image-builder/maas-image-builder/+merge/278773 )
    sed -i "s,python-stevedore,stevedore," maas-image-builder/setup.py

    # install from checkout
    pip install maas-image-builder/

    # fix2
    # AppArmor doesn't allow qemu to access /tmp, so /var/lib/libvirt/images/<temppath> is chosen instead (https://code.launchpad.net/~ti-mo/maas-image-builder/maas-image-builder/+merge/278773 )
    sed -i "s,\(tempdir.*\)location=None,\1location=b'/var/lib/libvirt/images'," /usr/local/lib/python2.7/dist-packages/mib/utils.py
    mkdir -p /var/lib/libvirt/images/

    # install these functional dependencies after main install to prevent supreceeding direct depenencies of main install and breaking it
    cd maas-image-builder/ && make install-dependencies && cd -

    # create a CentOS image
    #maas-image-builder -a amd64 -o centos7-amd64-root-tgz centos --edition 7

    # add CentOS image
    sleep 4
    #maas "${MAAS_ADMIN_USER}" boot-resources create name=centos/centos7 architecture=amd64/generic content@=./build-output/centos7-amd64-root-tgz
fi

if [[ "${MAAS_ADD_COREOS:-}" == "yes" ]]
then
    source <(wget -O- http://stable.release.core-os.net/amd64-usr/current/version.txt)
    # this dir will get emptied but left around - need to improve safety of rm on next line
    coreos_dl_dir="$(mktemp -d)"
    #trap "rm ${coreos_dl_dir} -rf" EXIT
    cd "${coreos_dl_dir}"
    wget -nv http://stable.release.core-os.net/amd64-usr/current/coreos_production_image.bin.bz2
    bunzip2 -c < coreos_production_image.bin.bz2 | gzip -c > coreos_production_image.bin.tgz
    sleep 4
    maas "${MAAS_ADMIN_USER}" boot-resources create name=custom/coreos_stable_"${COREOS_BUILD}"_"${COREOS_BRANCH}"_"${COREOS_PATCH}" architecture=amd64/generic content@=coreos_production_image.bin.tgz
    rm coreos_production_image.bin.tgz coreos_production_image.bin.bz2
fi


# apply image changes and/or start download of images not added from disk
sleep 4
maas "${MAAS_ADMIN_USER}" boot-resources import


#sleep 4
#set maas dhcp settings on mgmt interface; done in Readme for now using MAAS GUI


# done. log out of api cli wrapper
sleep 4
maas logout "${MAAS_ADMIN_USER}"

