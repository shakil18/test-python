#!/bin/bash
#
# tasks performed:
# - stop running docker containers
# - delete newly created files


docker-compose down

rm -rf encrypted-files fspf-file native-files/keytag cas-ca.pem client-key.pem client.pem myenv session.yml Dockerfile


