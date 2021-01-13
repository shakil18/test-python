set -x -a -e
trap "echo Unexpected error! See log above; exit 1" ERR

# CONFIG Parameters (might change)

export SCONE_CAS_ADDR="5-0-0.scone-cas.cf"
export DEVICE="/dev/sgx"

export SCONE_CAS_IMAGE="registry.scontain.com:5050/sconecuratedimages/services:cas"
# Not nessecarily access to CAS image, add default
export CAS_MRENCLAVE=`(docker pull $SCONE_CAS_IMAGE > /dev/null ; docker run -i --rm -e "SCONE_HASH=1" $SCONE_CAS_IMAGE cas) || echo 663ddae4f0036a39c18a533d97f7a5ba0850f2efb0147d63afa459a20315a7e1`  # compute MRENCLAVE for current CAS
# Need CLI_IMAGE to attest SCONE CAS, create a session, update, and verify that session
export CLI_IMAGE="registry.scontain.com:5050/sconecuratedimages/sconecli"
# Nedd PYTHON_IMAGE for our python based application
export PYTHON_IMAGE="registry.scontain.com:5050/sconecuratedimages/apps:python-2-alpine3.6"
export PYTHON_MRENCLAVE=`docker pull $PYTHON_IMAGE > /dev/null ; docker run -i --rm -e "SCONE_HEAP=256M" -e "SCONE_HASH=1" -e "SCONE_ALPINE=1" $PYTHON_IMAGE python`

# create random and hence, uniquee session number
SESSION="Session-$RANDOM-$RANDOM-$RANDOM"

# check if SGX device exists

if [[ ! -c "$DEVICE" ]] ; then 
    export DEVICE_O="DEVICE"
    export DEVICE="/dev/isgx"
    if [[ ! -c "$DEVICE" ]] ; then 
        echo "Neither $DEVICE_O nor $DEVICE exist"
        exit 1
    fi
fi

# to execute python application with interpreter inside an enclave 
#docker run --rm  --device=$DEVICE -v "$PWD/app":/usr/src/myapp -w /usr/src/myapp -e SCONE_HEAP=256M -e SCONE_MODE=HW -e SCONE_ALLOW_DLOPEN=2 -e SCONE_ALPINE=1 -e SCONE_VERSION=1 $PYTHON_IMAGE python hello.py
#

# create directories for encrypted files and fspf
rm -rf encrypted-files
rm -rf fspf-file
mkdir encrypted-files/
mkdir fspf-file/
cp fspf.sh fspf-file

# ensure that we have an up-to-date image
docker pull $CLI_IMAGE

# attest cas before uploading the session file, accept CAS running in debug
# mode (-d) and outdated TCB (-G), we accept debug-mode (--only_for_testing-debug)
# since in debug, so ignore signer (--only_for_testing-ignore-signer ) and also trust any enclave measurement value(--only_for_testing-trust-any)

# docker run --device=$DEVICE -it $CLI_IMAGE sh -c "scone cas attest -G --only_for_testing-debug scone-cas.cf $CAS_MRENCLAVE >/dev/null \
# && scone cas show-certificate" > cas-ca.pem

docker run --device=$DEVICE -it $CLI_IMAGE sh -c "scone cas attest 5-0-0.scone-cas.cf --only_for_testing-debug \
--only_for_testing-trust-any --only_for_testing-ignore-signer -G >/dev/null \
&& scone cas show-certificate" > cas-ca.pem

# create encrypte filesystem and fspf (file system protection file)
docker run --device=$DEVICE  -it -v $(pwd)/fspf-file:/fspf/fspf-file -v $(pwd)/native-files:/fspf/native-files/ -v $(pwd)/encrypted-files:/fspf/encrypted-files $CLI_IMAGE /fspf/fspf-file/fspf.sh

cat >Dockerfile <<EOF
FROM $PYTHON_IMAGE

COPY encrypted-files /fspf/encrypted-files
COPY fspf-file/fs.fspf /fspf/fs.fspf
EOF

# create a hello image with encrypted hello.py
docker build --pull -t hello .

# ensure that we have self-signed client certificate

if [[ ! -f client.pem || ! -f client-key.pem  ]] ; then
    openssl req -newkey rsa:4096 -days 365 -nodes -x509 -out client.pem -keyout client-key.pem -config clientcertreq.conf
fi

# create session file
export SCONE_FSPF_KEY=$(cat native-files/keytag | awk '{print $11}')
export SCONE_FSPF_TAG=$(cat native-files/keytag | awk '{print $9}')

MRENCLAVE=$PYTHON_MRENCLAVE envsubst '$MRENCLAVE $SCONE_FSPF_KEY $SCONE_FSPF_TAG $SESSION' < session-template.yml > session.yml
# note: this is insecure - use scone session create instead
curl -v -k -s --cert client.pem  --key client-key.pem  --data-binary @session.yml -X POST https://$SCONE_CAS_ADDR:8081/session


# create file with environment variables

cat > myenv << EOF
export SESSION="$SESSION"
export SCONE_CAS_ADDR="$SCONE_CAS_ADDR"
export DEVICE="$DEVICE"

EOF

echo "OK"
