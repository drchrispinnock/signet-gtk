#!/bin/bash

# From pkg-builder
# (c) Chris Pinnock 2026
# MIT License

which reprepro >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo "reprepro is not installed."
    exit 1
fi

which aws >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo "WARN: aws is not installed."
fi

which gcloud >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo "WARN: gcloud is not installed."
fi

# Dependent XX
#
aptrepos="./repos"
incoming="./incoming"
dir="."
mapreposbycodename=0
incomingbyplat=1
root="release"
tidy=0

# Should be externals always
#
maproot=""
grepos=""
arepos=""
aprofile=""

hightargets="debian ubuntu"
[ -f "hightargets" ] && targets=`cat hightargets`

targets="debian-13"
[ -f "platforms" ] && targets=`cat platforms`

declare -A CODENAMES
CODENAMES["debian-13"]="trixie"
CODENAMES["debian-12"]="bookworm"
CODENAMES["ubuntu-2404"]="noble"
CODENAMES["ubuntu-2604"]="resolute"

while [ $# -gt 0 ]; do
    case $1 in
    	--aptdir)
            dir="$2"; shift; ;;
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
        --incoming-by-platform)
            incomingbyplat="1" ;;
        --no-incoming-by-platform)
            incomingbyplat="0" ;;
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
        _t=$(echo $root | tr '[:lower:]' '[:upper:]')
        echo "$root"
        subdir="$aptrepos/$_t"
        maproot="$_t"
    ;;

esac

# GCP and AWS options
#
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

mkdir -p $aptrepos
if [ -f index.html ]; then cp index.html $aptrepos/index.html; fi

mkdir -p $aptrepos/keys
cp $dir/keys/*.asc $aptrepos/keys

for os in ${hightargets}; do
    echo "==> $os"

    if [ "$mapreposbycodename" = "0" ]; then
        mkdir -p $subdir/$os/conf
            if [ ! -f $dir/$os/distributions ]; then
                echo "No config for $os"
                continue
            fi

        cp $dir/$os/distributions $subdir/$os/conf
        cp $dir/$os/options $subdir/$os/conf
    fi

    for targ in $targets; do


        baseos=$(echo $targ | awk -F'-' '{print $1 "-" $2}')
        codename=${CODENAMES[${baseos}]}
        _code=""
        if [ "$mapreposbycodename" = "1" ]; then
            _code="$codename"
            mkdir -p $subdir/$os/$_code/conf
            if [ ! -f $dir/$os/$_code/distributions ]; then
                echo "No config for $os/$_code"
                continue
            fi

            cp $dir/$os/distributions $subdir/$os/$_code/conf
            cp $dir/$os/options $subdir/$os/$_code/conf
        fi

        resolve=$(echo $targ | awk -F'-' '{print $1}')

        if [ "$resolve" = "$os" ]; then
            echo "===> $targ ($root - target $subdir/$os/$_code)"
            _i="$incoming/$maproot/$targ/*.deb"
            [ "$incomingbyplat" = "0" ] && _i="$incoming/$maproot/*.deb"
            reprepro -b $subdir/$os/$_code includedeb $codename $_i
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
