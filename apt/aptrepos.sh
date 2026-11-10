# Get _aptrepos.sh from the pkg-builder repos
bash _aptrepos.sh --no-incoming-by-platform --incoming=../dist --awsprofile homes3 --aws s3://apt.signetwallet.org
