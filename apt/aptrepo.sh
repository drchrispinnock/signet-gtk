#!/bin/bash

# From pkg-builder
# (c) Chris Pinnock 2026
# MIT License

mapreposbycodename=0
aptrepos="./repos"
incoming="../dist"
root="release"
maproot=""
grepos=""
arepos="s3://apt.signetwallet.org"
aprofile=""
tidy=0

targets="debian-13"
[ -f "platforms" ] && targets=`cat platforms`

declare -A CODENAMES
CODENAMES["debian-13"]="trixie"
CODENAMES["debian-12"]="bookworm"
CODENAMES["ubuntu-2404"]="noble"
CODENAMES["ubuntu-2604"]="resolute"

while [ $# -gt 0 ]; do
    case $1 in
        --aptrepos)
            aptrepos="$2"; shift; ;;
        --targets|--target|-T)
            targets="$2"; shift; ;;
        --incoming)
            incoming="$2"; shift ;;
        --gcloud)
            grepos="$2"; shift; ;;
        --aws)
            arepos="$2"; shift; ;;
        --awsprofile)
            aprofile="$2"; shift; ;;
        --map-repos-by-codename)
            mapreposbycodename="1" ;;
        --no-map-repos-by-codename)
            mapreposbycodename="0" ;;
        --tidy)
            tidy=1 ;;
        --no-tidy)
            tidy=0 ;;
        --root)
            root="$2"; shift ;;
        -*) echo "WARN: unknown option $1" >&2; ;;
    esac
    shift
done

# Multiple repos handling for DEVEL, RC, etc
#
subdir="$aptrepos"
case $root in
    release)
        subdir="$aptrepos"
        maproot=""
        ;;
    dev|devel|DEVEL)
        subdir="$aptrepos/DEVEL"
        maproot="DEVEL"
        ;;
    *)
        echo "Root must be release or dev" && exit 2
        ;;
esac

gcliops=""
acliops=""
preacliops=""

if [ "$tidy" = "1" ]; then
   gcliops="$gcliops --delete-unmatched-destination-objects"
   acliops="$acliops --delete"
fi

if [ ! -z "$aprofile" ]; then
    preacliops="--profile $aprofile"
fi

which reprepro >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo "reprepro is not installed."
    exit 1
fi

mkdir -p $aptrepos
if [ -f index.html ]; then cp index.html $aptrepos/index.html; fi

mkdir -p $aptrepos/keys
cp keys/*.asc $aptrepos/keys

for os in debian ubuntu; do
    echo "==> $os"

    if [ "$mapreposbycodename" = "0" ]; then
        mkdir -p $subdir/$os/conf
            if [ ! -f $os/distributions ]; then
                echo "No config for $os"
                continue
            fi

        cp $os/distributions $subdir/$os/conf
        cp $os/options $subdir/$os/conf
    fi

    for targ in $targets; do


        baseos=$(echo $targ | awk -F'-' '{print $1 "-" $2}')
        codename=${CODENAMES[${baseos}]}
        _code=""
        if [ "$mapreposbycodename" = "1" ]; then
            _code="$codename"
            mkdir -p $subdir/$os/$_code/conf
            if [ ! -f $os/$_code/distributions ]; then
                echo "No config for $os/$_code"
                continue
            fi

            cp $os/distributions $subdir/$os/$_code/conf
            cp $os/options $subdir/$os/$_code/conf
        fi

        resolve=$(echo $targ | awk -F'-' '{print $1}')

        if [ "$resolve" = "$os" ]; then
            echo "===> $targ ($root - target $subdir/$os/$_code)"
# xxx            reprepro -b $subdir/$os/$_code includedeb $codename $incoming/$maproot/$targ/*.deb
            reprepro -b $subdir/$os/$_code includedeb $codename $incoming/$maproot/*.deb
            reprepro -b $subdir/$os/$_code export $codename
        fi

    done

    if [ -n "$grepos" ]; then
        echo "Syncing $aptrespos to $grepos"
        gcloud storage rsync -r $gcliops $aptrepos/ $grepos
    fi

    if [ -n "$arepos" ]; then
        echo "Syncing $aptrespos to $arepos"
        echo "aws $preacliops s3 sync $acliops $aptrepos/ $arepos"
        aws $preacliops s3 sync $acliops $aptrepos/ $arepos
    fi

done
